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
#   $1  adapter  — ftp | hdl | lvol
#   $2  archive  — absolute path to the source .7z archive
#   $3  dest     — adapter-specific destination path (from the job line)
#
# Adapter-specific "already present" logic
#   lvol — real filesystem check against LVOL_MOUNT_POINT/$dest/<each member>
#   ftp  — uses curl --list-only against FTP_HOST to see whether every archive
#          member already exists in the remote destination directory.
#   hdl  — uses `hdl_dump toc $HDL_INSTALL_TARGET` and grep's the operator-
#          supplied PS2 title.
#   rclone — uses `rclone lsf` against RCLONE_REMOTE/$dest and checks every
#          archive member.
#   rsync — STUB: always returns "not present". Real impl would ssh to
#          RSYNC_HOST and stat each member, or use `rsync --dry-run`.
#
# Remote-adapter checks are pessimistic: if the required tooling/config is
# absent they fall through to "not present" rather than risk a false skip.
# =============================================================================
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/strip_list.sh"
source "$ROOT_DIR/lib/job_format.sh"

adapter="$1"
archive="$2"
dest="$3"

log_trace "→ precheck.sh  adapter=$adapter  archive=$archive  dest=$dest"

# List the archive's contents. `7z l -slt` emits multiple `Path = ...` lines;
# the first is the archive itself, so we drop it with `tail -n +2`.
#
# LC_ALL=C pins awk's regex engine to byte-wise matching. Without it, a UTF-8
# locale combined with a 7z build that localises field names ("Fichier = ")
# would silently miss every Path line and yield an empty $contained. Pinning
# to C also makes the behaviour reproducible across operator environments.
#
# `set +e` is narrowed to JUST the command substitution so a
# legitimately-empty-archive (an edge case we handle via exit 2 below) is not
# turned into a script-wide abort under -e. Everything else in this script
# remains under -e so real bugs fail loudly.
set +e
contained=$(LC_ALL=C 7z l -slt "$archive" 2>/dev/null \
    | LC_ALL=C awk '/^Path = / { sub(/^Path = /, ""); print }' \
    | tail -n +2)
set -e

if [[ -z "$contained" ]]; then
    log_warn "precheck: archive $archive is empty or unreadable"
    exit 2
fi

