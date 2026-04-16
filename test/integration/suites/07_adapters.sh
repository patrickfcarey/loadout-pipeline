#!/usr/bin/env bash
# test/integration/suites/07_adapters.sh
#
# Adapter coverage. lvol and rsync are fully implemented. The remaining
# adapters (ftp, hdl_dump, rclone) intentionally hard-fail via
# fail_stub_adapter. When any of those adapters gets a real
# implementation, flip its scenario to a full end-to-end test against
# the already-provisioned substrate ($INT_FTP_ROOT,
# $INT_RCLONE_REMOTE, $INT_HDL_APA).

# ─── Test 14: sd adapter end-to-end on loop-mounted vfat ────────────────────

header "Int Test 14: sd adapter — real vfat copy, byte-exact"

T14_DIR="$INT_STATE/t14"
T14_EXTRACT="$INT_EXTRACT/t14"
T14_JOBS="$T14_DIR/t14.jobs"
T14_LOG="$INT_STATE/t14.log"
rm -rf "$T14_DIR" "$T14_EXTRACT" "$INT_SD_VFAT/t14"
mkdir -p "$T14_DIR" "$T14_EXTRACT"

_int_make_jobs "$T14_JOBS" \
    "$INT_FIXTURES/multi.7z|lvol|t14/multi"

set +e
EXTRACT_DIR="$T14_EXTRACT" QUEUE_DIR="$INT_QUEUE/t14" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
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

# ─── Test 18: rsync adapter — local transfer, byte-exact ──────────────────

header "Int Test 18: rsync adapter — local transfer"

T18_DIR="$INT_STATE/t18"
T18_EXTRACT="$INT_EXTRACT/t18"
T18_DEST="$INT_STATE/t18_dest"
T18_JOBS="$T18_DIR/t18.jobs"
T18_LOG="$INT_STATE/t18.log"
rm -rf "$T18_DIR" "$T18_EXTRACT" "$T18_DEST"
mkdir -p "$T18_DIR" "$T18_EXTRACT" "$T18_DEST"

_int_make_jobs "$T18_JOBS" \
    "$INT_FIXTURES/multi.7z|rsync|t18/multi"

set +e
EXTRACT_DIR="$T18_EXTRACT" QUEUE_DIR="$INT_QUEUE/t18" \
RSYNC_DEST_BASE="$T18_DEST" \
bash "$PIPELINE" "$T18_JOBS" >"$T18_LOG" 2>&1
t18_rc=$?
set -e

assert_rc "$t18_rc" 0 "Test 18 pipeline rc"

T18_EXP="$INT_STATE/t18_expected"
rm -rf "$T18_EXP"
mkdir -p "$T18_EXP"
( cd "$T18_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T18_EXP" "$T18_DEST/t18/multi" "Test 18 rsync local adapter tree"

# ─── Test 19: rsync adapter — remote (SSH loopback) transfer ─────────────

header "Int Test 19: rsync adapter — remote SSH transfer"

T19_DIR="$INT_STATE/t19"
T19_EXTRACT="$INT_EXTRACT/t19"
T19_DEST="$INT_STATE/t19_dest"
T19_JOBS="$T19_DIR/t19.jobs"
T19_LOG="$INT_STATE/t19.log"
rm -rf "$T19_DIR" "$T19_EXTRACT" "$T19_DEST"
mkdir -p "$T19_DIR" "$T19_EXTRACT" "$T19_DEST"

# Set up SSH config so the adapter's `ssh -p $PORT` picks up the test
# key and skips host-key verification automatically.
T19_SSH_CFG="/root/.ssh/config"
T19_HAD_SSH_CFG=0
[[ -f "$T19_SSH_CFG" ]] && T19_HAD_SSH_CFG=1
cat >> "$T19_SSH_CFG" <<EOF
Host 127.0.0.1
    IdentityFile $INT_SSH_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
chmod 600 "$T19_SSH_CFG"

_int_make_jobs "$T19_JOBS" \
    "$INT_FIXTURES/multi.7z|rsync|t19/multi"

set +e
EXTRACT_DIR="$T19_EXTRACT" QUEUE_DIR="$INT_QUEUE/t19" \
RSYNC_DEST_BASE="$T19_DEST" \
RSYNC_HOST="127.0.0.1" \
RSYNC_USER="root" \
RSYNC_SSH_PORT="$INT_SSH_PORT" \
bash "$PIPELINE" "$T19_JOBS" >"$T19_LOG" 2>&1
t19_rc=$?
set -e

# Clean up SSH config: remove the block we appended.
if (( T19_HAD_SSH_CFG )); then
    head -n -5 "$T19_SSH_CFG" > "${T19_SSH_CFG}.tmp" && mv "${T19_SSH_CFG}.tmp" "$T19_SSH_CFG"
else
    rm -f "$T19_SSH_CFG"
fi

assert_rc "$t19_rc" 0 "Test 19 pipeline rc"
assert_tree_eq "$T18_EXP" "$T19_DEST/t19/multi" "Test 19 rsync remote adapter tree"
