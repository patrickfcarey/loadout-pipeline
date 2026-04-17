#!/usr/bin/env bash
# test/integration/suites/07_adapters.sh
#
# Adapter coverage. lvol, rsync, ftp, rclone, and hdl_dump are all
# implemented and tested end-to-end against real substrates with byte-exact
# tree verification (or toc-verify, for hdl_dump), idempotent re-run
# (precheck skip), and multi-member archive handling. Test 15b is a
# load-time negative test that locks in the 4-field hdl job format.

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

# ─── Test 15: hdl_dump adapter — real inject + toc verify + precheck skip ─

header "Int Test 15: hdl_dump adapter — inject & toc verify (mock shim)"

T15_TITLE="PS2 Test Game"
T15_DIR="$INT_STATE/t15"
T15_EXTRACT="$INT_EXTRACT/t15"
T15_JOBS="$T15_DIR/t15.jobs"
T15_LOG1="$INT_STATE/t15_run1.log"
T15_LOG2="$INT_STATE/t15_run2.log"
# Post-refactor, the host path and device id are no longer part of the job
# line. The operator supplies HDL_INSTALL_TARGET as an env var, and the
# pipeline (plus this test) relies on $HOME/.hdl_dump.conf to resolve that
# target to a host path — exactly like real hdl_dump. We stage a scratch
# HOME just for Test 15 so we never touch /root/.hdl_dump.conf.
T15_HOME="$INT_STATE/t15_home"
T15_HDD_PATH="$INT_HDL_STATE/fake_hdd0.img"
T15_TARGET="${INT_HDL_DEVICE}:"
rm -rf "$T15_DIR" "$T15_EXTRACT" "$T15_HOME"
mkdir -p "$T15_DIR" "$T15_EXTRACT" "$T15_HOME"
printf '%s %s rw\n' "$INT_HDL_DEVICE" "$T15_HDD_PATH" > "$T15_HOME/.hdl_dump.conf"

_int_make_jobs "$T15_JOBS" \
    "$INT_FIXTURES/ps2_synth.7z|hdl|cd|$T15_TITLE"

# Run 1: full extract + inject. HDL_INSTALL_TARGET selects the hdl_dump
# target; HDL_HOST_DEVICE exercises the startup writability probe. Both
# resolve to the same mock-backed device in this test. HOME is redirected
# so hdl_dump reads our scratch config instead of /root/.hdl_dump.conf.
set +e
HOME="$T15_HOME" \
EXTRACT_DIR="$T15_EXTRACT" QUEUE_DIR="$INT_QUEUE/t15" \
HDL_DUMP_BIN="hdl_dump" \
HDL_INSTALL_TARGET="$T15_TARGET" \
HDL_HOST_DEVICE="$T15_TARGET" \
bash "$PIPELINE" "$T15_JOBS" >"$T15_LOG1" 2>&1
t15_rc1=$?
set -e

if (( t15_rc1 != 0 )); then
    fail "Test 15 run 1 pipeline rc: exit $t15_rc1 (expected 0)"
    echo "      --- pipeline log (last 30 lines) ---"
    tail -30 "$T15_LOG1" | sed 's/^/      /'
else
    pass "Test 15 run 1 pipeline rc: exit 0"
fi

# Verify the inject landed by running `hdl_dump toc` against the mock with
# the same scratch HOME. If the adapter had leaked HOME modifications into
# our environment, this call would read from the wrong config and fail.
set +e
t15_toc="$(HOME="$T15_HOME" hdl_dump toc "$T15_TARGET" 2>/dev/null)"
set -e
if echo "$t15_toc" | grep -qF "$T15_TITLE"; then
    pass "Test 15 hdl_dump toc contains '$T15_TITLE'"
else
    fail "Test 15 hdl_dump toc missing '$T15_TITLE'"
    echo "      --- hdl_dump toc output ---"
    echo "$t15_toc" | sed 's/^/      /'
fi

# Run 2: same job, same destination — precheck should detect the title on
# the target and skip the extract+inject path entirely.
rm -rf "$T15_EXTRACT"
mkdir -p "$T15_EXTRACT"

