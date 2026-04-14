#!/usr/bin/env bash
# sourced by lib/workers.sh — do not execute directly
# =============================================================================
# WORKER REGISTRY — tracks which job each active extract worker is processing.
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# queue_pop removes a job from the queue atomically before any work begins.
# If a worker is SIGKILL'd mid-job, the job simply vanishes — nothing re-queues
# it and no other worker picks it up in the current run.
#
# The registry bridges that gap. Each worker writes its current job here when
# it starts processing and removes it when it finishes (success, failure, or
# space-retry re-queue). After all workers exit, anything still in the registry
# was abandoned mid-flight. workers_start's recovery loop re-queues those jobs
# and runs another worker pass to complete them.
#
# FORMAT
# ------
# One line per active job: "<worker_pid> <job_string>\n"
# Space separates the PID from the rest of the line; job strings start with
# '~' and cannot contain newlines so the remainder-of-line is always the job.
#
# LOCK
# ----
# All mutations are guarded by an exclusive flock on .worker_registry.lock so
# concurrent workers never corrupt each other's entries.
# =============================================================================

# ─── _wr_path ─────────────────────────────────────────────────────────────────
# Returns the absolute path to the worker registry file. Centralising this path
# ensures every caller uses the same string and avoids divergence if QUEUE_DIR
# is ever changed.
#
# Parameters  : none
# Returns     : 0 always; prints the registry path to stdout
# Modifies    : nothing
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
# ─── _wr_lock_path ────────────────────────────────────────────────────────────
# Returns the absolute path to the flock lock file that serialises all registry
# reads and writes. Every worker_job_begin, worker_job_end, and
# worker_registry_recover call acquires an exclusive flock on this file before
# touching the registry.
#
# Parameters  : none
# Returns     : 0 always; prints the lock file path to stdout
# Modifies    : nothing
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
_wr_path()      { printf '%s' "$QUEUE_DIR/.worker_registry"; }
_wr_lock_path() { printf '%s' "$QUEUE_DIR/.worker_registry.lock"; }

# ─── worker_registry_init ─────────────────────────────────────────────────────
# Initialises the worker registry and its lock file to a clean empty state.
# Called once at the start of every pipeline run (and before each recovery pass)
# so any stale entries from killed workers in the prior run are discarded.
#
# Removes any pre-existing file before creating a fresh empty one, severing any
# symlink an attacker might have planted at either path.
#
# Parameters  : none
# Returns     : 0 always
# Modifies    : filesystem — creates/truncates $QUEUE_DIR/.worker_registry and
#               $QUEUE_DIR/.worker_registry.lock as empty regular files
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
worker_registry_init() {
    mkdir -p "$QUEUE_DIR"
    # Remove before creating so a pre-planted symlink is severed rather than
    # followed. rm -f on a symlink removes the link itself, not the target.
    rm -f -- "$(_wr_path)"
    : > "$(_wr_path)"
    rm -f -- "$(_wr_lock_path)"
    : > "$(_wr_lock_path)"
}

# ─── worker_job_begin ─────────────────────────────────────────────────────────
# Records that a worker process has claimed a job and is about to begin
# processing it. Called immediately after queue_pop, before bash extract.sh
# runs. If the worker is SIGKILL'd after this point but before worker_job_end,
# its entry remains in the registry so worker_registry_recover can re-queue it.
#
# Any pre-existing entry for this PID is removed before the new one is appended
# (safety guard against a worker calling begin twice without an intervening end).
#
# Parameters
#   $1  pid — BASHPID of the worker process claiming the job; used as the
#             registry key for lookup by worker_job_end and worker_registry_recover
#   $2  job — full job string being claimed (e.g. "~path/to/game.7z|sd|dest~")
#
# Returns     : 0 always
# Modifies    : $QUEUE_DIR/.worker_registry — appends "<pid> <job>\n"
#
# Locals
#   pid  — $1 captured as a named local
#   job  — $2 captured as a named local
#   reg  — path to the registry file (from _wr_path)
#   lock — path to the flock lock file (from _wr_lock_path)
#   tmp  — temporary file path "<reg>.tmp.<BASHPID>" used for atomic rewrite
#          that removes any stale entry for this PID before appending the new one
# ──────────────────────────────────────────────────────────────────────────────
worker_job_begin() {
    local pid="$1" job="$2"
    local reg lock
    reg="$(_wr_path)"
    lock="$(_wr_lock_path)"
    (
        flock -x 9
        # Remove any stale entry for this pid first (safety), then append.
        # If awk fails, rm the tmp orphan rather than leaving it behind.
        local tmp="${reg}.tmp.$BASHPID"
        if awk -v pid="$pid" '$1 != pid' "$reg" > "$tmp"; then
            mv "$tmp" "$reg"
        else
            rm -f -- "$tmp"
        fi
        printf '%s %s\n' "$pid" "$job" >> "$reg"
    ) 9>"$lock"
}

