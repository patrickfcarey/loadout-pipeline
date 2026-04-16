#!/usr/bin/env bash
# test/suites/07_adapters.sh
#
# Adapter stub smoke tests: verifies that the extract→dispatch wiring is
# correct for adapters other than the implemented local volume adapter. Each test
# runs a single job through the full pipeline and checks that:
#   1. The archive is extracted correctly.
#   2. The stub's characteristic log line is present in the output.

# ── test 16: rclone adapter stub runs end-to-end ──────────────────────────────
#
# Runs a single job through the full pipeline using the rclone adapter.
# The adapter is still a stub, but this verifies extract→dispatch wiring works
# and the job validates against the adapter regex in jobs.sh.

header "Test 16: rclone adapter stub"

RCLONE_EXTRACT="/tmp/iso_pipeline_test_rclone_$$"
RCLONE_JOBS="/tmp/iso_pipeline_test_rclone_$$.jobs"
RCLONE_LOG="/tmp/iso_pipeline_test_rclone_$$.log"
echo "~$ROOT_DIR/test/fixtures/isos/game1.7z|rclone|remote/games/game1~" > "$RCLONE_JOBS"

echo "  cmd: EXTRACT_DIR=$RCLONE_EXTRACT bash bin/loadout-pipeline.sh $RCLONE_JOBS"
EXTRACT_DIR="$RCLONE_EXTRACT" bash "$PIPELINE" "$RCLONE_JOBS" >"$RCLONE_LOG" 2>&1

if [[ -f "$RCLONE_EXTRACT/game1/game1.iso" ]]; then
    pass "game1 extracted for rclone adapter"
else
    fail "game1 not extracted for rclone adapter"
    sed 's/^/      /' "$RCLONE_LOG"
fi

if grep -q '\[rclone\] STUB' "$RCLONE_LOG"; then
    pass "rclone stub dispatch log line present"
else
    fail "expected [rclone] STUB log line not found"
    sed 's/^/      /' "$RCLONE_LOG"
fi

rm -rf "$RCLONE_EXTRACT" "$RCLONE_JOBS" "$RCLONE_LOG"

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
echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|rsync|games/game2~" > "$RSYNC_JOBS"

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

echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|rsync|games/game2~" > "$RSYNC_JOBS"

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