set +e
HOME="$T15_HOME" \
EXTRACT_DIR="$T15_EXTRACT" QUEUE_DIR="$INT_QUEUE/t15" \
HDL_DUMP_BIN="hdl_dump" \
HDL_INSTALL_TARGET="$T15_TARGET" \
HDL_HOST_DEVICE="$T15_TARGET" \
RESUME_PLANNER_IND=0 \
bash "$PIPELINE" "$T15_JOBS" >"$T15_LOG2" 2>&1
t15_rc2=$?
set -e

assert_rc "$t15_rc2" 0 "Test 15 run 2 pipeline rc"
if grep -qF '[skip]' "$T15_LOG2"; then
    pass "Test 15 precheck logged [skip] on re-run"
else
    fail "Test 15 precheck did not log [skip] on re-run"
    sed 's/^/      /' "$T15_LOG2"
fi

# A skipped run must not have re-extracted any ISO into the scratch dir.
if find "$T15_EXTRACT" -name '*.iso' -print -quit 2>/dev/null | grep -q .; then
    fail "Test 15 extract NOT skipped on re-run — ISO present under $T15_EXTRACT"
else
    pass "Test 15 extract skipped on re-run (no ISO in $T15_EXTRACT)"
fi

rm -rf "$T15_DIR" "$T15_EXTRACT" "$T15_HOME"

# ─── Test 15b: hdl job load-time validation ────────────────────────────────
# The hdl adapter is the only one that uses 4-field job lines
# (~<iso>|hdl|<cd|dvd>|<title>~). load_jobs must reject every malformed form
# at parse time so operators see the error before a worker ever dispatches.
# We rely on the bin/loadout-pipeline.sh exit code (≠0) as the signal; each
# bad-job file below is run in isolation so one rejection does not mask
# another.

header "Int Test 15b: hdl job load-time validation"

T15B_DIR="$INT_STATE/t15b"
rm -rf "$T15B_DIR"; mkdir -p "$T15B_DIR"

_t15b_expect_reject() {
    local label="$1"; shift
    local job_body="$1"; shift
    local jobs_file="$T15B_DIR/${label}.jobs"
    local log_file="$T15B_DIR/${label}.log"
    _int_make_jobs "$jobs_file" "$job_body"
    set +e
    EXTRACT_DIR="$INT_EXTRACT/t15b_${label}" QUEUE_DIR="$INT_QUEUE/t15b_${label}" \
    HDL_DUMP_BIN="hdl_dump" \
    HDL_INSTALL_TARGET="$T15_TARGET" \
    bash "$PIPELINE" "$jobs_file" >"$log_file" 2>&1
    local rc=$?
    set -e
    if (( rc != 0 )); then
        pass "Test 15b rejects $label (rc=$rc)"
    else
        fail "Test 15b accepted $label (expected rejection)"
        sed 's/^/      /' "$log_file"
    fi
}

# Missing title (3-field line — dest field is just the format).
_t15b_expect_reject "missing_title" \
    "$INT_FIXTURES/ps2_synth.7z|hdl|cd"
# Empty title (trailing '|' leaves parse_hdl_destination with title="").
_t15b_expect_reject "empty_title" \
    "$INT_FIXTURES/ps2_synth.7z|hdl|cd|"
# Bogus format literal (neither cd nor dvd).
_t15b_expect_reject "bogus_format" \
    "$INT_FIXTURES/ps2_synth.7z|hdl|bluray|$T15_TITLE"
# Extra trailing field beyond <format>|<title>.
_t15b_expect_reject "extra_trailing_field" \
    "$INT_FIXTURES/ps2_synth.7z|hdl|cd|$T15_TITLE|stray"

rm -rf "$T15B_DIR"

# ─── Test 16: ftp adapter — real lftp transfer to pure-ftpd loopback ──────

header "Int Test 16: ftp adapter — local loopback transfer"

T16_DIR="$INT_STATE/t16"
T16_EXTRACT="$INT_EXTRACT/t16"
T16_JOBS="$T16_DIR/t16.jobs"
T16_LOG="$INT_STATE/t16.log"
rm -rf "$T16_DIR" "$T16_EXTRACT" "$INT_FTP_ROOT/t16"
mkdir -p "$T16_DIR" "$T16_EXTRACT"