# ─── _precheck_member_is_safe ─────────────────────────────────────────────────
# Returns 0 if the given archive-member filename is a safe relative path that
# stays inside the target directory when appended. Rejects:
#   * absolute paths (leading /)
#   * any segment that is literally ".."
#   * leading "./" or embedded "/./" (could be combined with ".." in a way that
#     a naive string match misses)
#   * empty paths
#
# Why this matters: a malicious archive can encode member names like
# "../../etc/passwd" or "/etc/passwd". Before we probe for "already exists"
# with [[ -e "$local_root/$f" ]], we must be certain $f cannot escape
# $local_root — otherwise we'd leak information about the real filesystem (does
# /etc/passwd exist? does some victim file exist?) and on a repeat run a
# carefully-crafted archive could influence extract's behaviour via a precheck
# false-positive that causes extraction to be skipped.
#
# Note: this is a defense-in-depth check for the precheck stage. Actual write-
# side containment is enforced by 7z's own member-path handling in lib/extract.sh.
# Here we only care that the "already present" probe cannot escape.
#
# Parameters
#   $1  member — archive-member filename as emitted by `7z l -slt` Path line
#
# Returns
#   0 — safe
#   1 — unsafe (caller must refuse to use $member as a relative path)
#
# Locals
#   member — $1 captured as a named local
# ──────────────────────────────────────────────────────────────────────────────
_precheck_member_is_safe() {
    local member="$1"
    [[ -n "$member" ]]                    || return 1
    [[ "$member" != /* ]]                 || return 1
    [[ "$member" != *$'\n'* ]]            || return 1
    # Reject any ".." component regardless of position in the path.
    # The anchored regex matches at start-of-string, after a slash, before
    # a slash, or at end-of-string — every legitimate boundary for a path
    # component.
    [[ ! "$member" =~ (^|/)\.\.(/|$) ]]   || return 1
    return 0
}

# ── 1. Already at destination? ────────────────────────────────────────────
already_present=0
case "$adapter" in
    lvol)
        # Local volume: dest is a subdirectory under LVOL_MOUNT_POINT. ALL contained
        # members must exist for the archive to count as already present —
        # missing any one member means we still need to extract + re-dispatch.
        local_root="${LVOL_MOUNT_POINT%/}/${dest#/}"

        # Containment guard: reject destinations that escape LVOL_MOUNT_POINT via
        # ".." segments. load_jobs already rejects ".." at parse time, but
        # precheck also validates in case it is ever called independently.
        if command -v realpath >/dev/null 2>&1; then
            local_root_canonical="$(realpath -m "$local_root")"
            mount_canonical="$(realpath -m "${LVOL_MOUNT_POINT%/}")"
            case "${local_root_canonical}/" in
                "${mount_canonical}/"*) : ;;
                *)
                    log_warn "precheck: destination escapes LVOL_MOUNT_POINT — refusing probe: $local_root_canonical"
                    exit 2
                    ;;
            esac
        fi

        all_there=1
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            # Refuse to probe for archive members whose filenames contain
            # ".." segments or absolute paths. A malicious archive could
            # otherwise trick precheck into testing [[ -e "$local_root/../../etc/passwd" ]]
            # which might falsely report "already present" if the file exists,
            # causing the legitimate content to never be extracted.
            if ! _precheck_member_is_safe "$f"; then
                log_warn "precheck: archive $archive contains unsafe member path — refusing to probe: $f"
                exit 2
            fi
            # Stripped files are never dispatched to the destination, so
            # their absence must not cause a false "not present" result.
            strip_list_contains "$f" && continue
            if [[ ! -e "$local_root/$f" ]]; then
                all_there=0
                break
            fi
        done <<< "$contained"
        already_present=$all_there
        ;;
    ftp)
        if [[ -z "${FTP_HOST:-}" ]] || ! command -v curl >/dev/null 2>&1; then
            already_present=0
        else
            port="${FTP_PORT:-21}"
            dest_clean="${dest#/}"
            set +e
            remote_listing=$(curl -s --list-only \
                -u "${FTP_USER:-}:${FTP_PASS:-}" \
                "ftp://${FTP_HOST}:${port}/${dest_clean}/" \
                2>/dev/null)
            set -e
            if [[ -z "$remote_listing" ]]; then
                already_present=0
            else
                all_there=1
                while IFS= read -r f; do
                    [[ -z "$f" ]] && continue
                    if ! _precheck_member_is_safe "$f"; then
                        log_warn "precheck: archive $archive contains unsafe member path — refusing to probe: $f"
                        exit 2
                    fi
                    strip_list_contains "$f" && continue
                    if ! echo "$remote_listing" | grep -qF "$(basename "$f")"; then
                        all_there=0
                        break
                    fi
                done <<< "$contained"
                already_present=$all_there
            fi
        fi
        ;;
    hdl)
        # The hdl destination_spec is two pipe-delimited fields:
        #   <cd|dvd>|<title>
        # parse_hdl_destination validates the shape and emits the fields
        # newline-separated on stdout. load_jobs already rejects malformed
        # hdl jobs at load time, but precheck may be invoked in isolation
        # (e.g. from an integration test), so we re-validate here.
        #
        # The hdl_dump install target (e.g. hdd0:) is an operator-wide env var
        # set by the wrapper, not a per-job field. hdl_dump itself resolves
        # that target via the operator's real ~/.hdl_dump.conf, so this
        # precheck does not touch HOME.
        hdl_parsed=$(parse_hdl_destination "$dest") || {
            log_warn "precheck: malformed hdl destination: $dest"
            exit 2
        }
        { read -r hdl_format; read -r hdl_title; } <<< "$hdl_parsed"

        hdl_bin="${HDL_DUMP_BIN:-hdl_dump}"
        hdl_target="${HDL_INSTALL_TARGET:-}"
        if [[ -z "$hdl_target" ]] || ! command -v "$hdl_bin" >/dev/null 2>&1; then
            # Missing binary or target — same silent fall-through as rclone/ftp
            # precheck when the adapter's tooling/config is absent.
            already_present=0
        else
            set +e
            hdl_toc=$("$hdl_bin" toc "$hdl_target" 2>/dev/null)
            set -e
            if echo "$hdl_toc" | grep -qF "$hdl_title"; then
                already_present=1
            else
                already_present=0
            fi
        fi
        ;;
    rclone)
        if [[ -z "${RCLONE_REMOTE:-}" ]] || ! command -v rclone >/dev/null 2>&1; then
            already_present=0
        else
            dest_base="${RCLONE_DEST_BASE:-}"
            dest_base="${dest_base%/}"
            dest_clean="${dest#/}"
            if [[ -n "$dest_base" ]]; then
                rclone_target="${RCLONE_REMOTE}:${dest_base}/${dest_clean}"
            else
                rclone_target="${RCLONE_REMOTE}:${dest_clean}"
            fi
            rclone_args=()
            if [[ -n "${RCLONE_CONFIG:-}" ]]; then
                rclone_args+=(--config "$RCLONE_CONFIG")
            fi
            set +e
            remote_files=$(rclone lsf "${rclone_args[@]}" "$rclone_target" 2>/dev/null)
            set -e
            if [[ -z "$remote_files" ]]; then
                already_present=0
            else
                all_there=1
                while IFS= read -r f; do
                    [[ -z "$f" ]] && continue
                    if ! _precheck_member_is_safe "$f"; then
                        log_warn "precheck: archive $archive contains unsafe member path — refusing to probe: $f"
                        exit 2
                    fi
                    strip_list_contains "$f" && continue
                    if ! echo "$remote_files" | grep -qF "$f"; then
                        all_there=0
                        break
                    fi
                done <<< "$contained"
                already_present=$all_there
            fi
        fi
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
