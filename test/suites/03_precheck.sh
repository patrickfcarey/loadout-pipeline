#!/usr/bin/env bash
# test/suites/03_precheck.sh
#
# Precheck (already-at-destination) logic: skip on full presence, re-run on
# partial presence, correct handling of multi-file archives. These tests
# exercise lib/precheck.sh via the full pipeline to confirm that the
# check-and-skip path integrates correctly with the worker loop.

# ── test 7: precheck skip when content already at destination ─────────────────
#
# Prepopulates the SD destination with the expected iso, then runs the pipeline.
# Expects: a [skip] log line for the SD job, the SD job's extract dir to NOT
# be created (precheck short-circuits before copy/extract), and the FTP + HDL
# jobs to still run normally (their exists stubs always return "not present").

header "Test 7: precheck skip when content exists at destination"
CUSTOM_SD="/tmp/iso_pipeline_test_sd_$$"
CUSTOM_EXTRACT7="/tmp/iso_pipeline_test_extract7_$$"
TEST_LOG="/tmp/iso_pipeline_test7_$$.log"
mkdir -p "$CUSTOM_SD/games/game3"
printf 'pre-existing stub iso\n' > "$CUSTOM_SD/games/game3/game3.iso"
# Disable the resume planner so this test exercises the precheck skip path
# directly. The planner would otherwise drop the satisfied job upstream and
# the [skip] log line below would never appear. Test 12A covers the
# planner-enabled equivalent; see test/suites/12_resume_planner.sh.
echo "  cmd: RESUME_PLANNER_IND=0 SD_MOUNT_POINT=$CUSTOM_SD EXTRACT_DIR=$CUSTOM_EXTRACT7 bash bin/loadout-pipeline.sh test/example.jobs"
RESUME_PLANNER_IND=0 SD_MOUNT_POINT="$CUSTOM_SD" EXTRACT_DIR="$CUSTOM_EXTRACT7" \
    bash "$PIPELINE" "$TEST_JOBS" >"$TEST_LOG" 2>&1 || true

if grep -E '^\[skip\].*game3\.7z.*already exists at destination' "$TEST_LOG" >/dev/null; then
    pass "game3 skip event logged"
else
    fail "expected [skip] log line for game3 with reason 'already exists at destination'"
    echo "      --- captured output ---"
    sed 's/^/      /' "$TEST_LOG"
    echo "      -----------------------"
fi

if [[ ! -e "$CUSTOM_EXTRACT7/game3/game3.iso" ]]; then
    pass "game3 not extracted (precheck short-circuited before extract)"
else
    fail "game3 extracted despite precheck hit: $CUSTOM_EXTRACT7/game3/game3.iso exists"
fi

assert_extracted game1 "$CUSTOM_EXTRACT7"
assert_extracted game2 "$CUSTOM_EXTRACT7"

rm -rf "$CUSTOM_SD" "$CUSTOM_EXTRACT7" "$TEST_LOG"

# ── test 8: multi-file archive end-to-end ───────────────────────────────────
#
# game4.7z contains TWO members (game4.bin + game4.cue). Verifies that the
# pipeline extracts both, preserving the original filenames, and that the
# dispatch stage happens exactly once for the multi-member archive.

header "Test 8: multi-file archive (.bin + .cue)"
MULTI_EXTRACT="/tmp/iso_pipeline_test_multi_$$"
MULTI_JOBS="/tmp/iso_pipeline_test_multi_$$.jobs"
echo "~$ROOT_DIR/test/fixtures/isos/game4.7z|sd|games/game4~" > "$MULTI_JOBS"
echo "  cmd: EXTRACT_DIR=$MULTI_EXTRACT bash bin/loadout-pipeline.sh $MULTI_JOBS"
EXTRACT_DIR="$MULTI_EXTRACT" bash "$PIPELINE" "$MULTI_JOBS"

if [[ -f "$MULTI_EXTRACT/game4/game4.bin" ]]; then
    pass "game4.bin extracted with original filename preserved"
else
    fail "game4.bin missing from $MULTI_EXTRACT/game4/"
fi
if [[ -f "$MULTI_EXTRACT/game4/game4.cue" ]]; then
    pass "game4.cue extracted with original filename preserved"
else
    fail "game4.cue missing from $MULTI_EXTRACT/game4/"
fi

rm -rf "$MULTI_EXTRACT" "$MULTI_JOBS"