# ─── worker_job_end ───────────────────────────────────────────────────────────
# Removes a worker's entry from the registry. Called when a worker finishes
# handling a job — whether it succeeded, failed cleanly, or re-queued the job
# for a space-retry. A missing entry (worker never registered, or entry already
# removed) is a silent no-op, so double-calls are safe.
#
# Parameters
#   $1  pid — BASHPID of the worker whose entry should be removed; matches
#             the key written by the corresponding worker_job_begin call
#
# Returns     : 0 always
# Modifies    : $QUEUE_DIR/.worker_registry — the line whose first field matches
#               $pid is removed in place; file is unchanged if no match exists
#
# Locals
#   pid  — $1 captured as a named local; passed to awk as the filter key
#   reg  — path to the registry file (from _wr_path)
#   lock — path to the flock lock file (from _wr_lock_path)
#   tmp  — temporary file path "<reg>.tmp.<BASHPID>" used for the atomic awk rewrite
# ──────────────────────────────────────────────────────────────────────────────
worker_job_end() {
    local pid="$1"
    local reg lock tmp
    reg="$(_wr_path)"
    lock="$(_wr_lock_path)"
    [[ -f "$reg" ]] || return 0
    (
        flock -x 9
        tmp="${reg}.tmp.$BASHPID"
        if awk -v pid="$pid" '$1 != pid' "$reg" > "$tmp"; then
            mv "$tmp" "$reg"
        else
            rm -f -- "$tmp"
        fi
    ) 9>"$lock"
}

# ─── worker_registry_recover ──────────────────────────────────────────────────
# Reads every job string still in the registry, prints them to stdout (one per
# line), then clears the registry. Called by _recover_orphans in workers.sh
# after all extract workers have exited. Any entry still present at that point
# belonged to a worker that was SIGKILL'd and could not call worker_job_end —
# those jobs were pulled off the queue but never completed, so they must be
# re-queued for a recovery pass.
#
# Parameters  : none
#
# Returns     : 0 always
# Modifies    : $QUEUE_DIR/.worker_registry — truncated to empty after all
#               entries have been printed; the lock file is left in place
#
# Locals
#   reg  — path to the registry file (from _wr_path)
#   lock — path to the flock lock file (from _wr_lock_path)
# ──────────────────────────────────────────────────────────────────────────────
worker_registry_recover() {
    local reg lock
    reg="$(_wr_path)"
    lock="$(_wr_lock_path)"
    [[ -f "$reg" ]] || return 0
    (
        flock -x 9
        # Print the job (everything after the first space on each line).
        #
        # DO NOT use `{ $1=""; sub(/^ /,""); print }` here. Assigning to $1
        # causes awk to rebuild $0 using OFS (default single space), which
        # COLLAPSES runs of whitespace anywhere in the job string. A job path
        # containing two consecutive spaces would come back with one space,
        # and the mismatched path would then fail to re-queue correctly.
        #
        # index-based split keeps $0 byte-exact: take everything after the
        # first space literally, with no field reconstruction.
        awk '{ i = index($0, " "); if (i > 0) print substr($0, i + 1) }' "$reg"
        rm -f -- "$reg"
        : > "$reg"
    ) 9>"$lock"
}
