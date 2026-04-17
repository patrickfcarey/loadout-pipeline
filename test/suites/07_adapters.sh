#!/usr/bin/env bash
# test/suites/07_adapters.sh
#
# Adapter tests: verifies that the extract→dispatch wiring is correct for
# all adapters. Each end-to-end test runs a single job through the full
# pipeline and checks extraction + transfer. Validation tests exercise
# each adapter's input guards and stub fallback path directly.

# ── test 16: rclone adapter end-to-end ────────────────────────────────────────
#
# Runs a single job through the full pipeline using the rclone adapter with a
# temporary local remote. Requires rclone on PATH; skips if absent.

header "Test 16: rclone adapter"

if ! command -v rclone >/dev/null 2>&1; then
    pass "[SKIP] rclone not installed — adapter test requires rclone on PATH"
else
    RCLONE_EXTRACT="/tmp/iso_pipeline_test_rclone_$$"
    RCLONE_DEST="/tmp/iso_pipeline_test_rclone_dest_$$"
    RCLONE_JOBS="/tmp/iso_pipeline_test_rclone_$$.jobs"
    RCLONE_LOG="/tmp/iso_pipeline_test_rclone_$$.log"
    RCLONE_CONF="/tmp/iso_pipeline_test_rclone_$$.conf"
    mkdir -p "$RCLONE_DEST"
    cat > "$RCLONE_CONF" <<'RCLCONF'
[test_local]
type = local
RCLCONF
    { echo '---JOBS---'; echo "~$ROOT_DIR/test/fixtures/isos/game1.7z|rclone|games/game1~"; echo '---END---'; } > "$RCLONE_JOBS"

    echo "  cmd: EXTRACT_DIR=$RCLONE_EXTRACT RCLONE_REMOTE=test_local RCLONE_DEST_BASE=$RCLONE_DEST bash bin/loadout-pipeline.sh $RCLONE_JOBS"
    EXTRACT_DIR="$RCLONE_EXTRACT" \
        RCLONE_REMOTE="test_local" \
        RCLONE_DEST_BASE="$RCLONE_DEST" \
        RCLONE_CONFIG="$RCLONE_CONF" \
        RCLONE_FLAGS="" \
        bash "$PIPELINE" "$RCLONE_JOBS" >"$RCLONE_LOG" 2>&1

    if [[ -f "$RCLONE_EXTRACT/game1/game1.iso" ]]; then
        pass "game1 extracted for rclone adapter"
    else
        fail "game1 not extracted for rclone adapter"
        sed 's/^/      /' "$RCLONE_LOG"
    fi

    if [[ -f "$RCLONE_DEST/games/game1/game1.iso" ]]; then
        pass "game1 transferred via rclone to local destination"
    else
        fail "game1 not found at rclone destination"
        sed 's/^/      /' "$RCLONE_LOG"
    fi

    if grep -q '\[rclone\] Transferring' "$RCLONE_LOG"; then
        pass "rclone transfer log line present"
    else
        fail "expected [rclone] Transferring log line not found"
        sed 's/^/      /' "$RCLONE_LOG"
    fi

    rm -rf "$RCLONE_EXTRACT" "$RCLONE_DEST" "$RCLONE_JOBS" "$RCLONE_LOG" "$RCLONE_CONF"
fi

# ── test 17: rsync adapter — local transfer ──────────────────────────────────
#
# Runs a single job through the full pipeline using the rsync adapter in local
# mode (no RSYNC_HOST). Verifies that:
#   1. The archive is extracted correctly.
#   2. Files arrive at the rsync destination.
#   3. The transfer log line is present.

header "Test 17a: rsync adapter — local transfer"

