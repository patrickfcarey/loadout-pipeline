#!/usr/bin/env bash
# =============================================================================
# ADAPTER: RCLONE
# STATUS:  STUB — NOT IMPLEMENTED
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
#                        "mys3:" or "gdrive:backups"       (required to implement)
#   RCLONE_DEST_BASE   — base path appended after the remote, e.g. "/games"
#                        Final dest: $RCLONE_REMOTE$RCLONE_DEST_BASE/$dest
#                                                           (optional, default: "")
#   RCLONE_FLAGS       — extra flags forwarded verbatim to rclone, e.g.
#                        "--transfers=8 --checkers=16"      (optional)
#
# RECOMMENDED INVOCATION
#
#   rclone copy "$src" "$RCLONE_REMOTE${RCLONE_DEST_BASE:-}/$dest" \
#       --progress $RCLONE_FLAGS
#
# NOTES
#   - rclone copy skips files that already exist with the same size+modtime,
#     making reruns safe without extra precheck logic.
#   - For large archives consider --transfers and --multi-thread-streams flags.
#   - Use --dry-run to validate paths before a live transfer.
# =============================================================================

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"

src="$1"
dest="$2"

# Stub guard — see adapters/ftp.sh for rationale. Set ALLOW_STUB_ADAPTERS=1
# to allow a no-op stub completion (dev/test without a real remote).
if [[ "${ALLOW_STUB_ADAPTERS:-0}" != 1 ]]; then
    log_error "rclone: adapter is a stub and has not been implemented."
    log_error "rclone: set ALLOW_STUB_ADAPTERS=1 to allow the stub to report success anyway."
    exit 1
fi

# TODO: replace this echo with a real rclone invocation using the vars above
echo "[rclone] STUB — would transfer $src → ${RCLONE_REMOTE:-<RCLONE_REMOTE>}${RCLONE_DEST_BASE:-}/$dest"
