#!/usr/bin/env bash
# test/suites/05_space_ledger.sh
#
# Space reservation ledger correctness: concurrent reservation serialization
# under an artificially scarce filesystem, and the phantom GC that lets
# SIGKILL'd workers' stale ledger entries be evicted by sibling workers.

# ── test 13: concurrent space reservation under pressure ────────────────────
#
# With MAX_UNZIP=3 and a simulated filesystem that fits only ~one job's worth
# of bytes at a time, all three jobs must still complete successfully. This
# is the direct regression test for the pre-ledger race where `df` run in
# parallel by three workers all saw the same "free" bytes and all committed.
# SPACE_AVAIL_OVERRIDE_BYTES is a test hook in lib/space.sh that replaces the
# real df lookup so we don't need root/tmpfs to simulate scarcity.

header "Test 13: concurrent reservation serializes under scarcity"

SCARCE_COPY_DIR="/tmp/iso_pipeline_test_scarce_copy_$$"
SCARCE_EXTRACT_DIR="/tmp/iso_pipeline_test_scarce_extract_$$"
SCARCE_QUEUE_DIR="/tmp/iso_pipeline_test_scarce_queue_$$"
SCARCE_LOG="/tmp/iso_pipeline_test_scarce_$$.log"

clean_extracts
assert_clean_slate

echo "  cmd: MAX_UNZIP=3 SPACE_AVAIL_OVERRIDE_BYTES=300 SPACE_OVERHEAD_PCT=0 ..."
set +e
MAX_UNZIP=3 \
    SPACE_AVAIL_OVERRIDE_BYTES=300 \
    SPACE_OVERHEAD_PCT=0 \
    COPY_DIR="$SCARCE_COPY_DIR" \
    EXTRACT_DIR="$SCARCE_EXTRACT_DIR" \
    QUEUE_DIR="$SCARCE_QUEUE_DIR" \
    bash "$PIPELINE" "$TEST_JOBS" >"$SCARCE_LOG" 2>&1
scarce_rc=$?
set -e

if [[ $scarce_rc -eq 0 ]]; then
    pass "pipeline completed under scarcity (all 3 jobs reserved in turn)"
else
    fail "pipeline failed under scarcity (rc=$scarce_rc)"
    sed 's/^/      /' "$SCARCE_LOG"
fi
assert_all_extracted "$SCARCE_EXTRACT_DIR"

# Ledger must be empty when the pipeline exits cleanly.
if [[ ! -s "$SCARCE_QUEUE_DIR/.space_ledger" ]]; then
    pass "space ledger drained to empty on clean exit"
else
    fail "space ledger still populated after clean exit:"
    sed 's/^/      /' "$SCARCE_QUEUE_DIR/.space_ledger"
fi

rm -rf "$SCARCE_COPY_DIR" "$SCARCE_EXTRACT_DIR" "$SCARCE_QUEUE_DIR" "$SCARCE_LOG"

# ── test 19: phantom ledger GC (H1 regression) ────────────────────────────────
#
# The space ledger carries the worker BASHPID as a 6th field so phantoms —
# entries left behind by a SIGKILL'd worker that never ran its EXIT trap —
# can be detected and dropped. Without this, a waiting sibling would see a
# non-empty ledger, assume the phantom was making progress, and back off
# indefinitely while nothing ever released the space. This test plants a
# phantom directly into the ledger and exercises both code paths that
# consume the PID field: the destructive GC helper and the non-destructive
# space_ledger_empty liveness filter.

header "Test 19: phantom ledger GC (H1 regression)"

GC_QUEUE_DIR="/tmp/iso_pipeline_test_gc_$$"
mkdir -p "$GC_QUEUE_DIR"

while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < <(
    export QUEUE_DIR="$GC_QUEUE_DIR"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/space.sh"

    space_init

    # A PID well above any plausible kernel.pid_max default (32768). Using a
    # fixed absurdly-high number keeps the test deterministic.
    DEAD_PID=9999999
    LIVE_PID=$$

    ledger="$(_space_ledger_path)"

    # 1) Live entry only → space_ledger_empty returns false.
    printf 'extract.%s 2049 102400 2049 204800 %s\n' "$LIVE_PID" "$LIVE_PID" > "$ledger"
    if ! space_ledger_empty; then
        echo "PASS space_ledger_empty: live entry recognised"
    else
        echo "FAIL space_ledger_empty returned true but a live entry was present"
    fi

    # 2) Phantom entry only → space_ledger_empty treats ledger as empty.
    printf 'extract.%s 2049 104857600 2049 209715200 %s\n' "$DEAD_PID" "$DEAD_PID" > "$ledger"
    if space_ledger_empty; then
        echo "PASS space_ledger_empty: phantom-only ledger treated as empty"
    else
        echo "FAIL space_ledger_empty returned false on a phantom-only ledger"
    fi

    # 3) _space_ledger_gc_phantoms must physically drop the phantom line.
    _space_ledger_gc_phantoms
    if [[ ! -s "$ledger" ]]; then
        echo "PASS _space_ledger_gc_phantoms removed phantom entry from file"
    else
        echo "FAIL _space_ledger_gc_phantoms left a phantom in the ledger"
    fi

    # 4) Mixed phantom + live → GC keeps only the live line.
    printf 'extract.%s 2049 104857600 2049 209715200 %s\n' "$DEAD_PID" "$DEAD_PID" >  "$ledger"
    printf 'extract.%s 2049 102400 2049 204800 %s\n'       "$LIVE_PID" "$LIVE_PID" >> "$ledger"
    _space_ledger_gc_phantoms
    phantom_remaining=0
    live_remaining=0
    while read -r _ _ _ _ _ pid; do
        [[ "$pid" == "$DEAD_PID" ]] && phantom_remaining=1
        [[ "$pid" == "$LIVE_PID" ]] && live_remaining=1
    done < "$ledger"
    if (( phantom_remaining == 0 && live_remaining == 1 )); then
        echo "PASS GC preserved live entry and dropped phantom in mixed case"
    else
        echo "FAIL GC mixed-case result incorrect (phantom=$phantom_remaining live=$live_remaining)"
    fi

    # 5) End-to-end through space_reserve: a phantom holding "all" the space
    #    must be cleared so a small live reservation can fit.
    export SPACE_AVAIL_OVERRIDE_BYTES=2000000
    printf 'extract.%s 2049 1999999 2049 1999999 %s\n' "$DEAD_PID" "$DEAD_PID" > "$ledger"
    if space_reserve "extract.test19" "$GC_QUEUE_DIR" 100000 "$GC_QUEUE_DIR" 100000; then
        echo "PASS space_reserve succeeded after GCing phantom reservation"
    else
        echo "FAIL space_reserve failed even though only a phantom was holding capacity"
    fi
    space_release "extract.test19"
)

rm -rf "$GC_QUEUE_DIR"
