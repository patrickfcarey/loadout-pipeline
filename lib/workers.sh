#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/job_format.sh"
source "$ROOT_DIR/lib/resume_planner.sh"
#
# Two worker pools draining two queues:
#
#   EXTRACT_QUEUE_DIR  ── MAX_UNZIP workers ──┐
#                                             ▼
#                                 lib/extract.sh
#                                 (precheck → reserve → copy → 7z x)
#                                             │
#                                             ▼
#   DISPATCH_QUEUE_DIR ── MAX_DISPATCH workers ─→ lib/dispatch.sh → adapter
#
# The pools run concurrently: dispatch of job N overlaps extraction of job N+1.
# Dispatch workers use a short-poll loop and exit once the extract phase has
# finished (signalled by the .extract_done sentinel file) AND the dispatch
# queue has drained.
#
# Recovery: after each extract pass, the worker registry is scanned for jobs
# that were in-flight when a worker was SIGKILL'd. Those jobs are re-queued
# and a new pass runs. See lib/worker_registry.sh for details.

# =============================================================================
# Scratch-spool management
# =============================================================================

# ─── _spool_sweep_and_claim ───────────────────────────────────────────────────
# Sweeps COPY_DIR for subdirectories left by dead previous pipeline runs, then
# claims a fresh subdir for this run. Stale subdirs are identified by their
# numeric name (each run's subdir is named after its PID) — if that PID no
# longer passes kill -0, the directory is leftover garbage and is removed.
#
# Must run BEFORE COPY_SPOOL is created so the kill -0 check for our own PID
# is unambiguous (our subdir does not yet exist, so it cannot appear in the
# sweep). After the sweep, claims COPY_SPOOL="$COPY_DIR/$$" and unconditionally
# rm -rf's it before mkdir to defend against PID-space wraparound (a previous
# crashed run with the same PID would survive the sweep since kill -0 $$ is
# always alive for the current process).
#
# Parameters  : none
# Returns     : 0 always
# Modifies
#   COPY_SPOOL (exported env var) — set to "$COPY_DIR/$$"; all extract workers
#     in this run write their scratch copies here
#   filesystem — removes stale peer subdirs under COPY_DIR; creates COPY_SPOOL
#
# Locals
#   base   — local alias for COPY_DIR; the parent directory being swept
#   subdir — full path to each immediate subdirectory found inside base
#   subpid — basename of subdir; the PID of the run that created it; tested
#            with kill -0 to determine whether that run is still alive
# ──────────────────────────────────────────────────────────────────────────────
_spool_sweep_and_claim() {
    local base="$COPY_DIR" subdir subpid
    mkdir -p "$base"
    while IFS= read -r subdir; do
        subpid="$(basename "$subdir")"
        if [[ "$subpid" =~ ^[0-9]+$ ]] && ! kill -0 "$subpid" 2>/dev/null; then
            _spool_guarded_rm_rf "$subdir"
        fi
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    export COPY_SPOOL="$base/$$"
    # Guard against PID reuse: the sweep above skips dirs whose PID passes
    # `kill -0` — including our own PID, which is always alive. If a previous
    # crashed run happened to use the same PID (PID-space wrap-around), its
    # spool dir would survive the sweep and we'd inherit stale scratch files.
    # A cheap unconditional rm -rf guarantees a clean spool before first use.
    _spool_guarded_rm_rf "$COPY_SPOOL"
    mkdir -p "$COPY_SPOOL"
}

