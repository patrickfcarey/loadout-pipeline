#!/usr/bin/env bash
# =============================================================================
# PRECHECK — "already present at destination" gate.
# =============================================================================
# Answers one question: is the archive's extracted content already at the
# adapter destination? If yes, the entire job (copy + extract + dispatch) is
# skipped — saving potentially enormous IO on large archives that were already
# delivered. A multi-file archive is "already present" only when EVERY
# contained member is present at the destination.
#
# Scratch-space accounting is NOT done here — it happens in lib/extract.sh
# under a shared ledger (lib/space.sh) so concurrent workers coordinate
# reservations and a release trap always runs on extract exit.
#
# Exit codes
#   0 — content already present at destination → skip this job
#   1 — content not present → proceed with copy/extract/dispatch
#   2 — fatal: malformed archive, unknown adapter, etc.
#
# Arguments
#   $1  adapter  — ftp | hdl | sd
#   $2  archive  — absolute path to the source .7z archive
#   $3  dest     — adapter-specific destination path (from the job line)
#
# Adapter-specific "already present" logic
#   sd   — real filesystem check against SD_MOUNT_POINT/$dest/<each member>
#   ftp  — STUB: always returns "not present". Real impl would use `lftp ls`
#          or `curl --list-only` to check the remote directory.
#   hdl  — STUB: always returns "not present". Real impl would use
#          `hdl_dump toc $dest` and grep for an archive-derived game title.
#
# Both stubs are pessimistic by design: they always proceed with work rather
# than risk a false skip.
# =============================================================================
# -e is intentionally omitted here. The `7z l -slt | awk | tail` pipeline in
# the "contained" assignment can produce an empty string for a valid (empty)
# archive, and we handle that explicitly with the `[[ -z "$contained" ]]` guard
# below. Adding -e would turn a legitimately-empty-archive into an abrupt exit
# rather than a controlled exit-2.
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"

adapter="$1"
archive="$2"
dest="$3"

log_trace "→ precheck.sh  adapter=$adapter  archive=$archive  dest=$dest"

# ─── _precheck_is_stripped ────────────────────────────────────────────────────
# Returns 0 (true) when the given filename appears in EXTRACT_STRIP_LIST.
# Used by the sd precheck to exclude strip-listed members from the "all members
# present?" check. Without this, a re-run after a successful strip would always
# conclude the job is not done (because Vimm's Lair.txt, for example, is listed
# in the archive but was deleted before dispatch and therefore never exists at
# the destination), causing redundant re-extraction every time.
#
# Parameters
#   $1  filename — bare filename to look up (e.g. "Vimm's Lair.txt");
#                  matched exactly against each entry in the strip list
#
# Returns
#   0 — filename is in the strip list (caller should skip the presence check)
#   1 — filename is NOT in the strip list, OR the strip list file does not exist
#
# Modifies    : nothing — reads the strip list file but never writes it
#
# Locals
#   filename        — $1 captured as a named local; compared against each strip entry
#   strip_list_path — resolved path to the strip list file; uses EXTRACT_STRIP_LIST
#                     if set, otherwise falls back to "$ROOT_DIR/strip.list"
#   strip_name      — each line read from the strip list file; blank lines and
#                     comment lines are skipped; trailing whitespace is trimmed
#                     before comparison
# ──────────────────────────────────────────────────────────────────────────────
_precheck_is_stripped() {
    local filename="$1"
    local strip_list_path="${EXTRACT_STRIP_LIST:-$ROOT_DIR/strip.list}"
    local strip_name
    [[ -f "$strip_list_path" ]] || return 1
    while IFS= read -r strip_name; do
        [[ -z "$strip_name" || "$strip_name" =~ ^[[:space:]]*# ]] && continue
        strip_name="${strip_name%"${strip_name##*[![:space:]]}"}"
        [[ -z "$strip_name" ]] && continue
        [[ "$filename" == "$strip_name" ]] && return 0
    done < "$strip_list_path"
    return 1
}

# List the archive's contents. `7z l -slt` emits multiple `Path = ...` lines;
# the first is the archive itself, so we drop it with `tail -n +2`.
contained=$(7z l -slt "$archive" 2>/dev/null \
    | awk '/^Path = / { sub(/^Path = /, ""); print }' \
    | tail -n +2)

if [[ -z "$contained" ]]; then
    log_warn "precheck: archive $archive is empty or unreadable"
    exit 2
fi

# ── 1. Already at destination? ────────────────────────────────────────────
already_present=0
case "$adapter" in
    sd)
        # SD card: dest is a subdirectory under SD_MOUNT_POINT. ALL contained
        # members must exist for the archive to count as already present —
        # missing any one member means we still need to extract + re-dispatch.
        local_root="${SD_MOUNT_POINT%/}/${dest#/}"

        # Containment guard: reject destinations that escape SD_MOUNT_POINT via
        # ".." segments. load_jobs already rejects ".." at parse time, but
        # precheck also validates in case it is ever called independently.
        if command -v realpath >/dev/null 2>&1; then
            local_root_canonical="$(realpath -m "$local_root")"
            mount_canonical="$(realpath -m "${SD_MOUNT_POINT%/}")"
            case "${local_root_canonical}/" in
                "${mount_canonical}/"*) : ;;
                *)
                    log_warn "precheck: destination escapes SD_MOUNT_POINT — refusing probe: $local_root_canonical"
                    exit 2
                    ;;
            esac
        fi

        all_there=1
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            # Stripped files are never dispatched to the destination, so
            # their absence must not cause a false "not present" result.
            _precheck_is_stripped "$f" && continue
            if [[ ! -e "$local_root/$f" ]]; then
                all_there=0
                break
            fi
        done <<< "$contained"
        already_present=$all_there
        ;;
    ftp)
        # TODO: real check with lftp / curl. Must verify every member of
        # $contained is present at the remote $dest.
        already_present=0
        ;;
    hdl)
        # TODO: real check using `hdl_dump toc $dest | grep <title>`.
        already_present=0
        ;;
    rclone)
        # TODO: real check using `rclone ls $RCLONE_REMOTE$RCLONE_DEST_BASE/$dest`.
        already_present=0
        ;;
    rsync)
        # TODO: real check — ssh to RSYNC_HOST and stat each member, or use
        # `rsync --dry-run` to detect what would be transferred.
        already_present=0
        ;;
    *)
        log_warn "precheck: unknown adapter: $adapter"
        exit 2
        ;;
esac

if [[ $already_present -eq 1 ]]; then
    log_trace "← precheck.sh  $adapter: already present at $dest"
    exit 0
fi

log_trace "← precheck.sh  proceed"
exit 1
