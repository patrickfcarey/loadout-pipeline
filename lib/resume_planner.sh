#!/usr/bin/env bash
# =============================================================================
# RESUME PLANNER — cold-restart fast-path pre-pass.
# =============================================================================
# Problem
#   A power outage kills the pipeline mid-run. On restart, the same .jobs
#   file is re-submitted. Most jobs are already fully dispatched to the
#   local volume, but each one still forks bash + 7z and stats every member
#   through the full precheck path. On a 500-job run that's 500 bash forks
#   + 500 7z forks + thousands of stats against a slow volume before any useful
#   work happens.
#
# Solution
#   Run a synchronous pre-pass between _pipeline_run_init and the enqueue
#   loop in workers_start(). The pre-pass reads the global JOBS array in
#   place and drops every job whose content is already fully present at
#   the adapter destination. Surviving jobs fall through to the existing
#   pipeline (including the per-job precheck) unchanged — the planner only
#   removes jobs, never adds or mutates them.
#
# Why this is safe
#   The planner runs in a quiescent window: no worker has forked yet, no
#   dispatch is happening, the destination is static. Staleness is
#   structurally impossible because the cache is only consulted during
#   this window. The planner can only produce false negatives (keep a job
#   that was actually satisfied — precheck catches it later), never false
#   positives, so accuracy is identical to the no-planner baseline.
#
# Cache shape
#   In-memory, per-run. Two associative arrays:
#     _resume_dest_cache    — key: absolute destination dir under LVOL_MOUNT_POINT
#                             value: NUL-delimited relative paths of every
#                                    file/symlink beneath that dir (one readdir
#                                    per unique destination, not per job)
#     _resume_archive_cache — key: absolute archive path
#                             value: newline-delimited strip-filtered member list
#                                    (memoised so the same archive referenced
#                                    by multiple job lines only pays one 7z l)
#
# Scope
#   lvol adapter only. ftp/rclone/rsync precheck is a stub and hdl precheck
#   is a single hdl_dump toc call — planning them buys nothing. If those
#   adapters gain cheap-skip precheck implementations later, add per-adapter
#   branches in resume_plan.
#
# Disable switch
#   RESUME_PLANNER_IND=0 bypasses the planner entirely. Useful for forced
#   full re-verification during debugging. The disabled path logs once
#   and returns early, so nothing downstream changes behaviour.
#
# Future extensions (deliberately out of scope for v1)
#   * Persistent archive-member sidecar cache (skip the 7z l on subsequent
#     runs). Adds cache format + invalidation complexity — deferred.
#   * Common-parent destination walk (one find $SD/games instead of N
#     finds across $SD/games/game1, $SD/games/game2, ...). Deferred —
#     simple per-dest walk is auditable and the main big-O win (one
#     readdir per unique dest vs N stats per job × M members) is already
#     captured.
# =============================================================================

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/job_format.sh"
source "$ROOT_DIR/lib/strip_list.sh"