# ─── _spool_guarded_rm_rf ─────────────────────────────────────────────────────
# Wraps rm -rf around the very narrow set of paths that are legitimate spool
# subdirectories. Refuses to act on anything that does not live directly under
# $COPY_DIR and does not have a purely-numeric basename (which the spool claim
# logic above guarantees, because the basename is always $$). This keeps a
# corrupted COPY_SPOOL variable or an inherited-env surprise from turning into
# a destructive rm on the wrong path.
#
# Parameters
#   $1  path — the candidate directory to remove
#
# Returns     : 0 on success or skip; non-zero only if the rm itself fails
# Modifies    : filesystem — deletes $path if it passes the guards
# ──────────────────────────────────────────────────────────────────────────────
_spool_guarded_rm_rf() {
    local path="$1" name parent
    [[ -n "$path" ]] || return 0
    # Refuse unsafe paths outright: root, relative, no trailing component.
    case "$path" in
        ""|"/"|".") log_error "spool guard: refusing to rm '$path'"; return 1 ;;
    esac
    parent="$(dirname  "$path")"
    name="$(basename "$path")"
    if [[ "$parent" != "$COPY_DIR" || ! "$name" =~ ^[0-9]+$ ]]; then
        log_error "spool guard: refusing rm of '$path' (parent='$parent' name='$name' not under COPY_DIR/<pid>)"
        return 1
    fi
    rm -rf -- "$path"
}

# =============================================================================
# Per-run initialisation
# =============================================================================

# ─── _pipeline_run_init ───────────────────────────────────────────────────────
# Resets every shared data structure to a clean state at the start of a pipeline
# run: clears both queues, removes the .extract_done sentinel file, truncates
# the space ledger, and clears the worker registry. Also sources space.sh and
# worker_registry.sh so their functions are available in the current shell
# (and therefore inherited by all forked worker subshells).
#
# Parameters  : none
# Returns     : 0 always
# Modifies
#   $EXTRACT_QUEUE_DIR  — cleared of all .job and .claimed.* files
#   $DISPATCH_QUEUE_DIR — cleared of all .job and .claimed.* files
#   $QUEUE_DIR/.extract_done — removed if present
#   $QUEUE_DIR/.space_ledger and .space_ledger.lock — truncated to empty
#   $QUEUE_DIR/.worker_registry and .worker_registry.lock — truncated to empty
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
_pipeline_run_init() {
    queue_init "$EXTRACT_QUEUE_DIR"
    queue_init "$DISPATCH_QUEUE_DIR"
    rm -f "$QUEUE_DIR/.extract_done"
    source "$ROOT_DIR/lib/space.sh"
    space_init
    source "$ROOT_DIR/lib/worker_registry.sh"
    worker_registry_init
}

# =============================================================================
# Single extract+dispatch pass
# =============================================================================

# ─── _run_worker_pass ─────────────────────────────────────────────────────────
# Spawns one complete set of extract and dispatch worker processes, waits for
# all of them to finish, then cleans up the .extract_done sentinel and resets
# the dispatch queue for any subsequent recovery pass.
#
# Extract workers drain EXTRACT_QUEUE_DIR; each calls lib/extract.sh per job.
# Once all extract workers exit, a .extract_done sentinel is written so dispatch
# workers know no more jobs are coming and can exit after draining their queue.
# Dispatch workers drain DISPATCH_QUEUE_DIR; each calls lib/dispatch.sh per job.
#
# Parameters
#   $1  pass_num   — 1-based pass counter used only for log messages;
#                    pass 1 prints the "Starting N workers" banner, subsequent
#                    passes print a "Recovery pass N" message
#   $2  nameref_rc — name of the caller's integer variable (passed by nameref)
#                    that is set to 1 if any extract or dispatch worker exits
#                    non-zero; the caller accumulates this across passes
#
# Returns     : 0 always (failures are communicated via the nameref)
# Modifies
#   nameref_rc (caller's variable) — set to 1 on any worker failure
#   $QUEUE_DIR/.extract_done — created after all extract workers exit;
#                              removed before the function returns
#   $DISPATCH_QUEUE_DIR — re-initialised (queue_init) before the function
#                         returns so recovery passes start from a clean state
#
# Locals
#   pass         — $1 captured as a named local
#   _pass_rc     — nameref alias for $2; writing to this modifies the caller's variable
#   extract_pids — array of background PIDs for the MAX_UNZIP extract workers;
#                  waited on individually so each failure is detected
#   dispatch_pids — array of background PIDs for the MAX_DISPATCH dispatch workers;
#                   waited on after the extract_done sentinel is written
#   i            — loop counter for the worker spawn loops (1..MAX_UNZIP and
#                  1..MAX_DISPATCH)
#   pid          — current PID being waited on in the wait loops
# ──────────────────────────────────────────────────────────────────────────────
_run_worker_pass() {
    local pass="$1"
    local -n _pass_rc="$2"
    local extract_pids=() dispatch_pids=() i pid

    if (( pass == 1 )); then
        echo "[pipeline] Starting $MAX_UNZIP extract worker(s) and $MAX_DISPATCH dispatch worker(s)..."
    else
        echo "[pipeline] Recovery pass $pass: restarting workers for orphaned job(s)..."
    fi

    for ((i=1; i<=MAX_UNZIP; i++)); do
        unzip_worker &
        extract_pids+=($!)
    done
    for ((i=1; i<=MAX_DISPATCH; i++)); do
        dispatch_worker &
        dispatch_pids+=($!)
    done

    for pid in "${extract_pids[@]}"; do
        wait "$pid" || _pass_rc=1
    done

    # Signal dispatch workers that no more jobs are coming.
    touch "$QUEUE_DIR/.extract_done"

    for pid in "${dispatch_pids[@]}"; do
        wait "$pid" || _pass_rc=1
    done

    rm -f "$QUEUE_DIR/.extract_done"
    # Clear any leftover claimed files so a recovery pass starts from clean.
    queue_init "$DISPATCH_QUEUE_DIR"
}

