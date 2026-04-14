#!/usr/bin/env bash
# test/integration/suites/02_core_pipeline.sh
#
# End-to-end happy-path runs on real substrates. Every scenario here
# drives bin/loadout-pipeline.sh against the real 256 MB tmpfs ($INT_EXTRACT)
# and the real loop-mounted vfat SD card ($INT_SD_VFAT), then verifies
# the output tree byte-for-byte against the decoded source tree.

# ─── helper: build a scenario-local jobs file ───────────────────────────────
_int_make_jobs() {
    local file="$1"; shift
    : > "$file"
    while (( $# > 0 )); do
        printf '~%s~\n' "$1" >> "$file"
        shift
    done
}

# ─── helper: extract archive members to an "expected" tree ─────────────────
_int_decode_expected() {
    local archive="$1" out="$2"
    mkdir -p "$out"
    ( cd "$out" && 7z x -y "$archive" >/dev/null )
}

# ─── Test 2: default run with three small archives ─────────────────────────

header "Int Test 2: default run (small + medium + multi → vfat SD)"

T2_JOBS="$INT_STATE/t2.jobs"
T2_EXTRACT="$INT_EXTRACT/t2"
rm -rf "$T2_EXTRACT"
mkdir -p "$T2_EXTRACT"

_int_make_jobs "$T2_JOBS" \
    "$INT_FIXTURES/small.7z|sd|t2/small" \
    "$INT_FIXTURES/medium.7z|sd|t2/medium" \
    "$INT_FIXTURES/multi.7z|sd|t2/multi"

T2_LOG="$INT_STATE/t2.log"
set +e
EXTRACT_DIR="$T2_EXTRACT" QUEUE_DIR="$INT_QUEUE/t2" \
SD_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T2_JOBS" >"$T2_LOG" 2>&1
t2_rc=$?
set -e

assert_rc "$t2_rc" 0 "Test 2 pipeline rc"

# Decode expected trees from the archives directly.
T2_EXP="$INT_STATE/t2_expected"
rm -rf "$T2_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$T2_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$T2_EXP/medium"
_int_decode_expected "$INT_FIXTURES/multi.7z"  "$T2_EXP/multi"

assert_tree_eq "$T2_EXP/small"  "$INT_SD_VFAT/t2/small"  "Test 2 small on vfat"
assert_tree_eq "$T2_EXP/medium" "$INT_SD_VFAT/t2/medium" "Test 2 medium on vfat"
assert_tree_eq "$T2_EXP/multi"  "$INT_SD_VFAT/t2/multi"  "Test 2 multi on vfat"

# ─── Test 3: serial extraction (MAX_UNZIP=1) ────────────────────────────────

header "Int Test 3: serial extraction on real substrate (MAX_UNZIP=1)"

T3_JOBS="$INT_STATE/t3.jobs"
T3_EXTRACT="$INT_EXTRACT/t3"
rm -rf "$T3_EXTRACT" "$INT_SD_VFAT/t3"
mkdir -p "$T3_EXTRACT"

_int_make_jobs "$T3_JOBS" \
    "$INT_FIXTURES/small.7z|sd|t3/a" \
    "$INT_FIXTURES/small.7z|sd|t3/b" \
    "$INT_FIXTURES/small.7z|sd|t3/c"

set +e
MAX_UNZIP=1 \
EXTRACT_DIR="$T3_EXTRACT" QUEUE_DIR="$INT_QUEUE/t3" \
SD_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T3_JOBS" >"$INT_STATE/t3.log" 2>&1
t3_rc=$?
set -e

assert_rc "$t3_rc" 0 "Test 3 pipeline rc"

for sub in a b c; do
    assert_file_present "$INT_SD_VFAT/t3/$sub/small.iso" "Test 3 SD entry $sub"
done

# ─── Test 4: more workers than jobs (MAX_UNZIP=5, 2 jobs) ──────────────────

header "Int Test 4: more workers than jobs on real substrate"

T4_JOBS="$INT_STATE/t4.jobs"
T4_EXTRACT="$INT_EXTRACT/t4"
rm -rf "$T4_EXTRACT" "$INT_SD_VFAT/t4"
mkdir -p "$T4_EXTRACT"

_int_make_jobs "$T4_JOBS" \
    "$INT_FIXTURES/small.7z|sd|t4/a" \
    "$INT_FIXTURES/medium.7z|sd|t4/b"

set +e
MAX_UNZIP=5 \
EXTRACT_DIR="$T4_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4" \
SD_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T4_JOBS" >"$INT_STATE/t4.log" 2>&1
t4_rc=$?
set -e

assert_rc "$t4_rc" 0 "Test 4 pipeline rc"
assert_file_present "$INT_SD_VFAT/t4/a/small.iso"  "Test 4 SD a"
assert_file_present "$INT_SD_VFAT/t4/b/medium.iso" "Test 4 SD b"

# Queue must be fully drained after a successful run.
if [[ -d "$INT_QUEUE/t4" ]]; then
    leftover=$(find "$INT_QUEUE/t4" -maxdepth 3 \( -name "*.job" -o -name "*.claimed.*" \) 2>/dev/null | wc -l)
    if (( leftover == 0 )); then
        pass "Test 4 queue drained"
    else
        fail "Test 4 queue has $leftover leftover entries"
    fi
fi
