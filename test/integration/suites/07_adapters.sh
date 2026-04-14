#!/usr/bin/env bash
# test/integration/suites/07_adapters.sh
#
# Adapter coverage. Only the sd adapter is implemented today, so the
# three remaining adapters (ftp, hdl_dump, rclone, rsync) intentionally
# hard-fail via fail_stub_adapter. When any of those adapters gets a
# real implementation, flip its scenario to a full end-to-end test
# against the already-provisioned substrate ($INT_FTP_ROOT,
# $INT_RCLONE_REMOTE, $INT_SSH_PORT, $INT_HDL_APA).

# ─── Test 14: sd adapter end-to-end on loop-mounted vfat ────────────────────

header "Int Test 14: sd adapter — real vfat copy, byte-exact"

T14_DIR="$INT_STATE/t14"
T14_EXTRACT="$INT_EXTRACT/t14"
T14_JOBS="$T14_DIR/t14.jobs"
T14_LOG="$INT_STATE/t14.log"
rm -rf "$T14_DIR" "$T14_EXTRACT" "$INT_SD_VFAT/t14"
mkdir -p "$T14_DIR" "$T14_EXTRACT"

_int_make_jobs "$T14_JOBS" \
    "$INT_FIXTURES/multi.7z|sd|t14/multi"

set +e
EXTRACT_DIR="$T14_EXTRACT" QUEUE_DIR="$INT_QUEUE/t14" \
SD_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T14_JOBS" >"$T14_LOG" 2>&1
t14_rc=$?
set -e

assert_rc "$t14_rc" 0 "Test 14 pipeline rc"

T14_EXP="$INT_STATE/t14_expected"
rm -rf "$T14_EXP"
mkdir -p "$T14_EXP"
( cd "$T14_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T14_EXP" "$INT_SD_VFAT/t14/multi" "Test 14 sd adapter tree"

# ─── Test 15: hdl_dump adapter — intentional hard-fail ─────────────────────

header "Int Test 15: hdl_dump adapter (stub — intentional FAIL)"
fail_stub_adapter "hdl_dump"

# ─── Test 16: ftp adapter — intentional hard-fail ──────────────────────────

header "Int Test 16: ftp adapter (stub — intentional FAIL)"
fail_stub_adapter "ftp"

# ─── Test 17: rclone adapter — intentional hard-fail ───────────────────────

header "Int Test 17: rclone adapter (stub — intentional FAIL)"
fail_stub_adapter "rclone"

# ─── Test 18: rsync adapter — intentional hard-fail ────────────────────────

header "Int Test 18: rsync adapter (stub — intentional FAIL)"
fail_stub_adapter "rsync"
