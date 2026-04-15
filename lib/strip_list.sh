#!/usr/bin/env bash
# =============================================================================
# STRIP LIST HELPER — shared strip-list membership test.
# =============================================================================
# Single source of truth for "is this bare filename listed in strip.list?".
# Sourced by lib/precheck.sh (to skip strip-listed members when checking
# "already present at destination") and lib/resume_planner.sh (same question,
# asked up front for the whole jobs file).
#
# Keeping this in one place ensures both stages agree on strip-list semantics
# bit-for-bit: if precheck skips a member, the planner must also skip it, or
# the planner would keep a job precheck would drop and the speedup would be
# lost.
#
# File format (matches strip.list in ROOT_DIR):
#   * one bare filename per line
#   * blank lines ignored
#   * lines whose first non-whitespace character is '#' ignored
#   * trailing whitespace trimmed before comparison
#   * entries containing '/' are NOT matched here (precheck and extract
#     emit their own warnings; this helper silently skips them to avoid
#     a flood of duplicate warnings during the jobs scan)
# =============================================================================

# ─── strip_list_contains ──────────────────────────────────────────────────────
# Returns 0 (true) when the given bare filename appears in the strip list file
# referenced by EXTRACT_STRIP_LIST (default: $ROOT_DIR/strip.list).
#
# Parameters
#   $1  filename — bare filename to look up; compared exactly against each
#                  non-blank, non-comment strip-list entry
#
# Returns
#   0 — filename is in the strip list
#   1 — filename is NOT in the strip list, OR the strip list file does not
#       exist (missing strip list = nothing to strip)
#
# Modifies    : nothing — reads the strip list file, never writes
#
# Locals
#   filename        — $1 captured as a named local
#   strip_list_path — resolved path to the strip list file
#   strip_name      — each line read from the strip list file
# ──────────────────────────────────────────────────────────────────────────────
strip_list_contains() {
    local filename="$1"
    local strip_list_path="${EXTRACT_STRIP_LIST:-$ROOT_DIR/strip.list}"
    local strip_name
    [[ -f "$strip_list_path" ]] || return 1
    while IFS= read -r strip_name; do
        [[ -z "$strip_name" || "$strip_name" =~ ^[[:space:]]*# ]] && continue
        strip_name="${strip_name%"${strip_name##*[![:space:]]}"}"
        [[ -z "$strip_name" ]] && continue
        [[ "$strip_name" == */* ]] && continue
        [[ "$filename" == "$strip_name" ]] && return 0
    done < "$strip_list_path"
    return 1
}
