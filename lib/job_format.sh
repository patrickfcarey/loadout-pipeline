#!/usr/bin/env bash
# sourced by lib/jobs.sh, lib/extract.sh, lib/dispatch.sh — do not execute directly
# =============================================================================
# JOB FORMAT — canonical parser for the ~iso_path|adapter|destination~ format.
# =============================================================================
# This file is the single source of truth for job-line parsing. All pipeline
# stages that need to split a job token into its three fields must source this
# file and call parse_job_line, rather than re-implementing the strip-and-split
# inline.
#
# Format
#   ~iso_path|adapter_name|destination_spec~
#
# Fields
#   iso_path         — absolute path to the .7z archive on the local filesystem
#   adapter_name     — one of: ftp  hdl  sd  rclone  rsync
#   destination_spec — adapter-specific target path or identifier
#
# parse_job_line <raw_job_line>
#   Emits three newline-separated fields on stdout: iso_path, adapter_name,
#   destination_spec. Returns non-zero (and emits nothing) if the line is
#   malformed (missing delimiters, empty fields).
#
# Typical usage in a subprocess script:
#   source "$ROOT_DIR/lib/job_format.sh"
#   if ! parsed="$(parse_job_line "$raw_job_line")"; then
#       log_error "malformed job: $raw_job_line"
#       exit 1
#   fi
#   IFS=$'\n' read -r iso_path adapter_name destination_spec <<< "$parsed"
# =============================================================================

# ─── parse_job_line ───────────────────────────────────────────────────────────
# Parses one raw job token of the form ~iso_path|adapter_name|destination_spec~
# into its three constituent fields. This is the single authoritative parser
# used by every pipeline stage; no stage may re-implement this inline.
#
# Parameters
#   $1  raw_job_line — the full job string including leading and trailing '~'
#                      e.g. "~/path/to/game.7z|sd|games/game1~"
#
# Returns
#   0 — success; three newline-separated fields are printed to stdout:
#         line 1: iso_path
#         line 2: adapter_name
#         line 3: destination_spec
#   1 — failure; the line is malformed (missing '~' delimiters, wrong number
#       of '|' separators, or any field is empty). Nothing is printed.
#
# Modifies    : nothing — all output goes to stdout via printf
#
# Locals
#   raw_job_line    — $1 captured as a named local for clarity
#   stripped_body   — the job string with leading and trailing '~' removed,
#                     leaving only "iso_path|adapter_name|destination_spec"
#   iso_path        — first field after splitting on '|'
#   adapter_name    — second field after splitting on '|'
#   destination_spec — third field after splitting on '|'
# ──────────────────────────────────────────────────────────────────────────────
parse_job_line() {
    local raw_job_line="$1"
    local stripped_body

    # Must start and end with '~'.
    [[ "${raw_job_line:0:1}" == "~" && "${raw_job_line: -1}" == "~" ]] || return 1

    # Strip the leading and trailing delimiters.
    stripped_body="${raw_job_line#\~}"
    stripped_body="${stripped_body%\~}"

    local iso_path adapter_name destination_spec
    IFS='|' read -r iso_path adapter_name destination_spec <<< "$stripped_body"

    # All three fields must be non-empty.
    [[ -n "$iso_path" && -n "$adapter_name" && -n "$destination_spec" ]] || return 1

    printf '%s\n%s\n%s\n' "$iso_path" "$adapter_name" "$destination_spec"
}
