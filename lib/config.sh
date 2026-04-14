#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly

# Load .env if present. Each variable is only set if not already in the
# environment, so caller-supplied values (MAX_UNZIP=4 bash ...) always win.
if [[ -f "$ROOT_DIR/.env" ]]; then
    # Warn if .env is readable by group or others — it typically holds credentials.
    # stat -c %a gives the octal mode as a string (e.g. "644"); we test the
    # last two digits for any non-zero bit meaning group/other read access.
    _dotenv_mode="$(stat -c %a "$ROOT_DIR/.env" 2>/dev/null || echo 0)"
    if (( 8#${_dotenv_mode} & 8#044 )); then
        echo "[config] WARNING: .env is readable by group or others (mode $_dotenv_mode) — run: chmod 600 .env" >&2
    fi
    unset _dotenv_mode

    while IFS= read -r _dotenv_line; do
        # Skip blank lines and full-line comments.
        [[ "$_dotenv_line" =~ ^[[:space:]]*(#|$) ]] && continue
        # Split on the first '=' only so that passwords containing '=' are
        # preserved intact in the value.
        _dotenv_key="${_dotenv_line%%=*}"
        _dotenv_val="${_dotenv_line#*=}"
        # Remove spaces from key (env var names cannot contain spaces).
        _dotenv_key="${_dotenv_key// /}"
        # Skip if no '=' was found or key contains non-identifier characters.
        [[ "$_dotenv_key" == "$_dotenv_line" || -z "$_dotenv_key" ]] && continue
        [[ "$_dotenv_key" =~ [^a-zA-Z0-9_] ]] && continue
        # Trim trailing whitespace from value (editor line-ending artifacts).
        # The '#' character is NOT treated as a comment delimiter here — it is
        # valid in passwords and paths and is preserved literally.
        _dotenv_val="${_dotenv_val%"${_dotenv_val##*[![:space:]]}"}"
        [[ -v "$_dotenv_key" ]] || export "$_dotenv_key=$_dotenv_val"
    done < "$ROOT_DIR/.env"
    unset _dotenv_line _dotenv_key _dotenv_val
fi

# Fallback defaults if neither .env nor the caller provided a value.
# Pipeline core
export DEBUG_IND="${DEBUG_IND:-0}"
export MAX_UNZIP="${MAX_UNZIP:-2}"
export MAX_DISPATCH="${MAX_DISPATCH:-2}"
# QUEUE_DIR is the parent dir that holds both sub-queues.
export QUEUE_DIR="${QUEUE_DIR:-/tmp/iso_pipeline_queue}"
export EXTRACT_QUEUE_DIR="${EXTRACT_QUEUE_DIR:-$QUEUE_DIR/extract}"
export DISPATCH_QUEUE_DIR="${DISPATCH_QUEUE_DIR:-$QUEUE_DIR/dispatch}"
export EXTRACT_DIR="${EXTRACT_DIR:-/tmp/iso_pipeline}"
# Scratch copies live in a sibling dir, NOT inside EXTRACT_DIR: otherwise any
# consumer that iterates $EXTRACT_DIR/* trips over the hidden .copies subdir.
export COPY_DIR="${COPY_DIR:-/tmp/iso_pipeline_copies}"
# Safety budget applied on top of raw archive + extracted bytes when reserving
# scratch space. Percent, integer. 20 means "reserve archive+extracted × 1.20".
export SPACE_OVERHEAD_PCT="${SPACE_OVERHEAD_PCT:-20}"
# FTP adapter
export FTP_HOST="${FTP_HOST:-}"
export FTP_USER="${FTP_USER:-}"
export FTP_PASS="${FTP_PASS:-}"
export FTP_PORT="${FTP_PORT:-21}"
# HDL dump adapter
export HDL_DUMP_BIN="${HDL_DUMP_BIN:-hdl_dump}"
# SD card adapter
export SD_MOUNT_POINT="${SD_MOUNT_POINT:-/mnt/sdcard}"
# rclone adapter
export RCLONE_REMOTE="${RCLONE_REMOTE:-}"
export RCLONE_DEST_BASE="${RCLONE_DEST_BASE:-}"
export RCLONE_FLAGS="${RCLONE_FLAGS:-}"
# rsync adapter
export RSYNC_DEST_BASE="${RSYNC_DEST_BASE:-}"
export RSYNC_HOST="${RSYNC_HOST:-}"
export RSYNC_USER="${RSYNC_USER:-}"
export RSYNC_SSH_PORT="${RSYNC_SSH_PORT:-22}"
export RSYNC_FLAGS="${RSYNC_FLAGS:-}"
# Worker recovery
export MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"

# Dispatch worker poll backoff — how long to sleep when the dispatch queue is
# momentarily empty but extraction has not finished yet.
# DISPATCH_POLL_INITIAL_MS: starting sleep in milliseconds.
# DISPATCH_POLL_MAX_MS:     ceiling for the exponential backoff.
export DISPATCH_POLL_INITIAL_MS="${DISPATCH_POLL_INITIAL_MS:-50}"
export DISPATCH_POLL_MAX_MS="${DISPATCH_POLL_MAX_MS:-500}"

# Post-extraction strip list: plain text file listing exact filenames (one
# per line) to delete from every extracted directory before dispatch.
# Default is strip.list in the pipeline root directory. Set to an empty
# string or a non-existent path to disable stripping entirely.
export EXTRACT_STRIP_LIST="${EXTRACT_STRIP_LIST:-$ROOT_DIR/strip.list}"

# Space-reservation retry backoff for extract workers.
#
# When a worker cannot reserve scratch space right now (because sibling workers
# are holding it), it re-queues the job and sleeps before trying again.
# The sleep doubles on each consecutive miss for the same job, capped at
# SPACE_RETRY_BACKOFF_MAX_SEC, so a single large archive does not cause a
# rapid busy-poll storm from every other waiting worker.
#
# SPACE_RETRY_BACKOFF_INITIAL_SEC — first sleep after a space miss (seconds,
#                                   decimals supported; 5 = 5 seconds)
# SPACE_RETRY_BACKOFF_MAX_SEC     — ceiling for the exponential backoff
export SPACE_RETRY_BACKOFF_INITIAL_SEC="${SPACE_RETRY_BACKOFF_INITIAL_SEC:-5}"
export SPACE_RETRY_BACKOFF_MAX_SEC="${SPACE_RETRY_BACKOFF_MAX_SEC:-60}"
