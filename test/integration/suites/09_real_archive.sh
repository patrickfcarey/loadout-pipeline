#!/usr/bin/env bash
# test/integration/suites/09_real_archive.sh
#
# Real game ISO end-to-end, as in the unit test 21, but driving the
# integration substrate: real tmpfs extract + real vfat SD + real strip
# list dispatch guard. The existing 196 MB archive is expected to be
# baked into the container image at $INT_FIXTURES/Ultimate Board Game
# Collection (USA).7z (the Dockerfile copies the whole repo in, so the
# unit-suite fixture comes along for the ride).

header "Int Test 21: real game ISO on integration substrate"

REAL_ARCHIVE=""
# Prefer the integration fixture dir, fall back to the unit-suite fixture.
for candidate in \
    "$INT_FIXTURES/Ultimate Board Game Collection (USA).7z" \
    "$ROOT_DIR/test/fixtures/isos/Ultimate Board Game Collection (USA).7z"
do
    if [[ -s "$candidate" ]]; then
        REAL_ARCHIVE="$candidate"
        break
    fi
done

if [[ -z "$REAL_ARCHIVE" ]]; then
    fail "Test 21: real archive missing from the image"
    echo "      Place 'Ultimate Board Game Collection (USA).7z' under"
    echo "      test/fixtures/isos/ (or test/integration/fixtures/isos/)"
    echo "      before building the container."
else
    echo "  archive: $REAL_ARCHIVE ($(du -sh "$REAL_ARCHIVE" 2>/dev/null | cut -f1))"

    T21_DIR="$INT_STATE/t21"
    T21_EXTRACT="$INT_EXTRACT/t21"
    T21_JOBS="$T21_DIR/t21.jobs"
    T21_LOG="$INT_STATE/t21.log"
    rm -rf "$T21_DIR" "$T21_EXTRACT" "$INT_SD_VFAT/t21"
    mkdir -p "$T21_DIR" "$T21_EXTRACT"

    # The loop-mounted vfat is only 64 MB, far too small for a PS2 game.
    # Redirect the SD destination to a plain dir on the container rootfs so
    # the full adapter code path is exercised without hitting the vfat size
    # limit. INT_EXTRACT (1.5 GB tmpfs) handles the decompressed game fine.
    T21_SD="$T21_DIR/sd"
    mkdir -p "$T21_SD"

    printf '~%s|sd|t21/game~\n' "$REAL_ARCHIVE" > "$T21_JOBS"

    set +e
    EXTRACT_DIR="$T21_EXTRACT" QUEUE_DIR="$INT_QUEUE/t21" \
    SD_MOUNT_POINT="$T21_SD" \
    bash "$PIPELINE" "$T21_JOBS" >"$T21_LOG" 2>&1
    t21_rc=$?
    set -e

    assert_rc "$t21_rc" 0 "Test 21 pipeline rc"

    REAL_GAME_DIR="$T21_EXTRACT/Ultimate Board Game Collection (USA)"
    if [[ -d "$REAL_GAME_DIR" ]]; then
        pass "Test 21: extracted directory created with spaces + parens preserved"
    else
        fail "Test 21: extracted directory missing: $REAL_GAME_DIR"
    fi

    for member in \
        "Ultimate Board Game Collection (USA).bin" \
        "Ultimate Board Game Collection (USA).cue"
    do
        assert_file_present "$REAL_GAME_DIR/$member"   "Test 21 extract member $member"
        assert_file_present "$T21_SD/t21/game/$member" "Test 21 sd member $member"
    done

    assert_file_absent "$REAL_GAME_DIR/Vimm's Lair.txt"     "Test 21 stripped from extract"
    assert_file_absent "$T21_SD/t21/game/Vimm's Lair.txt"   "Test 21 stripped from sd"

    rm -rf "$T21_DIR" "$T21_EXTRACT"
fi