# =============================================================================
# Orphan recovery
# =============================================================================

# ─── _recover_orphans ─────────────────────────────────────────────────────────
# Reads the worker registry for jobs that were in-flight when a worker was
# SIGKILL'd (i.e. jobs that were popped from the extract queue but never
# finished), re-queues each onto EXTRACT_QUEUE_DIR, and returns 0 to signal
# the caller that another worker pass is needed. Returns 1 when the registry
# is empty and no recovery is required.
#
# Parameters  : none
#
# Returns
#   0 — one or more orphaned jobs were found and re-queued; caller should run
#       another _run_worker_pass
#   1 — registry was empty; all jobs completed normally; no recovery needed
#
# Modifies
#   $QUEUE_DIR/.worker_registry — cleared by worker_registry_recover after
#                                 all orphaned jobs have been read
#   $EXTRACT_QUEUE_DIR — each orphaned job string is pushed back as a new .job file
#
# Locals
#   orphaned — array accumulating every orphaned job string returned by
#              worker_registry_recover; collected into an array before re-queuing
#              so the registry is fully read before any new pushes begin
#   orphan   — loop variable iterating over the orphaned array during re-queue
# ──────────────────────────────────────────────────────────────────────────────
_recover_orphans() {
    local orphaned=() orphan
    while IFS= read -r orphan; do
        [[ -n "$orphan" ]] || continue
        orphaned+=("$orphan")
    done < <(worker_registry_recover)

    (( ${#orphaned[@]} == 0 )) && return 1

    log_warn "${#orphaned[@]} orphaned job(s) detected — re-queuing for recovery"
    for orphan in "${orphaned[@]}"; do
        queue_push "$EXTRACT_QUEUE_DIR" "$orphan"
    done
    return 0
}

# =============================================================================
# workers_start — top-level orchestrator
# =============================================================================

# ─── workers_start ────────────────────────────────────────────────────────────
# Top-level orchestrator for the two-stage worker pipeline. Sweeps and claims
# the scratch spool, initialises all shared data structures, enqueues every
# loaded job onto the extract queue, and then runs worker passes in a recovery
# loop until all jobs complete or the maximum recovery attempt limit is reached.
#
# Recovery loop behaviour:
#   - Each pass calls _run_worker_pass, which blocks until all workers exit.
#   - After each pass, _recover_orphans checks the worker registry for jobs
#     abandoned by SIGKILL'd workers and re-queues them. If orphans are found,
#     the loop continues with a new pass. If none are found, the loop exits.
#   - If the pass counter exceeds MAX_RECOVERY_ATTEMPTS, the pipeline gives up
#     and returns non-zero so the caller knows some jobs were permanently lost.
#
# Parameters  : none
#
# Returns
#   0 — all jobs completed successfully across all passes
#   1 — one or more jobs failed permanently (extract error, oversized archive,
#       or max recovery attempts exhausted)
#
# Modifies
#   COPY_SPOOL (env var) — set by _spool_sweep_and_claim; removed (rm -rf) on return
#   EXTRACT_QUEUE_DIR   — populated with all JOBS entries, then drained by workers
#   DISPATCH_QUEUE_DIR  — populated by extract workers, then drained by dispatch workers
#   $QUEUE_DIR/.space_ledger, .worker_registry, .extract_done — managed by sub-functions
#
# Locals
#   job          — loop variable iterating over the global JOBS array to push
#                  each job onto EXTRACT_QUEUE_DIR
#   rc           — overall pipeline return code; updated to pass_rc after each pass
#   pass_rc      — per-pass return code; passed by nameref to _run_worker_pass;
#                  reset to 0 before each pass so a clean recovery pass does not
#                  inherit the prior SIGKILL pass's failure
#   pass         — 1-based counter of how many worker passes have been run;
#                  used for log messages and the MAX_RECOVERY_ATTEMPTS guard
#   max_recovery — local copy of MAX_RECOVERY_ATTEMPTS (default 3); the ceiling
#                  on how many additional passes may be run to recover orphaned jobs
# ──────────────────────────────────────────────────────────────────────────────
workers_start() {
    log_enter
    _spool_sweep_and_claim
    _pipeline_run_init

    # Install an EXIT trap so COPY_SPOOL is cleaned up on SIGINT/SIGTERM,
    # set -e aborts, and any other non-normal exit path — not just at the
    # end of a clean completion. Without this, a Ctrl-C between passes
    # would leak the per-run spool until the next pipeline run's sweep
    # caught it (and even then only if the reused PID weren't alive).
    # shellcheck disable=SC2064  # intentional early expansion of $COPY_SPOOL
    trap "_spool_guarded_rm_rf '$COPY_SPOOL'" EXIT

    # Resume planner: drop jobs whose content is already fully present at the
    # adapter destination before any worker forks. Runs in the quiescent
    # window between _pipeline_run_init and the enqueue loop, so the
    # destination cannot change underfoot. Disabled path is a no-op.
    resume_plan

    local job
    for job in "${JOBS[@]}"; do
        queue_push "$EXTRACT_QUEUE_DIR" "$job"
    done

    local rc=0 pass_rc=0 pass=0 max_recovery="${MAX_RECOVERY_ATTEMPTS:-3}"

    while true; do
        (( pass++ )) || true
        # Reset per-pass rc so a clean recovery pass isn't tainted by a
        # prior pass's SIGKILL. The final pipeline rc is the rc of the LAST
        # pass that ran — i.e. "did we eventually finish cleanly?" — unless
        # we exhaust MAX_RECOVERY_ATTEMPTS, which is a hard failure below.
        pass_rc=0
        _run_worker_pass "$pass" pass_rc
        rc=$pass_rc

        _recover_orphans || break

        if (( pass > max_recovery )); then
            log_error "max recovery attempts ($max_recovery) reached; some jobs permanently abandoned"
            rc=1
            break
        fi
    done

    [[ $rc -eq 0 ]] || log_error "one or more workers reported failures"
    return $rc
}

# =============================================================================
# unzip_worker helpers
# =============================================================================

# ─── _unzip_handle_job ────────────────────────────────────────────────────────
# Runs lib/extract.sh for one job and resolves the outcome into one of three
# results: success, space-retry re-queue, or permanent failure. Called by
# unzip_worker for every job it pops from the extract queue.
#
# Space-retry path (rc=75): if extract.sh exits 75 (reservation did not fit),
# this function checks space_ledger_empty. If the ledger is already empty, no
# sibling holds space and waiting cannot help — the archive is declared too
# large and the job fails permanently. Otherwise, the backoff map is consulted
# for this job's current sleep interval, the worker sleeps, the interval is
# doubled (capped at SPACE_RETRY_BACKOFF_MAX_SEC), and the job is re-pushed
# onto the extract queue. The caller treats rc=75 as "not a failure".
#
# Parameters
#   $1  job                     — full job string (e.g. "~path/game.7z|sd|dest~")
#   $2  backoff_seconds_nameref — name of the caller's associative array variable
#                                 (passed by nameref) that maps job strings to
#                                 their current backoff interval in seconds; allows
#                                 the sleep to grow across consecutive space misses
#                                 within this worker's lifetime
#
# Returns
#   0  — extract.sh completed successfully
#   75 — space did not fit; job was re-queued; caller should not count as failure
#   1  — permanent failure (extract error, or archive too large for filesystem)
#
# Modifies
#   __backoff_sec (caller's associative array) — the entry for $job is updated
#     to the next (doubled) backoff interval after each space-reservation miss
#   $EXTRACT_QUEUE_DIR — job is re-pushed when rc=75 and siblings hold space
#
# Locals
#   job                 — $1 captured as a named local
#   __backoff_sec       — nameref alias for $2 (the caller's backoff map)
#   rc                  — exit code captured from bash extract.sh; drives the
#                         case branch that resolves the outcome
#   current_backoff_sec — this job's current sleep interval from the backoff map,
#                         defaulting to SPACE_RETRY_BACKOFF_INITIAL_SEC (5s)
#   max_backoff_sec     — ceiling for the exponential sleep, from
#                         SPACE_RETRY_BACKOFF_MAX_SEC (default 60s)
#   next_backoff_sec    — doubled interval written back into __backoff_sec[$job]
#                         for the next miss; computed by awk to handle decimals
# ──────────────────────────────────────────────────────────────────────────────
_unzip_handle_job() {
    local job="$1"
    local -n __backoff_sec="$2"
    local rc=0

    bash "$ROOT_DIR/lib/extract.sh" "$job" || rc=$?

    case "$rc" in
        0)
            return 0
            ;;
        75)
            # space_ledger_empty is in scope — space.sh is sourced by
            # _pipeline_run_init and inherited by this forked worker subshell.
            #
            # Fast-fail path: if the ledger is completely empty right now, no
            # sibling worker holds any space reservation. Waiting cannot help —
            # the archive is permanently too large for the available filesystem.
            if space_ledger_empty; then
                log_error "extract: archive does not fit in scratch space and no siblings are running — archive may be too large for this filesystem: $job"
                return 1
            fi

            # Backoff path: sibling workers are actively using scratch space.
            # Sleep before re-queuing so we do not spin-poll with expensive
            # precheck + space-reserve calls every fraction of a second.
            # The interval doubles on each consecutive miss for this job (tracked
            # in the per-worker nameref map), capped at SPACE_RETRY_BACKOFF_MAX_SEC.
            local current_backoff_sec="${__backoff_sec[$job]:-${SPACE_RETRY_BACKOFF_INITIAL_SEC:-5}}"
            local max_backoff_sec="${SPACE_RETRY_BACKOFF_MAX_SEC:-60}"

            log_debug "space reservation miss for $(basename "$job") — sleeping ${current_backoff_sec}s before re-queue (siblings hold space; max wait ${max_backoff_sec}s)"
            sleep "$current_backoff_sec"

            # Double the next interval, capped at the maximum.
            local next_backoff_sec
            next_backoff_sec=$(awk -v cur="$current_backoff_sec" -v max="$max_backoff_sec" \
                'BEGIN { n = cur * 2; print (n > max ? max : n) }')
            __backoff_sec[$job]="$next_backoff_sec"

            queue_push "$EXTRACT_QUEUE_DIR" "$job"
            return 75
            ;;
        *)
            log_error "extract failed (rc=$rc): $job"
            return 1
            ;;
    esac
}

