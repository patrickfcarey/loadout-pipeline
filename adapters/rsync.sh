#!/usr/bin/env bash
# =============================================================================
# ADAPTER: RSYNC
# STATUS:  STUB — NOT IMPLEMENTED
# =============================================================================
# Transfers an extracted directory to a local path or a remote host over SSH.
# When RSYNC_HOST is unset the transfer is treated as a local copy.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory to transfer
#   $2  dest  — destination path relative to RSYNC_DEST_BASE
#
# ENVIRONMENT VARIABLES (set in .env or passed at call time)
#   RSYNC_DEST_BASE    — base path on the target, e.g. "/mnt/nas/games"
#                                                           (required to implement)
#   RSYNC_HOST         — remote hostname or IP; omit for a local transfer
#                                                           (optional)
#   RSYNC_USER         — SSH username for remote transfers  (optional)
#   RSYNC_SSH_PORT     — SSH port (default: 22)             (optional)
#   RSYNC_FLAGS        — extra flags forwarded verbatim to rsync, e.g.
#                        "--checksum --compress"             (optional)
#
# RECOMMENDED INVOCATIONS
#
#   Local transfer:
#     rsync -a --delete "$src/" "${RSYNC_DEST_BASE%/}/$dest/" $RSYNC_FLAGS
#
#   Remote transfer over SSH:
#     rsync -a --delete \
#       -e "ssh -p ${RSYNC_SSH_PORT:-22}" \
#       "$src/" \
#       "${RSYNC_USER:-}${RSYNC_USER:+@}${RSYNC_HOST}:${RSYNC_DEST_BASE%/}/$dest/" \
#       $RSYNC_FLAGS
#
# NOTES
#   - Trailing slash on $src/ is intentional: rsync copies the *contents* of
#     src into dest rather than nesting src as a subdirectory inside dest.
#   - --delete removes remote files that no longer exist locally; remove it
#     if you want additive-only transfers.
#   - For large files consider --partial --progress to resume interrupted transfers.
# =============================================================================

set -euo pipefail

src="$1"
dest="$2"

_target="${RSYNC_DEST_BASE:-<RSYNC_DEST_BASE>}/$dest"
if [[ -n "${RSYNC_HOST:-}" ]]; then
    _target="${RSYNC_USER:-}${RSYNC_USER:+@}${RSYNC_HOST}:$_target"
fi

# TODO: replace this echo with a real rsync invocation using the vars above
echo "[rsync] STUB — would transfer $src → $_target"
