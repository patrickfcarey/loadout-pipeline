#!/usr/bin/env bash
# Creates small .iso archives (7z-compressed) from the sources/ directory.
# Run this once before running the pipeline against test/example.jobs.
# Requires: 7z (p7zip)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/sources"
ISOS_DIR="$SCRIPT_DIR/isos"

mkdir -p "$ISOS_DIR"

for game_dir in "$SOURCES_DIR"/*/; do
    game=$(basename "$game_dir")
    out="$ISOS_DIR/${game}.iso"
    echo "[fixtures] Packing $game → $out"
    # cd into the source dir so 7z stores relative paths, not absolute ones.
    # Without this, extraction recreates the full host directory tree inside /tmp.
    (cd "$game_dir" && 7z a "$out" . >/dev/null)
done

echo "[fixtures] Done. Archives written to $ISOS_DIR/"
