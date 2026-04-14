#!/usr/bin/env bash
# sourced by lib/extract.sh — do not execute directly
# =============================================================================
# SPACE LEDGER — shared reservation accounting for concurrent extract workers.
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# Without coordination, N concurrent workers all call `df`, all see the same
# free-byte count, all decide they fit, and collectively write N× the available
# space. This module prevents that with a flock-guarded ledger: every worker
# must atomically check-and-commit a reservation before touching the disk, so
# the actual bytes-in-flight are always subtracted from future workers' view.
#
# HOW THE LOCK WORKS
# ------------------
# space_reserve opens a file descriptor on $QUEUE_DIR/.space_ledger.lock and
# acquires an exclusive flock on it (flock -x). The entire read-ledger →
# call-df → arithmetic → append sequence executes inside the lock and releases
# only when the subshell exits. This means:
#
#   - There is no window between "decide I fit" and "record that I claimed
#     space" where a sibling worker can read a stale ledger.
#   - `df` is called from INSIDE the lock, so it reflects the real filesystem
#     state at the moment the decision is made and the reservation is written
#     atomically with the check.
#   - _space_dev (stat) is called outside the lock because device IDs are
#     stable and that call has no effect on the decision; only `df` matters.
#
# PHANTOM RECOVERY
# ----------------
# A worker SIGKILL'd mid-reservation cannot run its EXIT trap and therefore
# cannot call space_release. Without intervention its ledger line would block
# siblings from ever reserving that space, producing a livelock that the
# retry backoff in workers.sh cannot escape (the "fast-fail only when the
# ledger is empty" branch never fires). To defeat that, every ledger entry
# carries the worker BASHPID as a 6th field. space_reserve runs a GC pass
# inside the lock that drops any entries whose owner PID no longer passes
# `kill -0`, so phantoms stop counting against capacity as soon as any
# sibling next enters space_reserve. space_ledger_empty applies the same
# liveness filter when deciding whether to fast-fail a waiting worker.
#
# SAME-FILESYSTEM POOLING
# -----------------------
# When COPY_DIR and EXTRACT_DIR share a mount (same stat -c %d device number),
# checking each independently would double-count free space. In that case the
# code pools all in-flight copy+extract reservations against a single df call
# and requires (archive + extracted) × overhead bytes of headroom together.
#
# OVERHEAD BUDGET
# ---------------
# SPACE_OVERHEAD_PCT (default 20) inflates the raw byte requirement before
# comparing against available space. This covers filesystem metadata, any
# sparse→dense expansion, 7z's own temp files, and general slack.
# Required = (archive_bytes + extracted_bytes) × (1 + SPACE_OVERHEAD_PCT/100).
#
# RESERVATION LIFECYCLE
# ---------------------
# Reservations are held from just before cp runs until the EXIT trap in
# lib/extract.sh fires (success, error, or SIGTERM). SIGKILL cannot trigger
# the trap, but workers_start calls space_init at the top of every pipeline
# run, which truncates the ledger — so stale entries from a killed worker
# never leak into a subsequent run.
#
# LEDGER FORMAT
# -------------
# One line per active reservation:
#     <id> <copy_dev> <copy_bytes> <extract_dev> <extract_bytes> <owner_pid>
# <copy_dev>/<extract_dev> are stat -c %d device numbers.
# <owner_pid> is the BASHPID of the worker holding the reservation and is
# consumed by the PHANTOM RECOVERY GC path.
#
# TEST HOOKS
# ----------
# SPACE_AVAIL_OVERRIDE_BYTES — when set, replaces the real df lookup so tests
# can simulate a small filesystem without root/tmpfs privileges.
# =============================================================================

