#!/usr/bin/env bash
# test/suites/07_adapters.sh
#
# Adapter stub smoke tests: verifies that the extract→dispatch wiring is
# correct for adapters other than the implemented SD card adapter. Each test
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

# ── test 17: rsync adapter stub runs end-to-end ──────────────────────────────
#
# Same structure as test 16 but for the rsync adapter. Verifies both local
# (no RSYNC_HOST) and remote (with RSYNC_HOST) target formatting via the stub
# log line.

header "Test 17: rsync adapter stub — local target"

RSYNC_EXTRACT="/tmp/iso_pipeline_test_rsync_$$"
RSYNC_JOBS="/tmp/iso_pipeline_test_rsync_$$.jobs"
RSYNC_LOG="/tmp/iso_pipeline_test_rsync_$$.log"
echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|rsync|games/game2~" > "$RSYNC_JOBS"

echo "  cmd: EXTRACT_DIR=$RSYNC_EXTRACT RSYNC_DEST_BASE=/mnt/nas bash bin/loadout-pipeline.sh $RSYNC_JOBS"
EXTRACT_DIR="$RSYNC_EXTRACT" \
    RSYNC_DEST_BASE="/mnt/nas" \
    bash "$PIPELINE" "$RSYNC_JOBS" >"$RSYNC_LOG" 2>&1

if [[ -f "$RSYNC_EXTRACT/game2/game2.iso" ]]; then
    pass "game2 extracted for rsync adapter"
else
    fail "game2 not extracted for rsync adapter"
    sed 's/^/      /' "$RSYNC_LOG"
fi

if grep -q '\[rsync\] STUB.*→ /mnt/nas/games/game2' "$RSYNC_LOG"; then
    pass "rsync local target formatted correctly in stub log"
else
    fail "expected rsync local target log line not found"
    sed 's/^/      /' "$RSYNC_LOG"
fi

# Re-run with a remote host set — verify user@host: prefix appears.
RSYNC_REMOTE_LOG="/tmp/iso_pipeline_test_rsync_remote_$$.log"
RSYNC_REMOTE_EXTRACT="/tmp/iso_pipeline_test_rsync_remote_$$"
echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|rsync|games/game2~" > "$RSYNC_JOBS"

EXTRACT_DIR="$RSYNC_REMOTE_EXTRACT" \
    RSYNC_DEST_BASE="/mnt/nas" \
    RSYNC_HOST="nas.local" \
    RSYNC_USER="admin" \
    bash "$PIPELINE" "$RSYNC_JOBS" >"$RSYNC_REMOTE_LOG" 2>&1

if grep -q '\[rsync\] STUB.*→ admin@nas\.local:/mnt/nas/games/game2' "$RSYNC_REMOTE_LOG"; then
    pass "rsync remote target formatted correctly in stub log"
else
    fail "expected rsync remote target log line not found"
    sed 's/^/      /' "$RSYNC_REMOTE_LOG"
fi

rm -rf "$RSYNC_EXTRACT" "$RSYNC_REMOTE_EXTRACT" "$RSYNC_JOBS" "$RSYNC_LOG" "$RSYNC_REMOTE_LOG"