# =============================================================================
# unzip_worker
# =============================================================================

# ─── unzip_worker ─────────────────────────────────────────────────────────────
# Extract-stage worker. Runs as a background process (spawned with &) by
# _run_worker_pass. Pops jobs from EXTRACT_QUEUE_DIR in a loop and processes
# each one via _unzip_handle_job until the queue is empty, then exits.
#
# Each job is registered in the worker registry before processing and
# unregistered after, so any job in-flight when this worker is SIGKILL'd is
# detectable by _recover_orphans. Double-unregistration on loop exit is safe
# because worker_job_end is a no-op on a missing entry.
#
# Parameters  : none (job strings are consumed from EXTRACT_QUEUE_DIR)
#
# Returns
#   0 — all jobs either succeeded or were re-queued for space retry
#   1 — one or more jobs resulted in permanent failure
#
# Modifies
#   EXTRACT_QUEUE_DIR — jobs are popped (claimed and deleted) as they are processed
#   $QUEUE_DIR/.worker_registry — each job's begin/end is recorded here
#   _space_retry_backoff_seconds — per-job backoff state updated by _unzip_handle_job
#
# Locals
#   _space_retry_backoff_seconds — associative array (declare -A) mapping each
#                                  job string to its current retry sleep interval;
#                                  scoped to this worker instance so each parallel
#                                  worker maintains independent backoff state
#   job        — current job string popped from the queue by queue_pop
#   fail_count — count of jobs that exited with a permanent failure code (not 0
#                or 75); drives the worker's exit code
#   job_rc     — exit code from _unzip_handle_job for the current job; used to
#                distinguish permanent failures from space-retry re-queues
# ──────────────────────────────────────────────────────────────────────────────
unzip_worker() {
    log_enter
    # Per-job backoff tracking: maps job string → current sleep interval in
    # seconds for the next space-reservation retry. Starts at
    # SPACE_RETRY_BACKOFF_INITIAL_SEC and doubles on each miss, capped at
    # SPACE_RETRY_BACKOFF_MAX_SEC. Keyed on the full job string so multiple
    # different jobs in the queue each maintain independent backoff state.
    declare -A _space_retry_backoff_seconds=()
    local job fail_count=0 job_rc pop_rc

    # Explicit 3-way branch on queue_pop's exit code: 0 = got a job,
    # 1 = queue empty (normal exit), 2 = read error (treat as a failure).
    # Using `while job=$(queue_pop ...)` would collapse rc=1 and rc=2 into
    # the same "queue empty" branch, causing workers to silently exit with
    # unprocessed jobs still in the queue.
    while true; do
        pop_rc=0
        job=$(queue_pop "$EXTRACT_QUEUE_DIR") || pop_rc=$?
        case "$pop_rc" in
            0) : ;;                       # got a job — process it below
            1) break ;;                   # queue empty — normal exit
            *)                            # read error — fail loudly
                log_error "unzip_worker: queue_pop returned error (rc=$pop_rc); aborting this worker"
                (( fail_count++ )) || true
                break
                ;;
        esac
        worker_job_begin "$BASHPID" "$job"
        job_rc=0
        _unzip_handle_job "$job" _space_retry_backoff_seconds || job_rc=$?
        # Always unregister after handling — even for re-queued jobs. The job
        # will get a fresh registry entry when the next worker picks it up.
        worker_job_end "$BASHPID"
        case "$job_rc" in
            0|75) : ;;   # success or re-queued — not a counted failure
            *)    (( fail_count++ )) || true ;;
        esac
    done

    # Belt-and-suspenders: ensure our registry entry is gone even if the loop
    # exits via an unexpected path (e.g. a set -e abort inside queue_pop).
    worker_job_end "$BASHPID"

    return $(( fail_count > 0 ? 1 : 0 ))
}

