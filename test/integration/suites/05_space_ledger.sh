#!/usr/bin/env bash
# test/integration/suites/05_space_ledger.sh
#
# Real filesystem scarcity + phantom GC. No SPACE_AVAIL_OVERRIDE_BYTES
# here — the scarcity is a real 6 MB tmpfs, and the ENOSPC (if any) is
# a real kernel signal.

# ─── Test 10: real scarce tmpfs, concurrent workers all complete ────────────
#
# $INT_SCARCE is 6 MB. Three small.7z archives (~512 KB each) easily fit
# if reservations serialize correctly, but the sum of their raw decoded
# sizes is close to the tmpfs capacity — so any regression that lets
# workers collectively overshoot the free-space number will surface as a
# real ENOSPC from the kernel rather than a test-hook rejection.

header "Int Test 10: three small archives on 6M tmpfs, real ledger"

T10_DIR="$INT_STATE/t10"
T10_COPY="$INT_SCARCE/copy"
T10_EXTRACT="$INT_SCARCE/extract"
T10_QUEUE="$INT_QUEUE/t10"
T10_LOG="$INT_STATE/t10.log"
T10_JOBS="$T10_DIR/t10.jobs"
rm -rf "$T10_DIR" "$T10_COPY" "$T10_EXTRACT" "$INT_SD_VFAT/t10"
mkdir -p "$T10_DIR" "$T10_COPY" "$T10_EXTRACT"

_int_make_jobs "$T10_JOBS" \
    "$INT_FIXTURES/small.7z|sd|t10/a" \
    "$INT_FIXTURES/small.7z|sd|t10/b" \
    "$INT_FIXTURES/small.7z|sd|t10/c"

set +e
MAX_UNZIP=3 \
COPY_DIR="$T10_COPY" \
EXTRACT_DIR="$T10_EXTRACT" \
QUEUE_DIR="$T10_QUEUE" \
SD_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T10_JOBS" >"$T10_LOG" 2>&1
t10_rc=$?
set -e

assert_rc "$t10_rc" 0 "Test 10 pipeline rc"
for sub in a b c; do
    assert_file_present "$INT_SD_VFAT/t10/$sub/small.iso" "Test 10 vfat $sub"
done

# Ledger must be drained on clean exit.
if [[ ! -s "$T10_QUEUE/.space_ledger" ]]; then
    pass "Test 10: ledger drained"
else
    fail "Test 10: ledger still populated"
    sed 's/^/      /' "$T10_QUEUE/.space_ledger"
fi

# ─── Test 11: real dead PID in the ledger → GC evicts phantom ──────────────

header "Int Test 11: real dead-PID phantom, GC evicts it"

T11_QUEUE="$INT_QUEUE/t11"
mkdir -p "$T11_QUEUE"

# Use a real dead PID (reaped child) so the kill -0 check returns a true
# "process does not exist", not just "you may not signal". This is a
# stronger test than picking a fixed high number.
dead_pid=$(inject_dead_pid)
live_pid=$$

while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < <(
    export QUEUE_DIR="$T11_QUEUE"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/logging.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/space.sh"
    space_init
    ledger="$(_space_ledger_path)"

    printf 'extract.%s 2049 102400 2049 204800 %s\n' "$live_pid" "$live_pid" > "$ledger"
    if ! space_ledger_empty; then
        echo "PASS live entry recognised on real substrate"
    else
        echo "FAIL space_ledger_empty returned true despite live entry"
    fi

    printf 'extract.%s 2049 1048576 2049 2097152 %s\n' "$dead_pid" "$dead_pid" > "$ledger"
    if space_ledger_empty; then
        echo "PASS phantom-only ledger treated as empty (real dead PID)"
    else
        echo "FAIL phantom-only ledger not treated as empty"
    fi

    _space_ledger_gc_phantoms
    if [[ ! -s "$ledger" ]]; then
        echo "PASS GC dropped phantom from ledger file"
    else
        echo "FAIL GC left phantom in ledger"
    fi

    # End-to-end: plant a phantom holding "all" capacity, then reserve a
    # tiny live entry. GC runs inside space_reserve's flock, so the
    # reservation must succeed.
    export SPACE_AVAIL_OVERRIDE_BYTES=2000000
    printf 'extract.%s 2049 1999999 2049 1999999 %s\n' "$dead_pid" "$dead_pid" > "$ledger"
    if space_reserve "extract.int11" "$T11_QUEUE" 100000 "$T11_QUEUE" 100000; then
        echo "PASS space_reserve succeeded after GCing phantom"
    else
        echo "FAIL space_reserve failed though only a phantom held capacity"
    fi
    space_release "extract.int11"
)

rm -rf "$T11_QUEUE"
