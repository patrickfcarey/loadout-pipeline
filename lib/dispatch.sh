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

# Variable groups belonging to each adapter. These arrays are the SINGLE
# source of truth: the case arms below build their `env -u` strip list by
# taking every group except the one that matches the active adapter.
# To add a new credential (e.g. FTP_TLS) simply append it to the relevant
# array — every other adapter automatically strips it.
readonly _FTP_ENV_VARS=(FTP_HOST FTP_USER FTP_PASS FTP_PORT)
readonly _HDL_ENV_VARS=(HDL_DUMP_BIN)
readonly _LVOL_ENV_VARS=(LVOL_MOUNT_POINT)
readonly _RCLONE_ENV_VARS=(RCLONE_REMOTE RCLONE_DEST_BASE RCLONE_FLAGS)
readonly _RSYNC_ENV_VARS=(RSYNC_DEST_BASE RSYNC_HOST RSYNC_USER RSYNC_SSH_PORT RSYNC_FLAGS)

# ─── _build_strip_args ────────────────────────────────────────────────────────
# Build an `env -u <VAR>` argument list for every adapter group EXCEPT the
# one whose array name is passed in $1. Result is stored in the global
# `_strip_args` array so the caller can prepend it to an `env ... bash ...`
# invocation. Using a global avoids the subshell round-trip that would be
# required by stdout-based return (which would drop all shell quoting).
#
# Parameters
#   $1  keep — array name whose members should NOT be stripped
#              (e.g. "_FTP_ENV_VARS" when dispatching to the ftp adapter)
#
# Returns     : 0 always
# Modifies    : global `_strip_args` array is reset and populated
#
# Locals
#   keep         — $1
#   group_names  — list of every known adapter-env array name
#   group_name   — loop var over group_names
#   group_ref    — `declare -n` namerefs to the group array being iterated
#   var          — loop var over the vars inside group_ref
# ──────────────────────────────────────────────────────────────────────────────
_build_strip_args() {
    local keep="$1"
    local group_name var
    local -a group_names=(_FTP_ENV_VARS _HDL_ENV_VARS _LVOL_ENV_VARS _RCLONE_ENV_VARS _RSYNC_ENV_VARS)
    _strip_args=()
    for group_name in "${group_names[@]}"; do
        [[ "$group_name" == "$keep" ]] && continue
        local -n group_ref="$group_name"
        for var in "${group_ref[@]}"; do
            _strip_args+=(-u "$var")
        done
        unset -n group_ref
    done
}

declare -a _strip_args=()

case "$adapter" in
    ftp)
        _build_strip_args _FTP_ENV_VARS
        env "${_strip_args[@]}" bash "$ROOT_DIR/adapters/ftp.sh" "$src" "$dest"
        ;;
    hdl)
        _build_strip_args _HDL_ENV_VARS
        env "${_strip_args[@]}" bash "$ROOT_DIR/adapters/hdl_dump.sh" "$src" "$dest"
        ;;
    lvol)
        _build_strip_args _LVOL_ENV_VARS
        env "${_strip_args[@]}" bash "$ROOT_DIR/adapters/lvol.sh" "$src" "$dest"
        ;;
    rclone)
        _build_strip_args _RCLONE_ENV_VARS
        env "${_strip_args[@]}" bash "$ROOT_DIR/adapters/rclone.sh" "$src" "$dest"
        ;;
    rsync)
        _build_strip_args _RSYNC_ENV_VARS
        env "${_strip_args[@]}" bash "$ROOT_DIR/adapters/rsync.sh" "$src" "$dest"
        ;;
    *)
        log_error "unknown adapter: $adapter"
        exit 1
        ;;
esac

log_trace "← dispatch.sh"
