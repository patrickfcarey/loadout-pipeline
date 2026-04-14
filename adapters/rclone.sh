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

src="$1"
dest="$2"

# TODO: replace this echo with a real rclone invocation using the vars above
echo "[rclone] STUB — would transfer $src → ${RCLONE_REMOTE:-<RCLONE_REMOTE>}${RCLONE_DEST_BASE:-}/$dest"
