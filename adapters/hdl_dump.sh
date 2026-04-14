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

src="$1"
dest="$2"

# TODO: replace this echo with a real hdl_dump command using $HDL_DUMP_BIN
echo "[hdl_dump] STUB — would run: $HDL_DUMP_BIN inject_dvd $dest <title> $src/<game>.iso"
