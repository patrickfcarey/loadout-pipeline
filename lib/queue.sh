#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly
#
# File-based FIFO queue keyed off a directory path. The caller passes the
# queue dir to every function so multiple queues (extract, dispatch, ...)
# can coexist without colliding. See lib/workers.sh for typical use.

# ─── queue_init ───────────────────────────────────────────────────────────────
# Creates the queue directory and removes any leftover .job and .claimed.*
# files from a previous run. Called once per queue at pipeline startup and
# before each recovery pass to ensure a clean slate.
#
# Parameters
#   $1  qdir — path to the queue directory (e.g. $EXTRACT_QUEUE_DIR)
#
# Returns     : 0 always (mkdir -p and find -delete are tolerant of pre-existing state)
# Modifies    : filesystem — creates qdir if absent; deletes stale job files inside it
#
# Locals
#   qdir — $1 captured as a named local; used as the target for mkdir and find
# ──────────────────────────────────────────────────────────────────────────────
queue_init() {
    log_enter
    local qdir="$1"
    mkdir -p "$qdir"
    # Remove leftover .job and .claimed.* files from previous runs.
    # Using find -delete avoids the empty-dir nullglob ambiguity that
    # rm -rf glob has when no files match.
    find "$qdir" -maxdepth 1 \( -name "*.job" -o -name "*.claimed.*" \) -delete
}

# ─── queue_push ───────────────────────────────────────────────────────────────
# Writes a job string to the queue directory as a timestamped .job file. The
# filename encodes a nanosecond timestamp plus BASHPID so pushes from concurrent
# processes produce unique, naturally-sorted filenames that queue_pop drains in
# FIFO order.
#
# Parameters
#   $1  qdir      — path to the queue directory
#   $2  input_job — the job string to enqueue (e.g. "~path/to/game.7z|sd|dest~")
#
# Returns     : 0 always
# Modifies    : filesystem — creates one file named "<nanosec>.<pid>.job" in qdir
#               containing the job string
#
# Locals
#   qdir      — $1 captured as a named local
#   input_job — $2 captured as a named local
#   id        — unique filename stem: "$(date +%s%N).$BASHPID"
# ──────────────────────────────────────────────────────────────────────────────
queue_push() {
    log_enter
    local qdir="$1" input_job="$2" id
    # Append $BASHPID to the nanosecond timestamp so filenames stay unique
    # even if push is ever called concurrently from multiple processes.
    id="$(date +%s%N).$BASHPID"
    echo "$input_job" > "$qdir/$id.job"
}

# ─── queue_pop ────────────────────────────────────────────────────────────────
# Atomically claims and returns the oldest available job in the queue directory.
# Multiple concurrent workers may call queue_pop simultaneously; the atomic mv
# rename ensures each job is returned to exactly one caller. Callers that lose
# the mv race for a given file move on to the next candidate rather than giving
# up. Returns 1 (and prints nothing) when the queue is empty.
#
# Parameters
#   $1  qdir — path to the queue directory to pop from
#
# Returns
#   0 — success; the claimed job string is printed to stdout
#   1 — queue is empty (no .job files remain unclaimed)
#
# Modifies    : filesystem — removes the claimed .job file from qdir
#
# Locals
#   qdir    — $1 captured as a named local
#   file    — absolute path to a candidate .job file from the sorted find list
#   claimed — temporary path used during the atomic mv claim:
#             "<file>.claimed.<BASHPID>"; deleted immediately after cat
# ──────────────────────────────────────────────────────────────────────────────
queue_pop() {
    log_enter
    local qdir="$1" file claimed
    # Sort the glob explicitly. Bash expands globs in the shell's collation
    # order which is "almost" chronological for our <nanosec>.<pid>.job
    # filenames — but not guaranteed under pid wraparound or clock skew.
    # `sort` on the same filenames gives a reliable FIFO order.
    while IFS= read -r file; do
        # No [[ -e "$file" ]] guard here: if a sibling worker already claimed
        # this entry, the mv below will fail and `|| continue` moves us on to
        # the next candidate. An `|| return 1` guard here would abandon the
        # rest of the list on the first lost race — silently collapsing
        # parallelism under contention.
        # Use $BASHPID (real PID of this process), NOT $$ (parent PID).
        # In background subshells spawned with &, $$ returns the parent
        # script's PID — all workers would share the same claimed suffix.
        # $BASHPID always reflects the actual current process.
        claimed="${file}.claimed.$BASHPID"
        # mv is atomic on the same filesystem: only one worker can win this
        # race for a given source path.
        mv "$file" "$claimed" 2>/dev/null || continue
        cat "$claimed"
        rm -f "$claimed"
        return 0
    done < <(find "$qdir" -maxdepth 1 -name '*.job' -print 2>/dev/null | sort)
    return 1
}
