#!/usr/bin/env bash
# =============================================================================
# ADAPTER: FTP
# =============================================================================
# Uploads an extracted directory to an FTP server using lftp's mirror mode.
# lftp handles recursive directory creation, resume on broken connections,
# and parallel transfers natively.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory to upload
#   $2  dest  — remote destination path on the FTP server
#
# ENVIRONMENT VARIABLES (set in .env or passed at call time)
#   FTP_HOST  — FTP server hostname                  (required)
#   FTP_USER  — FTP username                         (required)
#   FTP_PASS  — FTP password                         (required)
#   FTP_PORT  — FTP port (default: 21)               (optional)
# =============================================================================

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"

src="$1"
dest="$2"

# ── Validate ────────────────────────────────────────────────────────────────

if [[ ! -d "$src" ]]; then
    log_error "ftp: source directory does not exist: $src"
    exit 1
fi

if [[ -z "${FTP_HOST:-}" ]]; then
    if [[ "${ALLOW_STUB_ADAPTERS:-0}" == 1 ]]; then
        echo "[ftp] STUB — FTP_HOST not set; running as no-op (ALLOW_STUB_ADAPTERS=1)"
        exit 0
    fi
    log_error "ftp: FTP_HOST is not set"
    exit 1
fi

if [[ -z "${FTP_USER:-}" ]]; then
    log_error "ftp: FTP_USER is not set"
    exit 1
fi

if [[ -z "${FTP_PASS:-}" ]]; then
    log_error "ftp: FTP_PASS is not set"
    exit 1
fi

if ! command -v lftp >/dev/null 2>&1; then
    log_error "ftp: lftp command not found on PATH"
    log_error "ftp: install lftp (apt: lftp, brew: lftp) to enable the adapter"
    exit 1
fi

# ── Build target path ───────────────────────────────────────────────────────

port="${FTP_PORT:-21}"
dest_clean="${dest#/}"
remote_path="/${dest_clean}"

log_trace "ftp: transfer $src → ftp://$FTP_HOST:$port$remote_path"
echo "[ftp] Transferring $src → ftp://$FTP_HOST:$port$remote_path"

# ── Upload via lftp mirror ──────────────────────────────────────────────────
# mirror -R (reverse mirror) uploads local → remote, creating directories
# as needed. --continue enables resume on partial uploads. --verbose shows
# per-file progress.
#
# Credentials are passed via lftp `set` commands rather than embedding them
# in the URL. This avoids URL-encoding issues with special characters (@, :,
# /, etc.) in usernames or passwords.

lftp -e "
    set ftp:passive-mode yes
    set net:max-retries 3
    set net:reconnect-interval-base 5
    open -u $FTP_USER,$FTP_PASS -p $port $FTP_HOST
    mirror -R --continue --verbose $src $remote_path
    quit
"

log_trace "ftp: done → ftp://$FTP_HOST:$port$remote_path"
