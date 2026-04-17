#!/usr/bin/env bash
# test/integration/suites/04_failure_handling.sh
#
# Real-environment failure and crash recovery:
#   - Corrupted archive triggers real 7z extract failure → EXIT trap fires
#   - Real SIGKILL via an inject_sigkill_after watcher → trap bypassed
#
# No shims anywhere: every failure is a real kernel or subprocess event.

# ─── Test 8: corrupt archive → 7z rc=1 → trap fires ─────────────────────────

header "Int Test 8: corrupted archive, trap fires, no litter"

T8_DIR="$INT_STATE/t8"
T8_COPY="$T8_DIR/copy"
T8_EXTRACT="$T8_DIR/extract"
T8_QUEUE="$INT_QUEUE/t8"
T8_LOG="$INT_STATE/t8.log"
T8_JOBS="$T8_DIR/t8.jobs"
T8_BAD="$T8_DIR/bad.7z"
rm -rf "$T8_DIR"
mkdir -p "$T8_DIR" "$T8_COPY" "$T8_EXTRACT"

# Truncate a real 7z to 128 bytes. The archive header survives so `7z l`
# succeeds, but `7z x` hits a checksum error and exits non-zero — giving
# the EXIT trap a real failure to clean up.
head -c 128 "$INT_FIXTURES/small.7z" > "$T8_BAD"

{ echo '---JOBS---'; echo "~$T8_BAD|lvol|t8/bad~"; echo '---END---'; } > "$T8_JOBS"

set +e
MAX_UNZIP=1 \
COPY_DIR="$T8_COPY" \
EXTRACT_DIR="$T8_EXTRACT" \
QUEUE_DIR="$T8_QUEUE" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T8_JOBS" >"$T8_LOG" 2>&1
t8_rc=$?
set -e

if (( t8_rc != 0 )); then
    pass "Test 8: pipeline rc=$t8_rc (non-zero on corrupt archive)"
else
    fail "Test 8: pipeline returned 0 despite corrupt archive"
    sed 's/^/      /' "$T8_LOG"
fi

# Scratch copies must be gone (trap released them).
scratch=$(find "$T8_COPY" -name '*.7z.*' 2>/dev/null | wc -l)
if (( scratch == 0 )); then
    pass "Test 8: no scratch copies left under $T8_COPY"
else
    fail "Test 8: $scratch scratch file(s) leaked under $T8_COPY"
fi