# =============================================================================
# dispatch_worker helpers
# =============================================================================

# ─── _dispatch_handle_job ─────────────────────────────────────────────────────
# Parses one dispatch job token and invokes the appropriate adapter script via
# lib/dispatch.sh. The token uses the same ~field|field|field~ format as extract
# jobs but the first field is the path to the extracted directory (not the
# archive), which is what the adapter receives to transfer.
#
# Parameters
#   $1  job — dispatch job token of the form "~extracted_dir|adapter|dest~"
#             where extracted_dir is the absolute path of the directory written
#             by lib/extract.sh (e.g. "/tmp/iso_pipeline/game1")
#
# Returns
#   0 — dispatch.sh exited successfully
#   1 — token was malformed (parse_job_line rejected it) or dispatch.sh failed
#
# Modifies    : nothing directly — delegate behaviour is adapter-specific
#
# Locals
#   job                   — $1 captured as a named local
#   parsed_dispatch_fields — three newline-separated fields returned by parse_job_line
#   src                   — extracted directory path (field 1 of the token)
#   adapter               — adapter name: ftp | hdl | sd | rclone | rsync (field 2)
#   dest                  — adapter-specific destination path (field 3)
# ──────────────────────────────────────────────────────────────────────────────
_dispatch_handle_job() {
    local job="$1"
    local parsed_dispatch_fields src adapter dest
    if ! parsed_dispatch_fields="$(parse_job_line "$job")"; then
        log_error "_dispatch_handle_job: malformed dispatch token: $job"
        return 1
    fi
    # parse_job_line emits three newline-separated fields; read them line-by-line.
    { read -r src; read -r adapter; read -r dest; } <<< "$parsed_dispatch_fields"
    bash "$ROOT_DIR/lib/dispatch.sh" "$adapter" "$src" "$dest"
}

