#!/usr/bin/env bash
# =============================================================================
# ADAPTER: RCLONE
# =============================================================================
# Transfers an extracted directory to any rclone-supported remote (S3, GDrive,
# Dropbox, SFTP, and 100+ others). Configure the remote once with `rclone config`
# and reference it here by name.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory to transfer
#   $2  dest  — destination path relative to RCLONE_DEST_BASE on the remote
#
# ENVIRONMENT VARIABLES (set in .env or passed at call time)
#   RCLONE_REMOTE      — rclone remote name and optional bucket/root, e.g.
#                        "mys3:" or "gdrive:backups"       (required)
#   RCLONE_DEST_BASE   — base path appended after the remote, e.g. "/games"
#                        Final dest: $RCLONE_REMOTE:$RCLONE_DEST_BASE/$dest
#                                                           (optional, default "")
#   RCLONE_FLAGS       — extra flags forwarded verbatim to rclone, e.g.
#                        "--transfers=8 --checkers=16"      (optional)
#   RCLONE_CONFIG      — path to rclone.conf; forwarded as --config if set
#                                                           (optional)
# =============================================================================

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"

src="$1"
dest="$2"

# ── Validate ────────────────────────────────────────────────────────────────

if [[ ! -d "$src" ]]; then
    log_error "rclone: source directory does not exist: $src"
    exit 1
fi

if [[ -z "${RCLONE_REMOTE:-}" ]]; then
    if [[ "${ALLOW_STUB_ADAPTERS:-0}" == 1 ]]; then
        echo "[rclone] STUB — RCLONE_REMOTE not set; running as no-op (ALLOW_STUB_ADAPTERS=1)"
        exit 0
    fi
    log_error "rclone: RCLONE_REMOTE is not set"
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    log_error "rclone: rclone command not found on PATH"
    exit 1
fi

# ── Build target path ───────────────────────────────────────────────────────

dest_base="${RCLONE_DEST_BASE:-}"
dest_base="${dest_base%/}"
dest_clean="${dest#/}"
if [[ -n "$dest_base" ]]; then
    target_path="${RCLONE_REMOTE}:${dest_base}/${dest_clean}"
else
    target_path="${RCLONE_REMOTE}:${dest_clean}"
fi

# ── Build rclone arguments ──────────────────────────────────────────────────

rclone_args=(copy "$src" "$target_path" --progress)

if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    rclone_args+=(--config "$RCLONE_CONFIG")
fi

log_trace "rclone: transfer $src → $target_path"
echo "[rclone] Transferring $src → $target_path"

# shellcheck disable=SC2086
rclone "${rclone_args[@]}" $RCLONE_FLAGS

log_trace "rclone: done → $target_path"
