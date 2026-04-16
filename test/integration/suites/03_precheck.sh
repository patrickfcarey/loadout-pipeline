#!/usr/bin/env bash
# test/integration/suites/03_precheck.sh
#
# Precheck (already-at-destination) logic, exercised against a real
# vfat local volume mount. Every scenario here pre-populates bytes on the
# mounted filesystem before the pipeline runs and verifies the real
# skip/partial/full behaviour.

header "Int Test 5: precheck skip — full content already on vfat SD"

T5_JOBS="$INT_STATE/t5.jobs"
T5_EXTRACT="$INT_EXTRACT/t5"
T5_LOG="$INT_STATE/t5.log"
rm -rf "$T5_EXTRACT" "$INT_SD_VFAT/t5"
mkdir -p "$T5_EXTRACT" "$INT_SD_VFAT/t5/small"

# Decode small.7z directly to the destination so the precheck will find
# a byte-for-byte match.
( cd "$INT_SD_VFAT/t5/small" && 7z x -y "$INT_FIXTURES/small.7z" >/dev/null )

# Snapshot mtime of the pre-existing file. A regression that ran the
# pipeline's copy path despite a precheck hit would update mtime.
pre_epoch=$(stat -c '%Y' "$INT_SD_VFAT/t5/small/small.iso")

printf '~%s/small.7z|lvol|t5/small~\n' "$INT_FIXTURES" > "$T5_JOBS"

set +e
EXTRACT_DIR="$T5_EXTRACT" QUEUE_DIR="$INT_QUEUE/t5" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T5_JOBS" >"$T5_LOG" 2>&1
t5_rc=$?
set -e

assert_rc "$t5_rc" 0 "Test 5 pipeline rc"

# Precheck should have short-circuited: the extract dir never gets built.
assert_file_absent "$T5_EXTRACT/small/small.iso" "Test 5 extract skipped"

# mtime on vfat has 2s granularity; sleep just long enough that a real
# rewrite would be visible before the assert.
assert_mtime_unchanged "$INT_SD_VFAT/t5/small/small.iso" "$pre_epoch" "Test 5 mtime"

header "Int Test 6: precheck skip — multi-member archive fully present"

T6_JOBS="$INT_STATE/t6.jobs"
T6_EXTRACT="$INT_EXTRACT/t6"
T6_LOG="$INT_STATE/t6.log"
rm -rf "$T6_EXTRACT" "$INT_SD_VFAT/t6"
mkdir -p "$T6_EXTRACT" "$INT_SD_VFAT/t6/multi"
( cd "$INT_SD_VFAT/t6/multi" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )

printf '~%s/multi.7z|lvol|t6/multi~\n' "$INT_FIXTURES" > "$T6_JOBS"

set +e
EXTRACT_DIR="$T6_EXTRACT" QUEUE_DIR="$INT_QUEUE/t6" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T6_JOBS" >"$T6_LOG" 2>&1
t6_rc=$?
set -e

assert_rc "$t6_rc" 0 "Test 6 pipeline rc"
assert_file_absent "$T6_EXTRACT/multi/multi.bin" "Test 6 extract skipped"

header "Int Test 7: precheck partial hit — must re-extract"

T7_JOBS="$INT_STATE/t7.jobs"
T7_EXTRACT="$INT_EXTRACT/t7"
T7_LOG="$INT_STATE/t7.log"
rm -rf "$T7_EXTRACT" "$INT_SD_VFAT/t7"
mkdir -p "$T7_EXTRACT" "$INT_SD_VFAT/t7/multi"
# Only half the archive is present — the real precheck must not short-circuit.
printf 'partial bin\n' > "$INT_SD_VFAT/t7/multi/multi.bin"

printf '~%s/multi.7z|lvol|t7/multi~\n' "$INT_FIXTURES" > "$T7_JOBS"

set +e
EXTRACT_DIR="$T7_EXTRACT" QUEUE_DIR="$INT_QUEUE/t7" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T7_JOBS" >"$T7_LOG" 2>&1
t7_rc=$?
set -e

assert_rc "$t7_rc" 0 "Test 7 pipeline rc"
assert_file_present "$T7_EXTRACT/multi/multi.bin" "Test 7 re-extracted bin"
assert_file_present "$T7_EXTRACT/multi/multi.cue" "Test 7 re-extracted cue"

# After re-extract, the destination must hold the canonical tree.
T7_EXP="$INT_STATE/t7_expected"
rm -rf "$T7_EXP"
mkdir -p "$T7_EXP"
( cd "$T7_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T7_EXP" "$INT_SD_VFAT/t7/multi" "Test 7 final vfat tree"
