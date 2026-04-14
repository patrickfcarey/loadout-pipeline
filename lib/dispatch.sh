#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"

adapter="$1"
src="$2"
dest="$3"

log_trace "→ dispatch.sh  adapter=$adapter  src=$src  dest=$dest"

# Credential scoping: each adapter subprocess receives only the environment
# variables that belong to it. All other adapter-specific credentials are
# stripped via `env -u` before the child process is forked.
#
# `env -u VARNAME` removes the variable from the child's environment without
# modifying the current shell — parent variables remain intact throughout.
# This limits exposure if a future adapter accidentally leaks or logs its
# environment (e.g. via a debug flag or error handler).

# Variable groups belonging to each adapter — used in the case arms below.
readonly _FTP_ENV_VARS=(FTP_HOST FTP_USER FTP_PASS FTP_PORT)
readonly _HDL_ENV_VARS=(HDL_DUMP_BIN)
readonly _SD_ENV_VARS=(SD_MOUNT_POINT)
readonly _RCLONE_ENV_VARS=(RCLONE_REMOTE RCLONE_DEST_BASE RCLONE_FLAGS)
readonly _RSYNC_ENV_VARS=(RSYNC_DEST_BASE RSYNC_HOST RSYNC_USER RSYNC_SSH_PORT RSYNC_FLAGS)

case "$adapter" in
    ftp)
        # Give FTP vars; strip HDL, SD, rclone, rsync vars.
        env \
            -u HDL_DUMP_BIN \
            -u SD_MOUNT_POINT \
            -u RCLONE_REMOTE -u RCLONE_DEST_BASE -u RCLONE_FLAGS \
            -u RSYNC_DEST_BASE -u RSYNC_HOST -u RSYNC_USER -u RSYNC_SSH_PORT -u RSYNC_FLAGS \
            bash "$ROOT_DIR/adapters/ftp.sh" "$src" "$dest"
        ;;
    hdl)
        # Give HDL vars; strip FTP, SD, rclone, rsync vars.
        env \
            -u FTP_HOST -u FTP_USER -u FTP_PASS -u FTP_PORT \
            -u SD_MOUNT_POINT \
            -u RCLONE_REMOTE -u RCLONE_DEST_BASE -u RCLONE_FLAGS \
            -u RSYNC_DEST_BASE -u RSYNC_HOST -u RSYNC_USER -u RSYNC_SSH_PORT -u RSYNC_FLAGS \
            bash "$ROOT_DIR/adapters/hdl_dump.sh" "$src" "$dest"
        ;;
    sd)
        # Give SD vars; strip FTP, HDL, rclone, rsync vars.
        env \
            -u FTP_HOST -u FTP_USER -u FTP_PASS -u FTP_PORT \
            -u HDL_DUMP_BIN \
            -u RCLONE_REMOTE -u RCLONE_DEST_BASE -u RCLONE_FLAGS \
            -u RSYNC_DEST_BASE -u RSYNC_HOST -u RSYNC_USER -u RSYNC_SSH_PORT -u RSYNC_FLAGS \
            bash "$ROOT_DIR/adapters/sdcard.sh" "$src" "$dest"
        ;;
    rclone)
        # Give rclone vars; strip FTP, HDL, SD, rsync vars.
        env \
            -u FTP_HOST -u FTP_USER -u FTP_PASS -u FTP_PORT \
            -u HDL_DUMP_BIN \
            -u SD_MOUNT_POINT \
            -u RSYNC_DEST_BASE -u RSYNC_HOST -u RSYNC_USER -u RSYNC_SSH_PORT -u RSYNC_FLAGS \
            bash "$ROOT_DIR/adapters/rclone.sh" "$src" "$dest"
        ;;
    rsync)
        # Give rsync vars; strip FTP, HDL, SD, rclone vars.
        env \
            -u FTP_HOST -u FTP_USER -u FTP_PASS -u FTP_PORT \
            -u HDL_DUMP_BIN \
            -u SD_MOUNT_POINT \
            -u RCLONE_REMOTE -u RCLONE_DEST_BASE -u RCLONE_FLAGS \
            bash "$ROOT_DIR/adapters/rsync.sh" "$src" "$dest"
        ;;
    *)
        log_error "unknown adapter: $adapter"
        exit 1
        ;;
esac

log_trace "← dispatch.sh"