# Partial extract dirs must be gone (trap cleaned them).
partials=$(find "$T8_EXTRACT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
if (( partials == 0 )); then
    pass "Test 8: no partial extract dirs under $T8_EXTRACT"
else
    fail "Test 8: $partials partial dir(s) leaked under $T8_EXTRACT"
fi

# Ledger must be fully drained.
if [[ ! -s "$T8_QUEUE/.space_ledger" ]]; then
    pass "Test 8: space ledger drained"
else
    fail "Test 8: space ledger still has entries"
    sed 's/^/      /' "$T8_QUEUE/.space_ledger"
fi

# ─── Test 9: real SIGKILL mid-extract → trap bypass → rerun recovers ───────

header "Int Test 9: real SIGKILL mid-extract, rerun recovers"

T9_DIR="$INT_STATE/t9"
T9_COPY="$T9_DIR/copy"
T9_EXTRACT="$T9_DIR/extract"
T9_QUEUE="$INT_QUEUE/t9"
T9_LOG="$INT_STATE/t9.log"
T9_JOBS="$T9_DIR/t9.jobs"
rm -rf "$T9_DIR" "$INT_SD_VFAT/t9"
mkdir -p "$T9_DIR" "$T9_COPY" "$T9_EXTRACT"

# Use the large archive so the 7z process has enough runtime for the
# watcher to find and kill it before extraction completes.
{ echo '---JOBS---'; echo "~$INT_FIXTURES/large.7z|lvol|t9/large~"; echo '---END---'; } > "$T9_JOBS"

# Fire a watcher that kills 7z ~0.2s after it first appears. Real SIGKILL
# on 7z: extract.sh sees the child die and exits non-zero, but its own
# process is killed too because 7z sends SIGPIPE back through.
T9_SENTINEL="$T9_DIR/.sigkill_fired"
watcher_pid=$(inject_sigkill_after "^7z" 0.2 "$T9_SENTINEL")

set +e
MAX_UNZIP=1 \
COPY_DIR="$T9_COPY" \
EXTRACT_DIR="$T9_EXTRACT" \
QUEUE_DIR="$T9_QUEUE" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T9_JOBS" >"$T9_LOG" 2>&1
t9_rc=$?
set -e

wait "$watcher_pid" 2>/dev/null || true

if [[ -f "$T9_SENTINEL" ]]; then
    if (( t9_rc != 0 )); then
        pass "Test 9: pipeline rc=$t9_rc (non-zero after SIGKILL on 7z)"
    else
        fail "Test 9: SIGKILL delivered but pipeline returned 0"
    fi
else
    echo -e "  ${DIM}[SKIP]${RESET} Test 9: 7z finished before watcher could deliver SIGKILL"
fi

# Rerun with real state — no watcher this time. The pipeline must recover.
set +e
MAX_UNZIP=1 \
COPY_DIR="$T9_COPY" \
EXTRACT_DIR="$T9_EXTRACT" \
QUEUE_DIR="$T9_QUEUE" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T9_JOBS" >"$INT_STATE/t9_rerun.log" 2>&1
t9_rerun_rc=$?
set -e

assert_rc "$t9_rerun_rc" 0 "Test 9 rerun rc"

T9_EXP="$INT_STATE/t9_expected"
rm -rf "$T9_EXP"
mkdir -p "$T9_EXP"
( cd "$T9_EXP" && 7z x -y "$INT_FIXTURES/large.7z" >/dev/null )
assert_tree_eq "$T9_EXP" "$INT_SD_VFAT/t9/large" "Test 9 final vfat tree"

# ─── Test 9b: rerun after corrupt archive recovers on vfat ──────────────
#
# Run 1: one corrupt archive + one good archive. The pipeline must fail
# (corrupt job) but the good job may or may not complete. Run 2: replace
# the corrupt archive with a valid one and re-run without cleaning state.
# The pipeline must recover and produce correct output for both jobs.

header "Int Test 9b: rerun after corrupt archive recovers on vfat"

T9B_DIR="$INT_STATE/t9b"
T9B_COPY="$T9B_DIR/copy"
T9B_EXTRACT="$T9B_DIR/extract"
T9B_QUEUE="$INT_QUEUE/t9b"
T9B_JOBS="$T9B_DIR/t9b.jobs"
T9B_BAD="$T9B_DIR/bad.7z"
rm -rf "$T9B_DIR" "$INT_SD_VFAT/t9b"
mkdir -p "$T9B_DIR" "$T9B_COPY" "$T9B_EXTRACT"

head -c 128 "$INT_FIXTURES/small.7z" > "$T9B_BAD"

_int_make_jobs "$T9B_JOBS" \
    "$T9B_BAD|lvol|t9b/bad" \
    "$INT_FIXTURES/medium.7z|lvol|t9b/good"

set +e
MAX_UNZIP=1 \
COPY_DIR="$T9B_COPY" \
EXTRACT_DIR="$T9B_EXTRACT" \
QUEUE_DIR="$T9B_QUEUE" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T9B_JOBS" >"$INT_STATE/t9b_run1.log" 2>&1
t9b_run1_rc=$?
set -e

if (( t9b_run1_rc != 0 )); then
    pass "Test 9b run 1: rc=$t9b_run1_rc (non-zero on corrupt archive)"
else
    fail "Test 9b run 1: pipeline returned 0 despite corrupt archive"
fi

# Fix: replace the corrupt archive with a valid one and rebuild jobs.
cp "$INT_FIXTURES/small.7z" "$T9B_BAD"
_int_make_jobs "$T9B_JOBS" \
    "$T9B_BAD|lvol|t9b/bad" \
    "$INT_FIXTURES/medium.7z|lvol|t9b/good"

set +e
MAX_UNZIP=1 \
COPY_DIR="$T9B_COPY" \
EXTRACT_DIR="$T9B_EXTRACT" \
QUEUE_DIR="$T9B_QUEUE" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T9B_JOBS" >"$INT_STATE/t9b_run2.log" 2>&1
t9b_run2_rc=$?
set -e

assert_rc "$t9b_run2_rc" 0 "Test 9b run 2 pipeline rc"

T9B_EXP="$INT_STATE/t9b_expected"
rm -rf "$T9B_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$T9B_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$T9B_EXP/medium"
assert_tree_eq "$T9B_EXP/small"  "$INT_SD_VFAT/t9b/bad"  "Test 9b rerun bad-now-fixed on vfat"
assert_tree_eq "$T9B_EXP/medium" "$INT_SD_VFAT/t9b/good" "Test 9b rerun good on vfat"
rm -rf "$T9B_EXP"

scratch=$(find "$T9B_COPY" -name '*.7z.*' 2>/dev/null | wc -l)
if (( scratch == 0 )); then
    pass "Test 9b: no scratch copies left"
else
    fail "Test 9b: $scratch scratch file(s) leaked under $T9B_COPY"
fi