_int_make_jobs "$T16_JOBS" \
    "$INT_FIXTURES/multi.7z|ftp|t16/multi"

set +e
EXTRACT_DIR="$T16_EXTRACT" QUEUE_DIR="$INT_QUEUE/t16" \
FTP_HOST="127.0.0.1" \
FTP_USER="$INT_FTP_USER" \
FTP_PASS="$INT_FTP_PASS" \
FTP_PORT="$INT_FTP_PORT" \
bash "$PIPELINE" "$T16_JOBS" >"$T16_LOG" 2>&1
t16_rc=$?
set -e

if (( t16_rc != 0 )); then
    fail "Test 16 pipeline rc: exit $t16_rc (expected 0)"
    echo "      --- pipeline log (last 30 lines) ---"
    tail -30 "$T16_LOG" | sed 's/^/      /'
    echo "      --- FTP root contents ---"
    find "$INT_FTP_ROOT" -type f 2>/dev/null | head -10 | sed 's/^/      /' || true
else
    pass "Test 16 pipeline rc: exit 0"
fi

T16_EXP="$INT_STATE/t16_expected"
rm -rf "$T16_EXP"
mkdir -p "$T16_EXP"
( cd "$T16_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T16_EXP" "$INT_FTP_ROOT/t16/multi" "Test 16 ftp adapter tree"
rm -rf "$T16_EXP"

# ─── Test 17: rclone adapter — local remote transfer ──────────────────────

header "Int Test 17: rclone adapter — local remote transfer"

T17_DIR="$INT_STATE/t17"
T17_EXTRACT="$INT_EXTRACT/t17"
T17_JOBS="$T17_DIR/t17.jobs"
T17_LOG="$INT_STATE/t17.log"
rm -rf "$T17_DIR" "$T17_EXTRACT" "$INT_RCLONE_BASE/t17"
mkdir -p "$T17_DIR" "$T17_EXTRACT"

_int_make_jobs "$T17_JOBS" \
    "$INT_FIXTURES/multi.7z|rclone|t17/multi"

set +e
EXTRACT_DIR="$T17_EXTRACT" QUEUE_DIR="$INT_QUEUE/t17" \
RCLONE_REMOTE="$INT_RCLONE_REMOTE" \
RCLONE_DEST_BASE="$INT_RCLONE_BASE" \
RCLONE_CONFIG="$INT_RCLONE_CONF" \
RCLONE_FLAGS="" \
bash "$PIPELINE" "$T17_JOBS" >"$T17_LOG" 2>&1
t17_rc=$?
set -e

assert_rc "$t17_rc" 0 "Test 17 pipeline rc"

T17_EXP="$INT_STATE/t17_expected"
rm -rf "$T17_EXP"
mkdir -p "$T17_EXP"
( cd "$T17_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T17_EXP" "$INT_RCLONE_BASE/t17/multi" "Test 17 rclone adapter tree"
rm -rf "$T17_EXP"

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
rm -rf "$T18_EXP"

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

T19_EXP="$INT_STATE/t19_expected"
rm -rf "$T19_EXP"
mkdir -p "$T19_EXP"
( cd "$T19_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T19_EXP" "$T19_DEST/t19/multi" "Test 19 rsync remote adapter tree"
rm -rf "$T19_EXP"

# ─── Test 16b: ftp adapter — idempotent re-run (precheck skip) ──────────────

header "Int Test 16b: ftp adapter — idempotent re-run (precheck skip)"

T16B_DIR="$INT_STATE/t16b"
T16B_EXTRACT="$INT_EXTRACT/t16b"
T16B_JOBS="$T16B_DIR/t16b.jobs"
T16B_LOG1="$INT_STATE/t16b_run1.log"
T16B_LOG2="$INT_STATE/t16b_run2.log"
rm -rf "$T16B_DIR" "$T16B_EXTRACT" "$INT_FTP_ROOT/t16b"
mkdir -p "$T16B_DIR" "$T16B_EXTRACT"

_int_make_jobs "$T16B_JOBS" \
    "$INT_FIXTURES/small.7z|ftp|t16b/small"

# Run 1: full transfer
set +e
EXTRACT_DIR="$T16B_EXTRACT" QUEUE_DIR="$INT_QUEUE/t16b" \
FTP_HOST="127.0.0.1" \
FTP_USER="$INT_FTP_USER" \
FTP_PASS="$INT_FTP_PASS" \
FTP_PORT="$INT_FTP_PORT" \
bash "$PIPELINE" "$T16B_JOBS" >"$T16B_LOG1" 2>&1
t16b_rc1=$?
set -e

assert_rc "$t16b_rc1" 0 "Test 16b run 1 pipeline rc"
assert_file_present "$INT_FTP_ROOT/t16b/small/small.iso" "Test 16b run 1 file on FTP"

# Run 2: same job, same destination — precheck should detect content and skip.
rm -rf "$T16B_EXTRACT"
mkdir -p "$T16B_EXTRACT"

set +e
EXTRACT_DIR="$T16B_EXTRACT" QUEUE_DIR="$INT_QUEUE/t16b" \
FTP_HOST="127.0.0.1" \
FTP_USER="$INT_FTP_USER" \
FTP_PASS="$INT_FTP_PASS" \
FTP_PORT="$INT_FTP_PORT" \
RESUME_PLANNER_IND=0 \
bash "$PIPELINE" "$T16B_JOBS" >"$T16B_LOG2" 2>&1
t16b_rc2=$?
set -e

assert_rc "$t16b_rc2" 0 "Test 16b run 2 pipeline rc"
if grep -qF '[skip]' "$T16B_LOG2"; then
    pass "Test 16b precheck logged [skip] on re-run"
else
    fail "Test 16b precheck did not log [skip] on re-run"
    sed 's/^/      /' "$T16B_LOG2"
fi
assert_file_absent "$T16B_EXTRACT/small/small.iso" "Test 16b extract skipped on re-run"

rm -rf "$T16B_DIR" "$T16B_EXTRACT"

# ─── Test 17b: rclone adapter — idempotent re-run (precheck skip) ───────────

header "Int Test 17b: rclone adapter — idempotent re-run (precheck skip)"

T17B_DIR="$INT_STATE/t17b"
T17B_EXTRACT="$INT_EXTRACT/t17b"
T17B_JOBS="$T17B_DIR/t17b.jobs"
T17B_LOG1="$INT_STATE/t17b_run1.log"
T17B_LOG2="$INT_STATE/t17b_run2.log"
rm -rf "$T17B_DIR" "$T17B_EXTRACT" "$INT_RCLONE_BASE/t17b"
mkdir -p "$T17B_DIR" "$T17B_EXTRACT"

_int_make_jobs "$T17B_JOBS" \
    "$INT_FIXTURES/small.7z|rclone|t17b/small"

# Run 1: full transfer
set +e
EXTRACT_DIR="$T17B_EXTRACT" QUEUE_DIR="$INT_QUEUE/t17b" \
RCLONE_REMOTE="$INT_RCLONE_REMOTE" \
RCLONE_DEST_BASE="$INT_RCLONE_BASE" \
RCLONE_CONFIG="$INT_RCLONE_CONF" \
RCLONE_FLAGS="" \
bash "$PIPELINE" "$T17B_JOBS" >"$T17B_LOG1" 2>&1
t17b_rc1=$?
set -e

assert_rc "$t17b_rc1" 0 "Test 17b run 1 pipeline rc"
assert_file_present "$INT_RCLONE_BASE/t17b/small/small.iso" "Test 17b run 1 file on rclone remote"

# Run 2: same job, same destination — precheck should detect content and skip.
rm -rf "$T17B_EXTRACT"
mkdir -p "$T17B_EXTRACT"

set +e
EXTRACT_DIR="$T17B_EXTRACT" QUEUE_DIR="$INT_QUEUE/t17b" \
RCLONE_REMOTE="$INT_RCLONE_REMOTE" \
RCLONE_DEST_BASE="$INT_RCLONE_BASE" \
RCLONE_CONFIG="$INT_RCLONE_CONF" \
RCLONE_FLAGS="" \
RESUME_PLANNER_IND=0 \
bash "$PIPELINE" "$T17B_JOBS" >"$T17B_LOG2" 2>&1
t17b_rc2=$?
set -e

assert_rc "$t17b_rc2" 0 "Test 17b run 2 pipeline rc"
if grep -qF '[skip]' "$T17B_LOG2"; then
    pass "Test 17b precheck logged [skip] on re-run"
else
    fail "Test 17b precheck did not log [skip] on re-run"
    sed 's/^/      /' "$T17B_LOG2"
fi
assert_file_absent "$T17B_EXTRACT/small/small.iso" "Test 17b extract skipped on re-run"

rm -rf "$T17B_DIR" "$T17B_EXTRACT"

# ─── Test 16c: ftp adapter — multi-member archive, byte-exact ───────────────

header "Int Test 16c: ftp adapter — multi-member archive"

T16C_DIR="$INT_STATE/t16c"
T16C_EXTRACT="$INT_EXTRACT/t16c"
T16C_JOBS="$T16C_DIR/t16c.jobs"
T16C_LOG="$INT_STATE/t16c.log"
rm -rf "$T16C_DIR" "$T16C_EXTRACT" "$INT_FTP_ROOT/t16c"
mkdir -p "$T16C_DIR" "$T16C_EXTRACT"

_int_make_jobs "$T16C_JOBS" \
    "$INT_FIXTURES/multi.7z|ftp|t16c/multi"

set +e
EXTRACT_DIR="$T16C_EXTRACT" QUEUE_DIR="$INT_QUEUE/t16c" \
FTP_HOST="127.0.0.1" \
FTP_USER="$INT_FTP_USER" \
FTP_PASS="$INT_FTP_PASS" \
FTP_PORT="$INT_FTP_PORT" \
bash "$PIPELINE" "$T16C_JOBS" >"$T16C_LOG" 2>&1
t16c_rc=$?
set -e

assert_rc "$t16c_rc" 0 "Test 16c pipeline rc"

T16C_EXP="$INT_STATE/t16c_expected"
rm -rf "$T16C_EXP"
mkdir -p "$T16C_EXP"
( cd "$T16C_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T16C_EXP" "$INT_FTP_ROOT/t16c/multi" "Test 16c ftp multi-member tree"
rm -rf "$T16C_EXP"

# ─── Test 17c: rclone adapter — multi-member archive, byte-exact ────────────

header "Int Test 17c: rclone adapter — multi-member archive"

T17C_DIR="$INT_STATE/t17c"
T17C_EXTRACT="$INT_EXTRACT/t17c"
T17C_JOBS="$T17C_DIR/t17c.jobs"
T17C_LOG="$INT_STATE/t17c.log"
rm -rf "$T17C_DIR" "$T17C_EXTRACT" "$INT_RCLONE_BASE/t17c"
mkdir -p "$T17C_DIR" "$T17C_EXTRACT"

_int_make_jobs "$T17C_JOBS" \
    "$INT_FIXTURES/multi.7z|rclone|t17c/multi"

set +e
EXTRACT_DIR="$T17C_EXTRACT" QUEUE_DIR="$INT_QUEUE/t17c" \
RCLONE_REMOTE="$INT_RCLONE_REMOTE" \
RCLONE_DEST_BASE="$INT_RCLONE_BASE" \
RCLONE_CONFIG="$INT_RCLONE_CONF" \
RCLONE_FLAGS="" \
bash "$PIPELINE" "$T17C_JOBS" >"$T17C_LOG" 2>&1
t17c_rc=$?
set -e

assert_rc "$t17c_rc" 0 "Test 17c pipeline rc"

T17C_EXP="$INT_STATE/t17c_expected"
rm -rf "$T17C_EXP"
mkdir -p "$T17C_EXP"
( cd "$T17C_EXP" && 7z x -y "$INT_FIXTURES/multi.7z" >/dev/null )
assert_tree_eq "$T17C_EXP" "$INT_RCLONE_BASE/t17c/multi" "Test 17c rclone multi-member tree"
rm -rf "$T17C_EXP"
