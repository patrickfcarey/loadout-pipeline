#!/usr/bin/env bash
# =============================================================================
# ADAPTER: HDL DUMP
# STATUS:  STUB — NOT IMPLEMENTED
# =============================================================================
# This adapter is a placeholder. It does not write any data to a HDD.
# Implement the hdl_dump transfer logic in the section marked TODO below.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory containing the ISO content
#   $2  dest  — target device path (e.g. /dev/sdb) or hdl_dump destination string
#
# ENVIRONMENT VARIABLES (set in .env or passed at call time)
#   HDL_DUMP_BIN — path to the hdl_dump binary (default: hdl_dump, assumes PATH)
#
# ABOUT HDL DUMP
#   hdl_dump is a command-line tool for writing PS2 game ISOs directly to a
#   PlayStation 2 internal or external HDD in HDLoader format.
#   Project: https://github.com/ps2homebrew/hdl-dump
#
# RECOMMENDED APPROACH
#   $HDL_DUMP_BIN inject_dvd <device> "<game title>" <iso_file> [<compat_flags>]
#
# EXAMPLE IMPLEMENTATIONS
#
#   Inject a DVD-format ISO:
#     "$HDL_DUMP_BIN" inject_dvd "$dest" "Game Title" "$src/game.iso"
#
#   Inject a CD-format ISO:
#     "$HDL_DUMP_BIN" inject_cd "$dest" "Game Title" "$src/game.iso"
#
#   List existing games on device (useful for pre-flight check):
#     "$HDL_DUMP_BIN" toc "$dest"
#
# PREREQUISITES
#   - HDL_DUMP_BIN must be on PATH or set to an absolute path in .env
#   - Running user needs read/write access to the block device ($dest)
#   - The ISO inside $src must be a valid PS2 ISO image
#
# =============================================================================

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"

src="$1"
dest="$2"

# Stub guard — see adapters/ftp.sh for rationale. Set ALLOW_STUB_ADAPTERS=1
# to allow a no-op stub completion (dev/test without a real hdl_dump target).
if [[ "${ALLOW_STUB_ADAPTERS:-0}" != 1 ]]; then
    log_error "hdl_dump: adapter is a stub and has not been implemented."
    log_error "hdl_dump: set ALLOW_STUB_ADAPTERS=1 to allow the stub to report success anyway."
    exit 1
fi

# TODO: replace this echo with a real hdl_dump command using $HDL_DUMP_BIN
echo "[hdl_dump] STUB — would run: $HDL_DUMP_BIN inject_dvd $dest <title> $src/<game>.iso"