# =============================================================================
# dispatch_worker
# =============================================================================

# ─── dispatch_worker ──────────────────────────────────────────────────────────
# Dispatch-stage worker. Runs as a background process (spawned with &) by
# _run_worker_pass. Pops jobs from DISPATCH_QUEUE_DIR and passes each to
# _dispatch_handle_job in a loop. When the queue is momentarily empty, sleeps
# with an exponential backoff before polling again. Exits when the queue is
# empty AND the .extract_done sentinel exists (written by _run_worker_pass after
# all extract workers have exited), signalling no more jobs are coming.
#
# Parameters  : none (job tokens are consumed from DISPATCH_QUEUE_DIR)
#
# Returns
#   0 — all dispatch jobs completed successfully
#   1 — one or more dispatch jobs failed
#
# Modifies
#   DISPATCH_QUEUE_DIR — jobs are popped as they are processed
#
# Locals
#   job          — current dispatch job token popped from the queue
#   fail_count   — count of jobs for which _dispatch_handle_job returned non-zero;
#                  drives the worker's exit code
#   poll_delay_ms — current poll sleep interval in integer milliseconds; starts at
#                   DISPATCH_POLL_INITIAL_MS (default 50ms) and doubles on each
#                   empty-queue poll, capped at poll_max_ms; reset to the initial
#                   value on each successful queue_pop so a burst of new jobs is
#                   picked up immediately without a long sleep penalty
#   poll_max_ms  — ceiling for the exponential poll backoff, from
#                  DISPATCH_POLL_MAX_MS (default 500ms); stored as a local to
#                  avoid repeated environment lookups inside the tight poll loop
# ──────────────────────────────────────────────────────────────────────────────
dispatch_worker() {
    log_enter
    # Integer-millisecond backoff: avoids a fork/exec of awk on every poll cycle.
    local job fail_count=0 pop_rc
    local poll_delay_ms="${DISPATCH_POLL_INITIAL_MS:-50}"
    local poll_max_ms="${DISPATCH_POLL_MAX_MS:-500}"

    while true; do
        pop_rc=0
        job=$(queue_pop "$DISPATCH_QUEUE_DIR") || pop_rc=$?
        case "$pop_rc" in
            0)
                poll_delay_ms="${DISPATCH_POLL_INITIAL_MS:-50}"   # reset on successful pop
                if ! _dispatch_handle_job "$job"; then
                    log_error "dispatch failed: $job"
                    (( fail_count++ )) || true
                fi
                continue
                ;;
            1) : ;;                       # queue empty — fall through to sentinel check
            *)
                log_error "dispatch_worker: queue_pop returned error (rc=$pop_rc); aborting this worker"
                (( fail_count++ )) || true
                break
                ;;
        esac
        # Queue empty — exit once extraction is also done.
        [[ -f "$QUEUE_DIR/.extract_done" ]] && break
        # Sleep then double the backoff, capped at the maximum.
        sleep "$(printf '%d.%03d' $(( poll_delay_ms / 1000 )) $(( poll_delay_ms % 1000 )))"
        (( poll_delay_ms = poll_delay_ms * 2 > poll_max_ms ? poll_max_ms : poll_delay_ms * 2 ))
    done

    return $(( fail_count > 0 ? 1 : 0 ))
}
