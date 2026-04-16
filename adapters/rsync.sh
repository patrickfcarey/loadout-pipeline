#!/usr/bin/env bash
# =============================================================================
# ADAPTER: RSYNC
# =============================================================================
# Transfers an extracted directory to a local or remote destination via rsync.
# Optimized for large ISO transfers: resumable, checksum-verified, compressed.
# When RSYNC_HOST is unset the transfer is treated as a local copy.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory to transfer
#   $2  dest  — destination path relative to RSYNC_DEST_BASE
#
# ENVIRONMENT VARIABLES (set in .env or passed at call time)
#   RSYNC_DEST_BASE  — base path on the target            (required)
#   RSYNC_HOST       — remote hostname; omit for local    (optional)
#   RSYNC_USER       — SSH username for remote transfers   (optional)
#   RSYNC_SSH_PORT   — SSH port, default 22               (optional)
#   RSYNC_FLAGS      — extra flags forwarded to rsync     (optional)
# =============================================================================

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"

src="$1"
dest="$2"

# ── Validate ────────────────────────────────────────────────────────────────

if [[ ! -d "$src" ]]; then
    log_error "rsync: source directory does not exist: $src"
    exit 1
fi

if [[ -z "${RSYNC_DEST_BASE:-}" ]]; then
    log_error "rsync: RSYNC_DEST_BASE is not set"
    exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
    log_error "rsync: rsync command not found on PATH"
    exit 1
fi

# ── Build target path ───────────────────────────────────────────────────────

dest_base="${RSYNC_DEST_BASE%/}"
dest_clean="${dest#/}"
target_path="${dest_base}/${dest_clean}"

# Base rsync flags: resumable, checksum-verified, compressed.
# -c is critical: re-extraction via 7z x -aoa changes file mtimes, so rsync's
# default size+mtime skip would re-transfer everything on a re-run.
rsync_args=(-avzc --partial --append-verify --info=progress2)

if [[ -z "${RSYNC_HOST:-}" ]]; then
    # ── Local transfer ──────────────────────────────────────────────────────

    # Containment: prevent "../" escapes out of RSYNC_DEST_BASE
    if ! command -v realpath >/dev/null 2>&1; then
        log_error "rsync: realpath not found — containment check is mandatory"
        log_error "rsync: install GNU coreutils (apt: coreutils, brew: coreutils) to enable the adapter"
        exit 1
    fi
    target_canonical="$(realpath -m "$target_path")"
    base_canonical="$(realpath -m "$dest_base")"
    case "${target_canonical}/" in
        "${base_canonical}/"*) : ;;
        *)
            log_error "rsync: destination escapes RSYNC_DEST_BASE"
            log_error "rsync:   resolved target : $target_canonical"
            log_error "rsync:   allowed root    : $base_canonical"
            exit 1
            ;;
    esac

    mkdir -p "$target_path"

    log_trace "rsync: local transfer $src → $target_path"
    echo "[rsync] Transferring $src → $target_path"

    # shellcheck disable=SC2086
    rsync "${rsync_args[@]}" $RSYNC_FLAGS "$src/" "$target_path/"

else
    # ── Remote transfer over SSH ────────────────────────────────────────────

    rsync_args+=(-e "ssh -p ${RSYNC_SSH_PORT:-22}")

    remote_target="${RSYNC_USER:+${RSYNC_USER}@}${RSYNC_HOST}:${target_path}/"

    log_trace "rsync: remote transfer $src → $remote_target"
    echo "[rsync] Transferring $src → $remote_target"

    # --mkpath creates missing destination directories on the remote side
    # (rsync 3.2.3+, released 2020).
    # shellcheck disable=SC2086
    rsync "${rsync_args[@]}" --mkpath $RSYNC_FLAGS "$src/" "$remote_target"

fi

log_trace "rsync: done → $target_path"