# ─── _space_ledger_path ───────────────────────────────────────────────────────
# Returns the absolute path to the space reservation ledger file. Centralising
# this path in one function ensures every caller uses the identical path and
# eliminates the risk of typos or divergence if QUEUE_DIR changes.
#
# Parameters  : none
# Returns     : 0 always; prints the ledger path to stdout
# Modifies    : nothing
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
# ─── _space_lock_path ─────────────────────────────────────────────────────────
# Returns the absolute path to the flock lock file that serialises all ledger
# reads and writes. All space_reserve / space_release / _space_ledger_gc_phantoms
# calls acquire an exclusive flock on this file before touching the ledger.
#
# Parameters  : none
# Returns     : 0 always; prints the lock file path to stdout
# Modifies    : nothing
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
_space_ledger_path()    { printf '%s' "$QUEUE_DIR/.space_ledger"; }
_space_lock_path()      { printf '%s' "$QUEUE_DIR/.space_ledger.lock"; }

# ─── space_init ───────────────────────────────────────────────────────────────
# Initialises the space ledger and its lock file to an empty, trusted state.
# Called once at the top of every pipeline run so stale entries from a previous
# run (including entries left by SIGKILL'd workers whose EXIT traps never fired)
# are discarded before any worker begins reserving space.
#
# Any pre-existing file at either path is removed before the new empty file is
# created. This severs any symlink an attacker might have planted at that path
# (rm -f removes the symlink itself, not its target).
#
# Parameters  : none
# Returns     : 0 always
# Modifies    : filesystem — creates/truncates $QUEUE_DIR/.space_ledger and
#               $QUEUE_DIR/.space_ledger.lock as empty regular files
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
space_init() {
    mkdir -p "$QUEUE_DIR"
    # Remove before creating: if a malicious actor planted a symlink at either
    # of these paths, `rm -f` removes the symlink itself (not its target), and
    # the subsequent `: >` creates a fresh regular file owned by us.
    rm -f -- "$(_space_ledger_path)"
    : > "$(_space_ledger_path)"
    rm -f -- "$(_space_lock_path)"
    : > "$(_space_lock_path)"
}

# ─── _space_dev ───────────────────────────────────────────────────────────────
# Returns the filesystem device ID (stat -c %d) of the given path, walking up
# to the nearest existing ancestor when the target directory does not yet exist.
# Used to determine whether the copy spool and extract directory share the same
# mount so the reservation logic can decide whether to pool their byte counts
# against a single df value or check them independently.
#
# Parameters
#   $1  path — directory path to resolve (need not exist yet)
#
# Returns     : 0 always; prints the numeric device ID to stdout (or "0" on error)
# Modifies    : nothing
#
# Locals
#   p — working path variable; starts as $1 and has its last component stripped
#       with ${p%/*} until an existing filesystem entry is found
# ──────────────────────────────────────────────────────────────────────────────
_space_dev() {
    # Stat the nearest existing ancestor — the target dir may not exist yet
    # the first time a worker reserves against it.
    local p="$1"
    while [[ -n "$p" && ! -e "$p" ]]; do p="${p%/*}"; done
    [[ -z "$p" ]] && p="/"
    stat -c %d "$p" 2>/dev/null || echo 0
}

# ─── _space_avail_bytes ───────────────────────────────────────────────────────
# Returns the number of bytes currently available on the filesystem containing
# the given path. Walks up to the nearest existing ancestor when the target
# directory does not yet exist. When the test hook SPACE_AVAIL_OVERRIDE_BYTES
# is set, that value is returned instead of calling df, allowing tests to
# simulate a small filesystem without root or tmpfs privileges.
#
# Parameters
#   $1  path — directory path whose filesystem to query (need not exist yet)
#
# Returns     : 0 always; prints the available byte count to stdout as a plain integer
# Modifies    : nothing
#
# Locals
#   p — working path variable; trimmed up the directory tree until an existing
#       entry is found, then passed to df
# ──────────────────────────────────────────────────────────────────────────────
_space_avail_bytes() {
    if [[ -n "${SPACE_AVAIL_OVERRIDE_BYTES:-}" ]]; then
        printf '%s' "$SPACE_AVAIL_OVERRIDE_BYTES"
        return 0
    fi
    local p="$1"
    while [[ -n "$p" && ! -e "$p" ]]; do p="${p%/*}"; done
    [[ -z "$p" ]] && p="/"
    df --output=avail -B1 "$p" 2>/dev/null | tail -n1 | tr -d ' '
}