RSYNC_EXTRACT="/tmp/iso_pipeline_test_rsync_$$"
RSYNC_DEST="/tmp/iso_pipeline_test_rsync_dest_$$"
RSYNC_JOBS="/tmp/iso_pipeline_test_rsync_$$.jobs"
RSYNC_LOG="/tmp/iso_pipeline_test_rsync_$$.log"
mkdir -p "$RSYNC_DEST"
{ echo '---JOBS---'; echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|rsync|games/game2~"; echo '---END---'; } > "$RSYNC_JOBS"

echo "  cmd: EXTRACT_DIR=$RSYNC_EXTRACT RSYNC_DEST_BASE=$RSYNC_DEST bash bin/loadout-pipeline.sh $RSYNC_JOBS"
EXTRACT_DIR="$RSYNC_EXTRACT" \
    RSYNC_DEST_BASE="$RSYNC_DEST" \
    bash "$PIPELINE" "$RSYNC_JOBS" >"$RSYNC_LOG" 2>&1

if [[ -f "$RSYNC_EXTRACT/game2/game2.iso" ]]; then
    pass "game2 extracted for rsync adapter"
else
    fail "game2 not extracted for rsync adapter"
    sed 's/^/      /' "$RSYNC_LOG"
fi

if [[ -f "$RSYNC_DEST/games/game2/game2.iso" ]]; then
    pass "game2 transferred via rsync to local destination"
else
    fail "game2 not found at rsync destination"
    sed 's/^/      /' "$RSYNC_LOG"
fi

if grep -q '\[rsync\] Transferring' "$RSYNC_LOG"; then
    pass "rsync transfer log line present"
else
    fail "expected [rsync] Transferring log line not found"
    sed 's/^/      /' "$RSYNC_LOG"
fi

# ── test 17b: rsync adapter — idempotent re-run ─────────────────────────────
#
# Re-runs the same job against the same destination. rsync -c skips files
# whose checksums match, so this should succeed near-instantly.

header "Test 17b: rsync adapter — idempotent re-run"

{ echo '---JOBS---'; echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|rsync|games/game2~"; echo '---END---'; } > "$RSYNC_JOBS"

RSYNC_RERUN_LOG="/tmp/iso_pipeline_test_rsync_rerun_$$.log"
EXTRACT_DIR="$RSYNC_EXTRACT" \
    RSYNC_DEST_BASE="$RSYNC_DEST" \
    bash "$PIPELINE" "$RSYNC_JOBS" >"$RSYNC_RERUN_LOG" 2>&1
RSYNC_RERUN_RC=$?

if (( RSYNC_RERUN_RC == 0 )); then
    pass "rsync idempotent re-run succeeded"
else
    fail "rsync idempotent re-run failed with rc=$RSYNC_RERUN_RC"
    sed 's/^/      /' "$RSYNC_RERUN_LOG"
fi

# ── test 17c: rsync adapter — containment check ─────────────────────────────
#
# Invokes the adapter directly (not through the pipeline) to exercise the
# adapter-level containment check. The pipeline's job loader also rejects
# ".." paths, but this tests the adapter's own defense-in-depth layer.

header "Test 17c: rsync adapter — containment escape rejected"

RSYNC_ESCAPE_LOG="/tmp/iso_pipeline_test_rsync_escape_$$.log"
RSYNC_ESCAPE_SRC="/tmp/iso_pipeline_test_rsync_escape_src_$$"
mkdir -p "$RSYNC_ESCAPE_SRC"

RSYNC_ESCAPE_RC=0
RSYNC_DEST_BASE="$RSYNC_DEST" \
    bash "$ROOT_DIR/adapters/rsync.sh" \
    "$RSYNC_ESCAPE_SRC" "../../etc/evil" >"$RSYNC_ESCAPE_LOG" 2>&1 || RSYNC_ESCAPE_RC=$?

if (( RSYNC_ESCAPE_RC != 0 )); then
    pass "rsync containment escape correctly rejected"
else
    fail "rsync containment escape was not rejected"
    sed 's/^/      /' "$RSYNC_ESCAPE_LOG"
fi

if grep -q 'escapes RSYNC_DEST_BASE' "$RSYNC_ESCAPE_LOG"; then
    pass "rsync containment error message present"
else
    fail "expected containment error message not found"
    sed 's/^/      /' "$RSYNC_ESCAPE_LOG"
fi

rm -rf "$RSYNC_EXTRACT" "$RSYNC_DEST" "$RSYNC_ESCAPE_SRC" \
       "$RSYNC_JOBS" "$RSYNC_LOG" "$RSYNC_RERUN_LOG" \
       "$RSYNC_ESCAPE_LOG"

# ── test 18: ftp adapter — validation & stub fallback ────────────────────────
#
# The FTP adapter requires an actual FTP server for end-to-end transfer, which
# is only available in the integration suite (pure-ftpd loopback). Here we test
# the adapter's validation layer and stub fallback path directly.

header "Test 18: ftp adapter — validation"

FTP_ADAPT_SRC="/tmp/iso_pipeline_test_ftp_src_$$"
FTP_ADAPT_LOG="/tmp/iso_pipeline_test_ftp_$$.log"
mkdir -p "$FTP_ADAPT_SRC"

# 18a: missing source directory → rc=1
FTP_RC=0
bash "$ROOT_DIR/adapters/ftp.sh" \
    "/nonexistent_$$" "some/dest" >"$FTP_ADAPT_LOG" 2>&1 || FTP_RC=$?
if (( FTP_RC == 1 )); then
    pass "ftp: missing src rejected with rc=1"
else
    fail "ftp: expected rc=1 for missing src, got $FTP_RC"
    sed 's/^/      /' "$FTP_ADAPT_LOG"
fi

# 18b: missing FTP_HOST without ALLOW_STUB_ADAPTERS → rc=1
FTP_RC=0
env -u FTP_HOST -u ALLOW_STUB_ADAPTERS \
    bash "$ROOT_DIR/adapters/ftp.sh" \
    "$FTP_ADAPT_SRC" "some/dest" >"$FTP_ADAPT_LOG" 2>&1 || FTP_RC=$?
if (( FTP_RC == 1 )); then
    pass "ftp: missing FTP_HOST rejected with rc=1"
else
    fail "ftp: expected rc=1 for missing FTP_HOST, got $FTP_RC"
    sed 's/^/      /' "$FTP_ADAPT_LOG"
fi

# 18c: missing FTP_HOST WITH ALLOW_STUB_ADAPTERS=1 → stub no-op rc=0
FTP_RC=0
env -u FTP_HOST ALLOW_STUB_ADAPTERS=1 \
    bash "$ROOT_DIR/adapters/ftp.sh" \
    "$FTP_ADAPT_SRC" "some/dest" >"$FTP_ADAPT_LOG" 2>&1 || FTP_RC=$?
if (( FTP_RC == 0 )); then
    pass "ftp: stub fallback succeeded with rc=0"
else
    fail "ftp: expected rc=0 for stub fallback, got $FTP_RC"
    sed 's/^/      /' "$FTP_ADAPT_LOG"
fi
if grep -q '\[ftp\] STUB' "$FTP_ADAPT_LOG"; then
    pass "ftp: stub fallback logged [ftp] STUB marker"
else
    fail "ftp: stub fallback missing [ftp] STUB log line"
    sed 's/^/      /' "$FTP_ADAPT_LOG"
fi

# 18d: FTP_HOST set but FTP_USER missing → rc=1
FTP_RC=0
env -u ALLOW_STUB_ADAPTERS -u FTP_USER -u FTP_PASS FTP_HOST="127.0.0.1" \
    bash "$ROOT_DIR/adapters/ftp.sh" \
    "$FTP_ADAPT_SRC" "some/dest" >"$FTP_ADAPT_LOG" 2>&1 || FTP_RC=$?
if (( FTP_RC == 1 )); then
    pass "ftp: missing FTP_USER rejected with rc=1"
else
    fail "ftp: expected rc=1 for missing FTP_USER, got $FTP_RC"
    sed 's/^/      /' "$FTP_ADAPT_LOG"
fi

# 18e: FTP_HOST + FTP_USER set but FTP_PASS missing → rc=1
FTP_RC=0
env -u ALLOW_STUB_ADAPTERS -u FTP_PASS FTP_HOST="127.0.0.1" FTP_USER="test" \
    bash "$ROOT_DIR/adapters/ftp.sh" \
    "$FTP_ADAPT_SRC" "some/dest" >"$FTP_ADAPT_LOG" 2>&1 || FTP_RC=$?
if (( FTP_RC == 1 )); then
    pass "ftp: missing FTP_PASS rejected with rc=1"
else
    fail "ftp: expected rc=1 for missing FTP_PASS, got $FTP_RC"
    sed 's/^/      /' "$FTP_ADAPT_LOG"
fi

rm -rf "$FTP_ADAPT_SRC" "$FTP_ADAPT_LOG"

# ── test 18b: rclone adapter — validation & stub fallback ────────────────────

header "Test 18b: rclone adapter — validation"

RCLONE_ADAPT_SRC="/tmp/iso_pipeline_test_rclone_val_src_$$"
RCLONE_ADAPT_LOG="/tmp/iso_pipeline_test_rclone_val_$$.log"
mkdir -p "$RCLONE_ADAPT_SRC"

# 18b-a: missing source directory → rc=1
RCL_RC=0
bash "$ROOT_DIR/adapters/rclone.sh" \
    "/nonexistent_$$" "some/dest" >"$RCLONE_ADAPT_LOG" 2>&1 || RCL_RC=$?
if (( RCL_RC == 1 )); then
    pass "rclone: missing src rejected with rc=1"
else
    fail "rclone: expected rc=1 for missing src, got $RCL_RC"
    sed 's/^/      /' "$RCLONE_ADAPT_LOG"
fi

# 18b-b: missing RCLONE_REMOTE without ALLOW_STUB_ADAPTERS → rc=1
RCL_RC=0
env -u RCLONE_REMOTE -u ALLOW_STUB_ADAPTERS \
    bash "$ROOT_DIR/adapters/rclone.sh" \
    "$RCLONE_ADAPT_SRC" "some/dest" >"$RCLONE_ADAPT_LOG" 2>&1 || RCL_RC=$?
if (( RCL_RC == 1 )); then
    pass "rclone: missing RCLONE_REMOTE rejected with rc=1"
else
    fail "rclone: expected rc=1 for missing RCLONE_REMOTE, got $RCL_RC"
    sed 's/^/      /' "$RCLONE_ADAPT_LOG"
fi

# 18b-c: missing RCLONE_REMOTE WITH ALLOW_STUB_ADAPTERS=1 → stub no-op rc=0
RCL_RC=0
env -u RCLONE_REMOTE ALLOW_STUB_ADAPTERS=1 \
    bash "$ROOT_DIR/adapters/rclone.sh" \
    "$RCLONE_ADAPT_SRC" "some/dest" >"$RCLONE_ADAPT_LOG" 2>&1 || RCL_RC=$?
if (( RCL_RC == 0 )); then
    pass "rclone: stub fallback succeeded with rc=0"
else
    fail "rclone: expected rc=0 for stub fallback, got $RCL_RC"
    sed 's/^/      /' "$RCLONE_ADAPT_LOG"
fi
if grep -q '\[rclone\] STUB' "$RCLONE_ADAPT_LOG"; then
    pass "rclone: stub fallback logged [rclone] STUB marker"
else
    fail "rclone: stub fallback missing [rclone] STUB log line"
    sed 's/^/      /' "$RCLONE_ADAPT_LOG"
fi

rm -rf "$RCLONE_ADAPT_SRC" "$RCLONE_ADAPT_LOG"
