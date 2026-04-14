#!/usr/bin/env bash
# =============================================================================
# ADAPTER: FTP
# STATUS:  STUB — NOT IMPLEMENTED
# =============================================================================
# This adapter is a placeholder. It does not transfer any files.
# Implement the transfer logic in the section marked TODO below.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory to upload
#   $2  dest  — remote destination path on the FTP server
#
# ENVIRONMENT VARIABLES (set in .env or passed at call time)
#   FTP_HOST  — FTP server hostname                  (required to implement)
#   FTP_USER  — FTP username                         (required to implement)
#   FTP_PASS  — FTP password                         (required to implement)
#   FTP_PORT  — FTP port (default: 21)               (optional)
#
# RECOMMENDED TOOLS
#   lftp    — most capable; supports mirroring, retries, SFTP, FTPS
#   curl    — simple single-file upload via --upload-file
#   ncftp   — lightweight, scriptable FTP client
#
# EXAMPLE IMPLEMENTATIONS
#
#   Mirror full directory with lftp (most common):
#     lftp -e "mirror -R \"$src\" \"$dest\"; quit" \
#       ftp://$FTP_USER:$FTP_PASS@$FTP_HOST:$FTP_PORT
#
#   Upload a single file with curl:
#     curl -T "$src/game.iso" \
#       ftp://$FTP_USER:$FTP_PASS@$FTP_HOST:$FTP_PORT/"$dest"/
#
#   With SFTP via lftp:
#     lftp -e "mirror -R \"$src\" \"$dest\"; quit" \
#       sftp://$FTP_USER:$FTP_PASS@$FTP_HOST
#
# =============================================================================

set -euo pipefail

src="$1"
dest="$2"

# TODO: replace this echo with a real transfer command using the vars above
echo "[ftp] STUB — would send $src → ftp://$FTP_HOST:$FTP_PORT$dest"