# ─── _space_reserved_on_dev ───────────────────────────────────────────────────
# Sums the bytes already committed in the ledger for a given device ID,
# filtered by reservation role. Used by space_reserve to determine how much of
# a device's free space is already spoken for by sibling workers before
# deciding whether a new reservation fits.
#
# Parameters
#   $1  dev  — numeric device ID (from stat -c %d) to sum reservations for
#   $2  mode — which ledger columns to include in the sum:
#                "copy"    — only the copy_bytes column (field 3)
#                "extract" — only the extract_bytes column (field 5)
#                "both"    — copy_bytes + extract_bytes for the matching device
#                            (used when copy and extract dirs share a filesystem)
#
# Returns     : 0 always; prints the total reserved byte count to stdout (0 if none)
# Modifies    : nothing — reads the ledger file but never writes it
#
# Locals
#   dev    — $1 captured as a named local
#   mode   — $2 captured as a named local
#   ledger — path to the ledger file (from _space_ledger_path)
# ──────────────────────────────────────────────────────────────────────────────
_space_reserved_on_dev() {
    local dev="$1" mode="$2" ledger
    ledger="$(_space_ledger_path)"
    [[ -f "$ledger" ]] || { echo 0; return; }
    awk -v dev="$dev" -v mode="$mode" '
        {
            total = 0
            if (mode == "copy"    && $2 == dev) total += $3
            if (mode == "extract" && $4 == dev) total += $5
            if (mode == "both") {
                if ($2 == dev) total += $3
                if ($4 == dev) total += $5
            }
            sum += total
        }
        END { print sum+0 }
    ' "$ledger"
}

# ─── _space_apply_overhead ────────────────────────────────────────────────────
# Inflates a raw byte count by the configured overhead percentage and returns
# the result. The overhead covers filesystem metadata, potential sparse-to-dense
# expansion during extraction, 7z's own temp files, and general slack.
# Formula: result = bytes × (100 + SPACE_OVERHEAD_PCT) / 100  (integer division)
#
# Parameters
#   $1  bytes — raw byte count to inflate (e.g. archive size + extracted size)
#
# Returns     : 0 always; prints the inflated byte count to stdout
# Modifies    : nothing
#
# Locals
#   bytes — $1 captured as a named local
#   pct   — SPACE_OVERHEAD_PCT from the environment (default 20); the percentage
#           by which to inflate: 20 → ×1.20, 50 → ×1.50, etc.
# ──────────────────────────────────────────────────────────────────────────────
_space_apply_overhead() {
    local bytes="$1" pct="${SPACE_OVERHEAD_PCT:-20}"
    # integer math: bytes * (100 + pct) / 100
    echo $(( bytes * (100 + pct) / 100 ))
}

# ─── _space_ledger_gc_phantoms ────────────────────────────────────────────────
# Removes ledger entries whose owner PID is no longer alive. A SIGKILL'd worker
# cannot run its EXIT trap and therefore cannot call space_release, leaving its
# ledger line as a "phantom" that would otherwise permanently block sibling
# workers from reserving space (livelock). This function evicts those phantoms.
#
# MUST be called with the exclusive ledger flock already held — it rewrites the
# ledger file in place and is not safe for concurrent execution. Uses an awk
# subprocess with system("kill -0 <pid>") so the liveness check and file rewrite
# happen atomically within awk, with no window for a new entry to be appended
# between reading and writing.
#
# Parameters  : none
# Returns     : 0 always (no-op when the ledger is missing or empty)
# Modifies    : $QUEUE_DIR/.space_ledger — rewritten in place; any entry whose
#               owner PID fails kill -0 is removed
#
# Locals
#   ledger — path to the ledger file (from _space_ledger_path)
#   tmp    — temporary file path "<ledger>.gc.<BASHPID>" used as the awk output
#            target before an atomic mv replaces the ledger
# ──────────────────────────────────────────────────────────────────────────────
_space_ledger_gc_phantoms() {
    local ledger tmp
    ledger="$(_space_ledger_path)"
    [[ -s "$ledger" ]] || return 0
    tmp="${ledger}.gc.$BASHPID"
    awk '{
        if (system("kill -0 " $6 " 2>/dev/null") == 0) print
    }' "$ledger" > "$tmp" && mv "$tmp" "$ledger"
}

