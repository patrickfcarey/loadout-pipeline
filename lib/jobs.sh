#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly

# job_format.sh provides the canonical parse_job_line function shared by every
# pipeline stage. Source it once here so callers of load_jobs also get the
# parser without a separate source call.
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/job_format.sh"

JOBS=()

# ─── load_jobs ────────────────────────────────────────────────────────────────
# Reads a jobs file line by line, validates every non-blank, non-comment line
# against the expected job format, checks for path-traversal sequences in the
# iso path and destination fields, and appends accepted lines to the global
# JOBS array. Any validation failure immediately returns non-zero so the
# pipeline aborts rather than processing a potentially malicious job.
#
# Parameters
#   $1  file — path to the jobs file to load
#              (e.g. "test/example.jobs" or an absolute path)
#
# Returns
#   0 — all lines parsed and validated; JOBS is populated (may be empty with a
#       warning if the file contained only blanks/comments)
#   1 — file not found, or any line failed format or path-traversal validation
#
# Modifies
#   JOBS (global array) — each valid job line is appended with JOBS+=("$line")
#
# Locals
#   file              — $1 captured as a named local
#   line              — current line being processed from the file
#   lineno            — 1-based line counter used in error messages
#   _job_regex        — ERE pattern stored in a variable (required by bash when
#                       the pattern contains spaces) that validates the full
#                       job-line format including the allowed character sets for
#                       iso_path and destination
#   parsed_job_fields — output of parse_job_line: three newline-separated fields
#                       used only to split the line for traversal checking
#   _check_iso        — iso_path field extracted from parsed_job_fields; tested
#                       for '..' path segments
#   _check_adapter    — adapter field extracted from parsed_job_fields (unused
#                       beyond parsing; adapter validity is enforced by the regex)
#   _check_dest       — destination field extracted from parsed_job_fields; tested
#                       for '..' path segments
# ──────────────────────────────────────────────────────────────────────────────
load_jobs() {
    log_enter
    local file="$1"

    # Detect whether this is the outermost load_jobs frame. Recursive
    # invocations (from the directory-profile branch below) have
    # FUNCNAME[1]=load_jobs; external callers do not. Only the outer call
    # runs the cross-file basename-uniqueness check at the end, so the
    # O(N) scan happens once per run rather than once per recursion.
    local _is_outer=0
    [[ "${FUNCNAME[1]:-}" != "load_jobs" ]] && _is_outer=1

    # Directory profile: load every *.jobs file inside, in sorted order.
    # JOBS is global, so the recursive calls append into the same array the
    # caller reads afterwards. Sort guarantees deterministic ordering across
    # filesystems whose readdir order is not stable.
    if [[ -d "$file" ]]; then
        local _dir_entry _dir_files=()
        while IFS= read -r -d '' _dir_entry; do
            _dir_files+=("$_dir_entry")
        done < <(find "$file" -maxdepth 1 -type f -name '*.jobs' -print0 | sort -z)

        if [[ ${#_dir_files[@]} -eq 0 ]]; then
            log_error "no .jobs files found in directory: $file"
            return 1
        fi

        local _jf
        for _jf in "${_dir_files[@]}"; do
            load_jobs "$_jf" || return 1
        done
        if (( _is_outer )); then
            _jobs_assert_unique_basenames || return 1
        fi
        return 0
    fi

    if [[ ! -f "$file" ]]; then
        log_error "job file or directory not found: $file"
        return 1
    fi

    local line lineno=0
    local _in_block_comment=0 _inside_body=0 _saw_header=0

    while IFS= read -r line; do
        (( lineno++ )) || true
        line="${line%$'\r'}"

        local _trimmed="${line#"${line%%[! ]*}"}"
        if (( _in_block_comment )); then
            [[ "$_trimmed" == '*/' || "$_trimmed" == '*/ '* ]] && _in_block_comment=0
            continue
        fi
        if [[ "$_trimmed" == '/*' || "$_trimmed" == '/* '* ]]; then
            _in_block_comment=1
            continue
        fi

        [[ -z "$line" || "$line" =~ ^# ]] && continue

        if [[ "$line" == '---JOBS---' ]]; then
            _saw_header=1
            _inside_body=1
            continue
        fi
        if [[ "$line" == '---END---' ]]; then
            _inside_body=0
            continue
        fi
        (( _inside_body )) || continue

        # Format: ~iso_path|adapter|destination~
        # Validation rules:
        #   iso_path    — absolute path to a .7z archive on the local filesystem.
        #                 Allowed: letters, digits, _ . / - and ALSO spaces,
        #                 parentheses, and apostrophes, because standard game ISO
        #                 naming conventions (e.g. "Tony Hawk's Pro Skater.7z" or
        #                 "Ultimate Board Game Collection (USA).7z") commonly
        #                 include them. Every pipeline code path double-quotes
        #                 $archive, so apostrophes and the other extras are safe.
        #   adapter     — one of: ftp  hdl  lvol  rclone  rsync
        #   destination — adapter-specific target path. More restrictive than
        #                 iso_path: spaces, parens, and apostrophes are NOT allowed
        #                 here because adapter destinations may be passed to external
        #                 tools (rsync, rclone, lftp) whose quoting behaviour varies
        #                 and because remote paths rarely need those characters.
        #                 Allowed: letters, digits, _ . / -
        #                 Exception: the hdl title sub-field (third pipe onward)
        #                 accepts a broader character class because real PS2
        #                 titles contain spaces, parens, apostrophes, ampersands
        #                 (e.g. "Ratchet & Clank"), and colons (e.g. "Final
        #                 Fantasy VII: Advent Children"). Every adapter wraps
        #                 the title in double quotes before handing it to an
        #                 external binary, so these extras are safe here.
        #
        # Always rejected in every field: shell injection characters (; $ ` "
        # \ tab, newline) and the path-traversal sequence (..). Additional
        # |field groups after the third pipe are allowed for future column
        # extensibility.
        #
        # Store the pattern in a variable. bash recommends this when the ERE
        # contains spaces so the pattern is not subject to word-splitting.
        # The '"'"' sequence embeds a literal apostrophe inside the single-
        # quoted pattern by closing, escaping, and re-opening the string.
        # Dash (-) is placed last inside each bracket expression so it is
        # interpreted literally, not as a range marker.
        local _job_regex='^~/[A-Za-z0-9_./ '"'"'()-]+\.7z\|(ftp|hdl|lvol|rclone|rsync)\|[A-Za-z0-9_./-]+(\|[A-Za-z0-9_./ '"'"'&:()-]*)*~$'
        if [[ ! "$line" =~ $_job_regex ]]; then
            log_error "invalid job at line $lineno: '$line'"
            log_error "expected format: ~/absolute/path/to/archive.7z|(ftp|hdl|lvol|rclone|rsync)|destination~"
            log_error "iso_path chars : letters, digits, _ . / - space ( ) '"
            log_error "destination chars: letters, digits, _ . / -"
            log_error "trailing-field (e.g. hdl title) also allows: space ( ) ' & :"
            return 1
        fi

        # Reject path-traversal attempts in either the iso path or the destination
        # field. A crafted destination like "../../../etc/cron.d" would otherwise
        # escape adapter sandbox roots (e.g. LVOL_MOUNT_POINT) when joined with them.
        # parse_job_line is available because job_format.sh is sourced at the top
        # of this file. Using it here consolidates parsing in one place.
        #
        # The regex matches any '..' path segment — anchored to start-of-string
        # or a '/' on the left and end-of-string or '/' on the right. This
        # catches the leading case ('..', '../foo'), trailing case ('foo/..'),
        # and the mid-string case ('foo/../bar'). The right anchor must be
        # '(/|$)' (slash OR end-of-string), NOT '(/$|$)' (slash+end OR end),
        # because the latter fails on mid-string segments.
        local parsed_job_fields
        if ! parsed_job_fields="$(parse_job_line "$line")"; then
            log_error "malformed job at line $lineno (parser rejected): '$line'"
            return 1
        fi
        local _check_iso _check_adapter _check_dest
        { read -r _check_iso; read -r _check_adapter; read -r _check_dest; } <<< "$parsed_job_fields"
        if [[ "$_check_iso"  =~ (^|/)\.\.(/|$) || \
              "$_check_dest" =~ (^|/)\.\.(/|$) ]]; then
            log_error "path traversal attempt (..) at line $lineno: '$line'"
            return 1
        fi

        # Archive basename (after .7z strip) must be a real filename, not a
        # directory reference. Without this guard, a path like "/..7z" passes
        # the traversal regex above (because ".." is followed by "7", not "/"
        # or end-of-string) and GNU basename then strips the ".7z" suffix to
        # a single ".", which would cause extract.sh to compute out_dir as
        # "$EXTRACT_DIR/." — i.e. $EXTRACT_DIR itself. Extraction into the
        # root of EXTRACT_DIR would mix sibling workers' output, and the
        # dispatch token would then leak the entire directory to the adapter
        # destination. Reject anything whose stripped basename is empty or
        # starts with a dot.
        local _check_stem
        _check_stem="$(basename "$_check_iso" .7z)"
        if [[ -z "$_check_stem" || "$_check_stem" == .* ]]; then
            log_error "invalid archive basename at line $lineno: '$_check_iso'"
            log_error "archive filename must not be empty or begin with a dot after stripping .7z"
            return 1
        fi

        # Adapter-specific validation for `hdl`. The hdl adapter extends the
        # destination_spec with one extra field: the PS2 title. Validating at
        # load time surfaces typos to the operator before a worker is spawned.
        # The host-side HDD device and hdl_dump install target are operator-
        # wide env vars (HDL_HOST_DEVICE, HDL_INSTALL_TARGET), not per-job.
        if [[ "$_check_adapter" == "hdl" ]]; then
            if ! parse_hdl_destination "$_check_dest" >/dev/null; then
                log_error "invalid hdl job at line $lineno: '$line'"
                log_error "hdl jobs require: ~<iso>|hdl|<cd|dvd>|<title>~"
                return 1
            fi
        fi

        JOBS+=("$line")
    done < "$file"

    if (( ! _saw_header )); then
        log_error "missing ---JOBS--- header in $file"
        log_error "jobs files must begin with a ---JOBS--- header and end with ---END---"
        return 1
    fi

    if [[ ${#JOBS[@]} -eq 0 ]]; then
        log_warn "no jobs found in $file"
    fi

    if (( _is_outer )); then
        _jobs_assert_unique_basenames || return 1
    fi
}

# ─── _jobs_assert_unique_basenames ───────────────────────────────────────────
# Asserts that no two DISTINCT archives share a basename. Two different files
# (e.g. ps2/Final_Fantasy.7z and psx/Final_Fantasy.7z) would both drive
# extract.sh to compute out_dir=$EXTRACT_DIR/Final_Fantasy and clobber each
# other when unzip_worker runs them concurrently.
#
# The legitimate fan-out pattern — same archive path dispatched to multiple
# destinations (install this ISO to N targets) — is explicitly allowed:
# identical paths produce identical extract content, so the shared
# out_dir is a cache hit, not a race. We key on the archive path first,
# only flagging collisions where the stem matches but the path does not.
#
# Parameters  : none (reads the global JOBS array)
#
# Returns
#   0 — every archive stem maps to at most one distinct path
#   1 — at least one stem collision across different paths; error logged
#
# Locals
#   seen     — associative array: stem → first archive path seen
#   job      — current job token from JOBS
#   parsed   — three-line output of parse_job_line for $job
#   archive  — archive field parsed from $job
#   stem     — basename "$archive" .7z — the extract-dir key we're guarding
# ─────────────────────────────────────────────────────────────────────────────
_jobs_assert_unique_basenames() {
    local -A seen=()
    local job parsed archive stem
    for job in "${JOBS[@]}"; do
        if ! parsed="$(parse_job_line "$job")"; then
            continue
        fi
        { read -r archive; read -r _; read -r _; } <<< "$parsed"
        stem="$(basename "$archive" .7z)"
        if [[ -n "${seen[$stem]+_}" && "${seen[$stem]}" != "$archive" ]]; then
            log_error "duplicate archive basename across jobs: '$stem.7z'"
            log_error "  first archive : ${seen[$stem]}"
            log_error "  next archive  : $archive"
            log_error "two archives with the same basename would collide at \$EXTRACT_DIR/$stem"
            log_error "rename one archive to make the basename unique"
            return 1
        fi
        seen["$stem"]="$archive"
    done
    return 0
}