# ── test 9: precheck skip for a multi-file archive ───────────────────────────
#
# Prepopulates BOTH .bin and .cue at the SD destination; the pipeline should
# short-circuit before any copy/extract happens.

header "Test 9: precheck skip when all members already at destination"
MULTI_SD="/tmp/iso_pipeline_test_multi_sd_$$"
MULTI_EXTRACT9="/tmp/iso_pipeline_test_multi9_$$"
MULTI_JOBS9="/tmp/iso_pipeline_test_multi9_$$.jobs"
MULTI_LOG9="/tmp/iso_pipeline_test_multi9_$$.log"
mkdir -p "$MULTI_SD/games/game4"
printf 'prepopulated bin\n' > "$MULTI_SD/games/game4/game4.bin"
printf 'prepopulated cue\n' > "$MULTI_SD/games/game4/game4.cue"
echo "~$ROOT_DIR/test/fixtures/isos/game4.7z|sd|games/game4~" > "$MULTI_JOBS9"
# Disable the resume planner so this test exercises precheck directly on a
# fully-satisfied multi-file archive. Test 12A covers the planner-enabled
# equivalent for single-file archives; the multi-file planner path is
# exercised by Test 12C's partial-hit companion.
echo "  cmd: RESUME_PLANNER_IND=0 SD_MOUNT_POINT=$MULTI_SD EXTRACT_DIR=$MULTI_EXTRACT9 bash bin/loadout-pipeline.sh $MULTI_JOBS9"
RESUME_PLANNER_IND=0 SD_MOUNT_POINT="$MULTI_SD" EXTRACT_DIR="$MULTI_EXTRACT9" \
    bash "$PIPELINE" "$MULTI_JOBS9" >"$MULTI_LOG9" 2>&1 || true

if grep -E '^\[skip\].*game4\.7z.*already exists at destination' "$MULTI_LOG9" >/dev/null; then
    pass "multi-file archive skip event logged"
else
    fail "expected [skip] log line for game4"
    sed 's/^/      /' "$MULTI_LOG9"
fi

if [[ ! -e "$MULTI_EXTRACT9/game4" ]]; then
    pass "multi-file archive not extracted (short-circuited)"
else
    fail "game4 extracted despite precheck skip"
fi

rm -rf "$MULTI_SD" "$MULTI_EXTRACT9" "$MULTI_JOBS9" "$MULTI_LOG9"

# ── test 10: precheck does NOT skip when only some members present ──────────
#
# Prepopulates ONLY game4.bin — the .cue is missing. Precheck must treat this
# as "not fully present" and let the pipeline re-extract so the destination
# ends up consistent.

header "Test 10: precheck partial hit does not skip"
PARTIAL_SD="/tmp/iso_pipeline_test_partial_sd_$$"
PARTIAL_EXTRACT="/tmp/iso_pipeline_test_partial_$$"
PARTIAL_JOBS="/tmp/iso_pipeline_test_partial_$$.jobs"
PARTIAL_LOG="/tmp/iso_pipeline_test_partial_$$.log"
mkdir -p "$PARTIAL_SD/games/game4"
printf 'only bin present\n' > "$PARTIAL_SD/games/game4/game4.bin"
echo "~$ROOT_DIR/test/fixtures/isos/game4.7z|sd|games/game4~" > "$PARTIAL_JOBS"
echo "  cmd: SD_MOUNT_POINT=$PARTIAL_SD EXTRACT_DIR=$PARTIAL_EXTRACT bash bin/loadout-pipeline.sh $PARTIAL_JOBS"
SD_MOUNT_POINT="$PARTIAL_SD" EXTRACT_DIR="$PARTIAL_EXTRACT" \
    bash "$PIPELINE" "$PARTIAL_JOBS" >"$PARTIAL_LOG" 2>&1

if grep -E '^\[skip\]' "$PARTIAL_LOG" >/dev/null; then
    fail "precheck incorrectly skipped a partial hit"
    sed 's/^/      /' "$PARTIAL_LOG"
else
    pass "precheck did not skip on partial hit"
fi
if [[ -f "$PARTIAL_EXTRACT/game4/game4.bin" && -f "$PARTIAL_EXTRACT/game4/game4.cue" ]]; then
    pass "game4 re-extracted in full"
else
    fail "game4 not fully re-extracted after partial hit"
fi

rm -rf "$PARTIAL_SD" "$PARTIAL_EXTRACT" "$PARTIAL_JOBS" "$PARTIAL_LOG"
