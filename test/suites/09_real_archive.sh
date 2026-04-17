#!/usr/bin/env bash
# test/suites/09_real_archive.sh
#
# End-to-end test with a real game ISO archive. HARD-FAILS when the archive
# is absent — the suite will NOT go green on a machine that cannot actually
# exercise the real-archive path. To run the suite, place the archive at:
#   test/fixtures/isos/Ultimate Board Game Collection (USA).7z

# ── test 21: real game ISO — multi-file archive (bin+cue) ────────────────────
#
# Exercises the full pipeline end-to-end with an actual 196 MB PS2 game
# archive: "Ultimate Board Game Collection (USA).7z". This test verifies:
#   1. The expanded iso_path character set accepts spaces and parentheses.
#   2. A real multi-member archive (.bin, .cue, Vimm's Lair.txt) extracts
#      all members correctly under their original names.
#   3. The sd adapter copies all members to the ps2/ destination folder.
#
# Previously this test silently called pass() when the archive was absent,
# which kept the suite green on machines that had NEVER run the real path.
# That was a lie: "PASS" implied the behaviour was validated when in fact
# nothing was checked. The missing-archive branch now fails loudly so the
# operator cannot mistake an untested environment for a working one.

header "Test 21: real game ISO — Ultimate Board Game Collection (USA)"

REAL_ARCHIVE=$(find "$FIXTURES_DIR/isos" -name "Ultimate Board Game Collection*" 2>/dev/null | head -1)
# Generate the real-archive jobs file at runtime so the path tracks
# $REAL_ARCHIVE's actual location on disk (WSL /mnt/c/..., Oracle Linux
# /tank/..., CI /home/runner/..., etc). A committed file with a baked-in
# absolute path would break the moment the repo moved off one machine.
REAL_JOBS="/tmp/iso_pipeline_test_real_jobs_$$.jobs"
REAL_EXTRACT="/tmp/iso_pipeline_test_real_isos_$$"
REAL_SD_DIR="/tmp/iso_pipeline_test_real_isos_sd_$$"
REAL_LOG="/tmp/iso_pipeline_test_real_isos_$$.log"

if [[ -z "$REAL_ARCHIVE" ]]; then
    fail "Test 21: real archive missing — expected at $FIXTURES_DIR/isos/Ultimate Board Game Collection (USA).7z"
    echo "      Place the archive in test/fixtures/isos/ to run this test."
    echo "      (The real-archive path is intentionally required — a silent skip"
    echo "       would mask regressions in the space/parentheses iso_path handling,"
    echo "       real multi-member extraction, and the strip.list dispatch guard.)"
else
    echo "  archive: $REAL_ARCHIVE ($(du -sh "$REAL_ARCHIVE" 2>/dev/null | cut -f1))"
    mkdir -p "$REAL_EXTRACT" "$REAL_SD_DIR"
    { echo '---JOBS---'; echo "~$REAL_ARCHIVE|lvol|ps2~"; echo '---END---'; } > "$REAL_JOBS"

    set +e
    EXTRACT_DIR="$REAL_EXTRACT" \
    LVOL_MOUNT_POINT="$REAL_SD_DIR" \
    bash "$PIPELINE" "$REAL_JOBS" >"$REAL_LOG" 2>&1
    real_rc=$?
    set -e

    if [[ $real_rc -eq 0 ]]; then
        pass "pipeline completed successfully for real game archive"
    else
        fail "pipeline returned rc=$real_rc for real game archive"
        sed 's/^/      /' "$REAL_LOG"
    fi

    REAL_GAME_DIR="$REAL_EXTRACT/Ultimate Board Game Collection (USA)"
    if [[ -d "$REAL_GAME_DIR" ]]; then
        pass "extracted directory created: $(basename "$REAL_GAME_DIR")"
    else
        fail "extracted directory not created: $REAL_GAME_DIR"
    fi

    # Verify game content members were extracted (strip.list removes Vimm's Lair.txt).
    real_content_members=(
        "Ultimate Board Game Collection (USA).bin"
        "Ultimate Board Game Collection (USA).cue"
    )
    for member in "${real_content_members[@]}"; do
        if [[ -f "$REAL_GAME_DIR/$member" ]]; then
            pass "extracted member present: $member"
        else
            fail "extracted member missing: $member"
        fi
    done

    # Verify Vimm's Lair.txt was stripped from the extracted directory.
    if [[ ! -f "$REAL_GAME_DIR/Vimm's Lair.txt" ]]; then
        pass "Vimm's Lair.txt stripped from extracted directory (not dispatched)"
    else
        fail "Vimm's Lair.txt was NOT stripped — strip.list may not have been applied"
    fi

    # Verify the sd adapter copied game content into the ps2/ destination folder.
    REAL_SD_DEST="$REAL_SD_DIR/ps2"
    for member in "${real_content_members[@]}"; do
        if [[ -f "$REAL_SD_DEST/$member" ]]; then
            pass "sd adapter: member present at ps2/$member"
        else
            fail "sd adapter: member missing from ps2/$member"
        fi
    done

    # Verify Vimm's Lair.txt was never dispatched to the sd destination.
    if [[ ! -f "$REAL_SD_DEST/Vimm's Lair.txt" ]]; then
        pass "Vimm's Lair.txt absent from sd destination (correctly never dispatched)"
    else
        fail "Vimm's Lair.txt reached the sd destination — strip logic did not run before dispatch"
    fi

    rm -rf "$REAL_EXTRACT" "$REAL_SD_DIR" "$REAL_LOG" "$REAL_JOBS"
fi
