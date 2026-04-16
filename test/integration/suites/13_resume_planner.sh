#!/usr/bin/env bash
# test/integration/suites/13_resume_planner.sh
#
# Resume planner (lib/resume_planner.sh) behaviour against a real
# loop-mounted vfat local volume. Exercises the "cold restart after power
# outage" code path end-to-end: jobs whose content already sits on the
# vfat substrate must be dropped by the planner before any worker forks,
# and the files on disk must not be touched.
#
# Scenarios:
#   13A  planner drops a fully-satisfied sd job; mtime unchanged
#   13B  planner keeps a partially-satisfied multi-file job
#   13C  RESUME_PLANNER_IND=0 bypasses planner; precheck still skips

# ─── Int Test 13A: planner skips pre-populated vfat destination ────────────

header "Int Test 13A: resume planner drops fully-satisfied vfat job"

T13A_JOBS="$INT_STATE/t13a.jobs"
T13A_EXTRACT="$INT_EXTRACT/t13a"
T13A_LOG="$INT_STATE/t13a.log"
rm -rf "$T13A_EXTRACT" "$INT_SD_VFAT/t13a"
mkdir -p "$T13A_EXTRACT" "$INT_SD_VFAT/t13a/dest1" "$INT_SD_VFAT/t13a/dest2"

# Pre-populate dest1 with the canonical small.7z payload. The planner must
# drop this job upstream without any worker ever touching the file.
( cd "$INT_SD_VFAT/t13a/dest1" && 7z x -y "$INT_FIXTURES/small.7z" >/dev/null )

# Snapshot mtime so a silent rewrite would be detectable after the run.
# vfat mtime granularity is 2s — fine here because the planner does not
# write at all.
t13a_pre_epoch=$(stat -c '%Y' "$INT_SD_VFAT/t13a/dest1/small.iso")

# Jobs: one already satisfied (dropped by planner), one empty (processed).
{
    printf '~%s/small.7z|lvol|t13a/dest1~\n' "$INT_FIXTURES"
    printf '~%s/small.7z|lvol|t13a/dest2~\n' "$INT_FIXTURES"
} > "$T13A_JOBS"

set +e
EXTRACT_DIR="$T13A_EXTRACT" QUEUE_DIR="$INT_QUEUE/t13a" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T13A_JOBS" >"$T13A_LOG" 2>&1
t13a_rc=$?
set -e

assert_rc "$t13a_rc" 0 "Test 13A pipeline rc"

if grep -E 'resume planner: 1 of 2 already satisfied' "$T13A_LOG" >/dev/null; then
    pass "Test 13A planner reported 1 of 2 satisfied on vfat"
else
    fail "Test 13A expected 'resume planner: 1 of 2 already satisfied' in log"
    sed 's/^/      /' "$T13A_LOG"
fi

# Proof-of-no-touch: the pre-existing file's mtime must be identical.
assert_mtime_unchanged "$INT_SD_VFAT/t13a/dest1/small.iso" "$t13a_pre_epoch" \
    "Test 13A dest1 mtime"

# dest2 must still be fully populated end-to-end (sibling job survived).
assert_file_present "$INT_SD_VFAT/t13a/dest2/small.iso" "Test 13A dest2 dispatched"

# ─── Int Test 13B: partial vfat destination kept ───────────────────────────

header "Int Test 13B: resume planner keeps partially-satisfied vfat job"

T13B_JOBS="$INT_STATE/t13b.jobs"
T13B_EXTRACT="$INT_EXTRACT/t13b"
T13B_LOG="$INT_STATE/t13b.log"
rm -rf "$T13B_EXTRACT" "$INT_SD_VFAT/t13b"
mkdir -p "$T13B_EXTRACT" "$INT_SD_VFAT/t13b/dest"

# Pre-populate ONLY multi.bin; multi.cue is missing. The planner must
# classify the job as "not satisfied" and let the pipeline re-extract.
printf 'partial bin byte payload\n' > "$INT_SD_VFAT/t13b/dest/multi.bin"

printf '~%s/multi.7z|lvol|t13b/dest~\n' "$INT_FIXTURES" > "$T13B_JOBS"

set +e
EXTRACT_DIR="$T13B_EXTRACT" QUEUE_DIR="$INT_QUEUE/t13b" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T13B_JOBS" >"$T13B_LOG" 2>&1
t13b_rc=$?
set -e

assert_rc "$t13b_rc" 0 "Test 13B pipeline rc"

if grep -E 'resume planner: 0 of 1 already satisfied' "$T13B_LOG" >/dev/null; then
    pass "Test 13B planner kept the partially-satisfied job"
else
    fail "Test 13B expected 'resume planner: 0 of 1 already satisfied' in log"
    sed 's/^/      /' "$T13B_LOG"
fi

# After re-extract the vfat destination must hold the canonical tree.
T13B_EXP="$INT_STATE/t13b_expected"
rm -rf "$T13B_EXP"
mkdir -p "$T13B_EXP"
( cd "$T13B_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T13B_EXP" "$INT_SD_VFAT/t13b/dest" "Test 13B final vfat tree"

# ─── Int Test 13C: disable switch on vfat ──────────────────────────────────

header "Int Test 13C: RESUME_PLANNER_IND=0 on vfat"

T13C_JOBS="$INT_STATE/t13c.jobs"
T13C_EXTRACT="$INT_EXTRACT/t13c"
T13C_LOG="$INT_STATE/t13c.log"
rm -rf "$T13C_EXTRACT" "$INT_SD_VFAT/t13c"
mkdir -p "$T13C_EXTRACT" "$INT_SD_VFAT/t13c/dest"

( cd "$INT_SD_VFAT/t13c/dest" && 7z x -y "$INT_FIXTURES/small.7z" >/dev/null )
t13c_pre_epoch=$(stat -c '%Y' "$INT_SD_VFAT/t13c/dest/small.iso")

printf '~%s/small.7z|lvol|t13c/dest~\n' "$INT_FIXTURES" > "$T13C_JOBS"

set +e
RESUME_PLANNER_IND=0 \
EXTRACT_DIR="$T13C_EXTRACT" QUEUE_DIR="$INT_QUEUE/t13c" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T13C_JOBS" >"$T13C_LOG" 2>&1
t13c_rc=$?
set -e

assert_rc "$t13c_rc" 0 "Test 13C pipeline rc"

if grep -E 'resume planner: disabled' "$T13C_LOG" >/dev/null; then
    pass "Test 13C planner logged disabled state on vfat"
else
    fail "Test 13C expected 'resume planner: disabled' in log"
    sed 's/^/      /' "$T13C_LOG"
fi

# With the planner disabled, precheck must still short-circuit the job.
if grep -E '^\[skip\].*small\.7z.*already exists at destination' "$T13C_LOG" >/dev/null; then
    pass "Test 13C precheck still skipped the pre-populated vfat job"
else
    fail "Test 13C expected [skip] log line for small.7z from precheck"
    sed 's/^/      /' "$T13C_LOG"
fi

# Nothing rewrote the pre-existing file on vfat.
assert_mtime_unchanged "$INT_SD_VFAT/t13c/dest/small.iso" "$t13c_pre_epoch" \
    "Test 13C dest mtime"
