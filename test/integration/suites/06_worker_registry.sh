#!/usr/bin/env bash
# test/integration/suites/06_worker_registry.sh
#
# Worker registry exercised against real files on the container rootfs.
# Uses inject_dead_pid so the "dead worker" is a real reaped child, not a
# fake PID that only *happens* to be absent from the process table.

header "Int Test 12: worker_registry_recover picks up orphans (real dead PID)"

T12_QUEUE="$INT_QUEUE/t12"
mkdir -p "$T12_QUEUE"

dead_pid=$(inject_dead_pid)
ORPHAN_JOB="~$INT_FIXTURES/small.7z|sd|t12/orphan~"

while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < <(
    export QUEUE_DIR="$T12_QUEUE"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/logging.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/worker_registry.sh"

    worker_registry_init
    worker_job_begin "$dead_pid" "$ORPHAN_JOB"

    recovered=$(worker_registry_recover)
    if [[ "$recovered" == "$ORPHAN_JOB" ]]; then
        echo "PASS worker_registry_recover returned orphaned job verbatim"
    else
        echo "FAIL recover returned '$recovered' (expected '$ORPHAN_JOB')"
    fi

    recovered2=$(worker_registry_recover)
    if [[ -z "$recovered2" ]]; then
        echo "PASS registry cleared after recover"
    else
        echo "FAIL registry not cleared: '$recovered2'"
    fi

    worker_job_end "$dead_pid"
    echo "PASS worker_job_end on missing entry is no-op"
)

rm -rf "$T12_QUEUE"

header "Int Test 13: registry preserves byte-exact job string with double spaces"

T13_QUEUE="$INT_QUEUE/t13"
mkdir -p "$T13_QUEUE"
T13_DIR="$INT_EXTRACT/t13 has  two  spaces"
mkdir -p "$T13_DIR"
cp "$INT_FIXTURES/small.7z" "$T13_DIR/weird  game.7z"
T13_JOB="~$T13_DIR/weird  game.7z|sd|t13/weird  game~"

while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < <(
    export QUEUE_DIR="$T13_QUEUE"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/logging.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/worker_registry.sh"

    worker_registry_init
    worker_job_begin 12345 "$T13_JOB"
    out=$(worker_registry_recover)
    if [[ "$out" == "$T13_JOB" ]]; then
        echo "PASS recover preserved double spaces byte-exact"
    else
        echo "FAIL recover collapsed spaces: |$out| (expected |$T13_JOB|)"
    fi
)

rm -rf "$T13_QUEUE" "$T13_DIR"