# ─── space_reserve ────────────────────────────────────────────────────────────
# Atomically checks whether the scratch filesystem has room for a new archive
# and, if so, commits a reservation to the shared ledger. All logic (GC →
# df → arithmetic → append) executes inside an exclusive flock so concurrent
# workers cannot collectively overshoot available free space.
#
# When the copy spool and extract directory share the same filesystem (same
# device ID), their byte requirements are pooled against a single df value.
# When they are on different filesystems, each is checked independently.
#
# Parameters
#   $1  id            — unique reservation key (e.g. "extract.$BASHPID"); used
#                       by space_release to locate and remove this entry later
#   $2  copy_dir      — scratch directory where the .7z copy will land
#   $3  copy_bytes    — size of the archive file in bytes (from stat -c %s)
#   $4  extract_dir   — directory where 7z will write extracted members
#   $5  extract_bytes — total uncompressed size of all archive members (from 7z l)
#
# Returns
#   0 — reservation committed; caller may proceed with copy + extract
#   1 — does not fit right now; caller should sleep and retry later
#
# Modifies
#   $QUEUE_DIR/.space_ledger — appends one line on success:
#     "<id> <cdev> <cbytes> <edev> <ebytes> <owner_pid>"
#
# Locals
#   lock          — path to the flock lock file (from _space_lock_path)
#   ledger        — path to the space ledger file (from _space_ledger_path)
#   cdev          — device ID of copy_dir (stat -c %d); used to match ledger entries
#   edev          — device ID of extract_dir (stat -c %d)
#   owner_pid     — BASHPID captured BEFORE the flock subshell; inside the subshell
#                   $BASHPID is the subshell's own PID, not the worker's
#   total_need    — overhead-inflated combined byte requirement when cdev == edev
#   total_reserved — sum of all in-flight copy+extract bytes on the shared device
#   avail         — bytes available on the shared device (from df or override)
#   need_c        — overhead-inflated copy bytes when devices differ
#   need_e        — overhead-inflated extract bytes when devices differ
#   avail_c       — bytes available on the copy device
#   avail_e       — bytes available on the extract device
#   reserved_c    — bytes already reserved for copy operations on the copy device
#   reserved_e    — bytes already reserved for extract operations on the extract device
# ──────────────────────────────────────────────────────────────────────────────
space_reserve() {
    local id="$1" cdir="$2" cbytes="$3" edir="$4" ebytes="$5"
    local lock ledger cdev edev owner_pid
    lock="$(_space_lock_path)"
    ledger="$(_space_ledger_path)"
    mkdir -p "$QUEUE_DIR"
    [[ -f "$lock" ]]   || : > "$lock"
    [[ -f "$ledger" ]] || : > "$ledger"

    cdev="$(_space_dev "$cdir")"
    edev="$(_space_dev "$edir")"
    # Capture the caller's PID here, BEFORE the flock subshell. Inside the
    # subshell $BASHPID is the subshell itself, which is not the worker that
    # owns the reservation and will not be what `kill -0` needs to check.
    owner_pid=$BASHPID

    (
        flock -x 9
        # GC phantoms left by SIGKILL'd siblings so capacity math reflects
        # only live reservations. Runs inside the lock so no one appends
        # concurrently.
        _space_ledger_gc_phantoms
        local need_c need_e avail_c avail_e reserved_c reserved_e
        if [[ "$cdev" == "$edev" ]]; then
            # Shared filesystem: copy+extract pool against one free-space number.
            local total_need total_reserved avail
            total_need="$(_space_apply_overhead $(( cbytes + ebytes )))"
            total_reserved="$(_space_reserved_on_dev "$cdev" both)"
            avail="$(_space_avail_bytes "$cdir")"
            if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
                log_warn "space_reserve: df returned non-numeric for $cdir — treating as no-fit"
                exit 1
            fi
            if (( total_need > avail - total_reserved )); then
                exit 1
            fi
        else
            need_c="$(_space_apply_overhead "$cbytes")"
            need_e="$(_space_apply_overhead "$ebytes")"
            avail_c="$(_space_avail_bytes "$cdir")"
            avail_e="$(_space_avail_bytes "$edir")"
            if [[ ! "$avail_c" =~ ^[0-9]+$ || ! "$avail_e" =~ ^[0-9]+$ ]]; then
                log_warn "space_reserve: df returned non-numeric — treating as no-fit"
                exit 1
            fi
            reserved_c="$(_space_reserved_on_dev "$cdev" copy)"
            reserved_e="$(_space_reserved_on_dev "$edev" extract)"
            if (( need_c > avail_c - reserved_c )); then exit 1; fi
            if (( need_e > avail_e - reserved_e )); then exit 1; fi
        fi
        printf '%s %s %s %s %s %s\n' "$id" "$cdev" "$cbytes" "$edev" "$ebytes" "$owner_pid" >> "$ledger"
        exit 0
    ) 9>"$lock"
}

