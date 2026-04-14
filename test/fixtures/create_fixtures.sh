#!/usr/bin/env bash
# Creates small .7z archives for the test suite.
# Each sources/<game>/ directory contains one or more files; every file
# inside the directory becomes a member of the corresponding .7z archive.
# This lets the fixtures cover both single-file archives (game1/2/3) and
# multi-file archives (game4: .bin + .cue).
# Requires: 7z (p7zip)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/sources"
ISOS_DIR="$SCRIPT_DIR/isos"

mkdir -p "$ISOS_DIR"
mkdir -p "$SOURCES_DIR"

# Regenerate the dummy source content so re-running the fixtures script is
# idempotent even if someone deletes the source files between runs.
for game in game1 game2 game3; do
    mkdir -p "$SOURCES_DIR/$game"
    printf '%s dummy iso content\n' "$game" > "$SOURCES_DIR/$game/$game.iso"
done

# Multi-file fixture: a CD-style .bin / .cue pair inside a single archive.
# Exercises the pipeline's ability to preserve multiple filenames end-to-end.
mkdir -p "$SOURCES_DIR/game4"
printf 'game4 track 1 binary data\n' > "$SOURCES_DIR/game4/game4.bin"
printf 'FILE "game4.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n' \
    > "$SOURCES_DIR/game4/game4.cue"

for game_dir in "$SOURCES_DIR"/*/; do
    game=$(basename "$game_dir")
    out="$ISOS_DIR/${game}.7z"
    echo "[fixtures] Packing $game → $out"
    # Remove any stale archive so 7z always writes a fresh one (7z a appends
    # to existing archives; we want a clean regeneration every run).
    rm -f "$out"
    # Archive every file in the source dir, not a hard-coded member name —
    # this is what makes the multi-file fixture work without a special case.
    (cd "$game_dir" && 7z a "$out" ./* >/dev/null)
done

echo "[fixtures] Done. Archives written to $ISOS_DIR/"