# ─── _resume_plan_member_is_safe ──────────────────────────────────────────────
# Rejects archive-member filenames that could escape the destination directory
# when appended as a relative path. Structural twin of _precheck_member_is_safe
# in lib/precheck.sh (lines 139-150). precheck.sh is always forked as a
# subprocess so its helpers cannot be sourced; duplicating 7 lines is cheaper
# than refactoring the fork boundary.
#
# Keep the two copies in sync when either side changes.
#
# Parameters
#   $1  member — archive-member filename as emitted by `7z l -slt` Path line
#
# Returns
#   0 — safe relative path
#   1 — unsafe (absolute, contains '..', empty, or contains newline)
#
# Locals
#   member — $1 captured as a named local
# ──────────────────────────────────────────────────────────────────────────────
_resume_plan_member_is_safe() {
    local member="$1"
    [[ -n "$member" ]]                    || return 1
    [[ "$member" != /* ]]                 || return 1
    [[ "$member" != *$'\n'* ]]            || return 1
    [[ ! "$member" =~ (^|/)\.\.(/|$) ]]   || return 1
    return 0
}

# ─── _resume_plan_dest_for_job ────────────────────────────────────────────────
# Resolves the lvol adapter destination for a job and verifies it stays inside
# LVOL_MOUNT_POINT. Mirrors the containment guard at lib/precheck.sh:159-174.
# Fails closed on any containment escape so the caller keeps the job — precheck
# will then issue its authoritative exit 2.
#
# Parameters
#   $1  dest — adapter destination field from the job line
#
# Returns
#   0 — prints the canonical absolute destination path to stdout; safe to use
#   1 — containment escape or realpath unavailable; nothing printed; caller
#       must keep the job and defer to precheck
#
# Locals
#   dest                  — $1 captured as a named local
#   local_root            — "$LVOL_MOUNT_POINT/$dest" before canonicalisation
#   local_root_canonical  — realpath -m of local_root
#   mount_canonical       — realpath -m of LVOL_MOUNT_POINT
# ──────────────────────────────────────────────────────────────────────────────
_resume_plan_dest_for_job() {
    local dest="$1"
    command -v realpath >/dev/null 2>&1 || return 1
    local local_root="${LVOL_MOUNT_POINT%/}/${dest#/}"
    local local_root_canonical mount_canonical
    local_root_canonical="$(realpath -m "$local_root")" || return 1
    mount_canonical="$(realpath -m "${LVOL_MOUNT_POINT%/}")" || return 1
    case "${local_root_canonical}/" in
        "${mount_canonical}/"*) printf '%s\n' "$local_root_canonical"; return 0 ;;
    esac
    return 1
}

# ─── _resume_plan_load_dest_cache ─────────────────────────────────────────────
# Populates _resume_dest_cache[$dir] with a NUL-delimited set of every file
# and symlink beneath $dir (relative to $dir). Uses `-type f -o -type l` so
# the membership test matches the follow-symlinks semantics of `[[ -e ]]`
# used by precheck.sh at line 191.
#
# Missing dirs store an empty string so every subsequent membership test
# cleanly misses.
#
# Parameters
#   $1  dir — absolute destination directory to scan
#
# Returns     : 0 always
# Modifies
#   _resume_dest_cache[$dir] — populated with NUL-joined relative paths
#
# Locals
#   dir     — $1 captured as a named local
#   payload — accumulated NUL-delimited path set read from find
# ──────────────────────────────────────────────────────────────────────────────
_resume_plan_load_dest_cache() {
    local dir="$1"
    [[ -n "${_resume_dest_cache[$dir]+_}" ]] && return 0
    local payload=""
    if [[ -d "$dir" ]]; then
        payload="$(find "$dir" \( -type f -o -type l \) -printf '%P\0' 2>/dev/null)"
    fi
    _resume_dest_cache["$dir"]="$payload"
}

# ─── _resume_plan_archive_members ─────────────────────────────────────────────
# Memoised wrapper around `7z l -slt` that returns the strip-filtered list of
# archive members on stdout, one per line. Same parse as precheck.sh:98-100
# (tail -n +2 drops the archive's own Path line). Applies the same
# _resume_plan_member_is_safe guard as the precheck, so any unsafe member path
# in the archive causes the whole job to be kept (return 1) and precheck issues
# the authoritative refusal.
#
# The returned list is strip-aware: any member that strip_list_contains matches
# is dropped, matching the invariant at precheck.sh:190. An empty list after
# filtering is also treated as "cannot plan" — precheck.sh:103 issues exit 2
# for an empty archive, and we let it.
#
# Parameters
#   $1  archive — absolute path to the .7z archive
#
# Returns
#   0 — members printed to stdout (newline-delimited, strip-filtered, safe)
#   1 — 7z failed, archive unreadable, empty listing, or an unsafe member
#       was found; caller must keep the job
#
# Modifies
#   _resume_archive_cache[$archive] — populated on success with the member list
#
# Locals
#   archive — $1 captured as a named local
#   raw     — raw Path lines from 7z after tail -n +2
#   members — accumulated newline-delimited filtered list
#   line    — loop variable walking raw
# ──────────────────────────────────────────────────────────────────────────────
_resume_plan_archive_members() {
    local archive="$1"
    if [[ -n "${_resume_archive_cache[$archive]+_}" ]]; then
        printf '%s' "${_resume_archive_cache[$archive]}"
        return 0
    fi
    local raw
    raw="$(LC_ALL=C 7z l -slt "$archive" 2>/dev/null \
        | LC_ALL=C awk '/^Path = / { sub(/^Path = /, ""); print }' \
        | tail -n +2)" || return 1
    [[ -n "$raw" ]] || return 1
    local members="" line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _resume_plan_member_is_safe "$line" || return 1
        strip_list_contains "$line" && continue
        members+="$line"$'\n'
    done <<< "$raw"
    [[ -n "$members" ]] || return 1
    _resume_archive_cache["$archive"]="$members"
    printf '%s' "$members"
    return 0
}

# ─── _resume_plan_job_is_satisfied ────────────────────────────────────────────
# Checks whether every (strip-filtered) archive member is already present under
# the given destination directory. The dest cache is populated lazily — the
# first job targeting a given dest pays the readdir cost, subsequent jobs
# against the same dest reuse the cached set.
#
# Fast early-exit: if $local_root does not exist on disk at all, skip the 7z l
# entirely and return 1 (keep job) immediately. This is the cheapest possible
# "definitely not satisfied" verdict and keeps the planner's cold-run overhead
# near zero for the common first-ever-run case.
#
# Parameters
#   $1  archive    — absolute path to the .7z archive
#   $2  local_root — absolute destination directory (already containment-checked)
#
# Returns
#   0 — every member present at $local_root; caller should drop this job
#   1 — at least one member missing, or the planner cannot decide; keep job
#
# Locals
#   archive    — $1 captured as a named local
#   local_root — $2 captured as a named local
#   members    — newline-delimited strip-filtered member list from the cache
#   present    — NUL-joined relative paths under local_root from the cache
#   member     — loop variable walking members
# ──────────────────────────────────────────────────────────────────────────────
_resume_plan_job_is_satisfied() {
    local archive="$1" local_root="$2"
    [[ -d "$local_root" ]] || return 1

    local members
    members="$(_resume_plan_archive_members "$archive")" || return 1

    _resume_plan_load_dest_cache "$local_root"
    local present="${_resume_dest_cache[$local_root]}"

    local member
    while IFS= read -r member; do
        [[ -z "$member" ]] && continue
        # NUL-delimited membership test: each path in $present is followed by
        # a literal NUL. We embed the candidate between NULs on both sides and
        # use a leading NUL on $present so the first entry also matches.
        case $'\0'"$present" in
            *$'\0'"$member"$'\0'*) : ;;
            *) return 1 ;;
        esac
    done <<< "$members"
    return 0
}

# ─── resume_plan ──────────────────────────────────────────────────────────────
# Public entry point. Scans the global JOBS array and rewrites it in place,
# dropping every job whose content is already fully present at the adapter
# destination. Runs synchronously between _pipeline_run_init and the JOBS
# enqueue loop in workers_start(). Must never run after a worker has forked.
#
# Short-circuits immediately when RESUME_PLANNER_IND != "1": logs once and
# returns, leaving JOBS untouched.
#
# Parameters  : none (reads and mutates the global JOBS array)
#
# Returns     : 0 always — failures to plan simply fall through to the normal
#                precheck path, never aborting the pipeline
#
# Modifies
#   JOBS (global array) — rebuilt in place with survivors appended in original
#                         iteration order so downstream FIFO assumptions hold
#
# Locals
#   _resume_dest_cache     — associative array keyed by absolute dest dir,
#                            values are NUL-joined relative path sets
#   _resume_archive_cache  — associative array keyed by absolute archive path,
#                            values are newline-delimited strip-filtered members
#   survivors              — new JOBS contents collected in iteration order
#   started_at             — epoch seconds at entry; drives the summary line
#   total                  — |JOBS| at entry; denominator of the summary ratio
#   dropped                — count of jobs removed by the planner
#   raw_job                — current iteration's raw job token
#   parsed                 — three-line output of parse_job_line
#   archive                — archive field parsed from raw_job
#   adapter                — adapter field parsed from raw_job
#   dest                   — destination field parsed from raw_job
#   local_root             — canonicalised absolute destination dir for the job
#   elapsed                — wall-clock seconds spent in the planner (summary)
# ──────────────────────────────────────────────────────────────────────────────
resume_plan() {
    log_enter
    if [[ "${RESUME_PLANNER_IND:-1}" != "1" ]]; then
        log_info "resume planner: disabled (RESUME_PLANNER_IND=${RESUME_PLANNER_IND:-1})"
        return 0
    fi

    local total=${#JOBS[@]}
    if (( total == 0 )); then
        return 0
    fi

    # Fresh per-call caches. declare -A in a function creates a local scope,
    # so these do not leak between calls or into forked workers.
    local -A _resume_dest_cache=()
    local -A _resume_archive_cache=()

    local started_at
    started_at="$(date +%s)"

    local survivors=() raw_job parsed archive adapter dest local_root
    local dropped=0

    for raw_job in "${JOBS[@]}"; do
        if ! parsed="$(parse_job_line "$raw_job")"; then
            survivors+=("$raw_job")
            continue
        fi
        { read -r archive; read -r adapter; read -r dest; } <<< "$parsed"

        if [[ "$adapter" != "lvol" ]]; then
            survivors+=("$raw_job")
            continue
        fi

        if ! local_root="$(_resume_plan_dest_for_job "$dest")"; then
            log_warn "resume planner: refusing to plan (destination escapes or realpath unavailable): $raw_job"
            survivors+=("$raw_job")
            continue
        fi

        if _resume_plan_job_is_satisfied "$archive" "$local_root"; then
            (( dropped++ )) || true
            continue
        fi

        survivors+=("$raw_job")
    done

    local elapsed=$(( $(date +%s) - started_at ))
    JOBS=("${survivors[@]}")

    log_info "resume planner: $dropped of $total already satisfied in ${elapsed}s ($((total - dropped)) to process)"
    return 0
}