# ─── space_release ────────────────────────────────────────────────────────────
# Removes a previously committed reservation from the space ledger. Called by
# the EXIT trap in lib/extract.sh on every exit path (success, error, SIGTERM)
# so sibling workers can reclaim the space immediately when an extract finishes.
# A no-op when the ledger does not exist or contains no matching entry.
#
# Parameters
#   $1  id — reservation key that was passed to space_reserve
#            (e.g. "extract.$BASHPID")
#
# Returns     : 0 always
# Modifies    : $QUEUE_DIR/.space_ledger — the line matching $id is removed in place
#
# Locals
#   id     — $1 captured as a named local; matched against ledger field 1
#   lock   — path to the flock lock file
#   ledger — path to the space ledger file
#   tmp    — temporary file path "<ledger>.tmp.<BASHPID>" used as the awk output
#            target before an atomic mv replaces the ledger
# ──────────────────────────────────────────────────────────────────────────────
space_release() {
    local id="$1" lock ledger tmp
    lock="$(_space_lock_path)"
    ledger="$(_space_ledger_path)"
    [[ -f "$ledger" ]] || return 0
    (
        flock -x 9
        tmp="${ledger}.tmp.$BASHPID"
        awk -v id="$id" '$1 != id' "$ledger" > "$tmp" && mv "$tmp" "$ledger"
    ) 9>"$lock"
}

# ─── space_ledger_empty ───────────────────────────────────────────────────────
# Reports whether the ledger currently holds any LIVE reservations. Phantoms
# (entries whose owner PID no longer passes kill -0) are treated as absent so
# the retry backoff in workers.sh can fast-fail correctly after a SIGKILL storm
# instead of waiting forever on reservations that will never be released.
#
# Called by _unzip_handle_job immediately after a failed space_reserve to decide
# whether the archive is permanently too large for the filesystem (ledger empty →
# no siblings hold space → waiting cannot help) or whether it should sleep and
# retry (siblings are still actively using scratch space).
#
# Intentionally lock-free: space_reserve already ran a GC pass inside its lock
# moments before this is called, so phantoms are nearly always already gone. A
# concurrent space_reserve from another worker could add a new entry between our
# read and the caller's decision — in the worst case this causes one extra retry.
#
# Parameters  : none
#
# Returns
#   0 — ledger is effectively empty (no file, empty file, or only phantom entries)
#   1 — at least one live reservation exists (a sibling worker is actively running)
#
# Modifies    : nothing — reads the ledger file but never writes it
#
# Locals
#   ledger    — path to the ledger file (from _space_ledger_path)
#   owner_pid — PID field (field 6) of each ledger line; tested with kill -0
# ──────────────────────────────────────────────────────────────────────────────
space_ledger_empty() {
    local ledger owner_pid
    ledger="$(_space_ledger_path)"
    [[ -f "$ledger" ]] || return 0
    [[ -s "$ledger" ]] || return 0
    while read -r _ _ _ _ _ owner_pid; do
        [[ -n "$owner_pid" ]] || continue
        kill -0 "$owner_pid" 2>/dev/null && return 1
    done < "$ledger"
    return 0
}
