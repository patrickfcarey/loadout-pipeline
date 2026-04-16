#!/usr/bin/env bash
# test/suites/19_unit_concurrency.sh
#
# Unit tests for concurrent queue / worker-registry races plus precheck.sh
# error paths. Suite 15 R4 covered the serial queue round-trip; this suite
# hammers the atomic-claim path under contention so a regression in the
# mv-based claim or the flock-guarded registry rewrite is localised to a
# specific helper rather than showing up as a flaky end-to-end test.
#
#   Q1  queue_pop race: two concurrent pops on a single-job queue
#   Q2  queue_pop rc=2 path: mv succeeds, cat fails, rm -f succeeds
#   Q3  queue_pop FIFO + no-loss under N concurrent poppers
#   R7  Two concurrent worker_job_begin for the same pid → one surviving row
#   PR1 precheck.sh on an archive with no Path entries → exit 2
#   PR2 precheck.sh with an unknown adapter → exit 2
#
# set -e trap: process-substitution subshells inherit `set -e` from
# run_tests.sh, so every body must avoid expressions that return exit 1
# under normal flow. Banned idioms inside `_u_run_subshell < <(...)`:
#   * `(( x++ ))` post-increment when x starts at 0 — use `x=$((x+1))`
#   * `wait` without `|| :` — any non-zero child aborts the subshell
#   * `cmd || rc=$?` without guarding a fallthrough path
# Background subshells spawned with `(...) &` inherit set -e too; use
# `set +e` inside them when the body intentionally runs commands allowed
# to fail (e.g. `queue_pop` returning 1 at end-of-queue).

_u_run_subshell() {
    while IFS= read -r line; do
        case "$line" in
            PASS*) pass "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
        esac
    done
}

# =============================================================================
# Q1 — two concurrent queue_pop on a single-job queue: exactly one winner
# =============================================================================

header "Test Q1: concurrent queue_pop race on single-job queue"

Q1_QDIR="/tmp/lp_unit_q1_$$"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/queue.sh"

    queue_init "$Q1_QDIR"
    queue_push "$Q1_QDIR" "~/only/one.7z|lvol|dest~"

    r1="$Q1_QDIR/r1.out"
    r2="$Q1_QDIR/r2.out"
    c1="$Q1_QDIR/r1.rc"
    c2="$Q1_QDIR/r2.rc"

    (
        set +e
        queue_pop "$Q1_QDIR" >"$r1" 2>/dev/null
        echo $? >"$c1"
    ) &
    (
        set +e
        queue_pop "$Q1_QDIR" >"$r2" 2>/dev/null
        echo $? >"$c2"
    ) &
    wait || :

    rc1=$(cat "$c1" 2>/dev/null || echo miss)
    rc2=$(cat "$c2" 2>/dev/null || echo miss)
    out1=$(cat "$r1" 2>/dev/null || echo "")
    out2=$(cat "$r2" 2>/dev/null || echo "")

    winners=0
    empties=0
    [[ "$rc1" == "0" && "$out1" == "~/only/one.7z|lvol|dest~" ]] && winners=$((winners + 1))
    [[ "$rc2" == "0" && "$out2" == "~/only/one.7z|lvol|dest~" ]] && winners=$((winners + 1))
    [[ "$rc1" == "1" && -z "$out1" ]] && empties=$((empties + 1))
    [[ "$rc2" == "1" && -z "$out2" ]] && empties=$((empties + 1))

    if (( winners == 1 )); then
        echo "PASS exactly one popper claimed the job"
    else
        echo "FAIL winners=$winners (rc1=$rc1 out1=$out1 rc2=$rc2 out2=$out2)"
    fi
    if (( empties == 1 )); then
        echo "PASS the other popper reported rc=1 (empty)"
    else
        echo "FAIL empties=$empties (rc1=$rc1 out1=$out1 rc2=$rc2 out2=$out2)"
    fi

    leftover=$(find "$Q1_QDIR" -maxdepth 1 -name "*.job" | wc -l)
    if (( leftover == 0 )); then
        echo "PASS queue drained after race (no .job files left)"
    else
        echo "FAIL $leftover .job files remain after race"
    fi
)

rm -rf "$Q1_QDIR"

# =============================================================================
# Q2 — queue_pop rc=2 when the claim succeeds but the read fails
# =============================================================================
#
# The rc=2 branch exists so a corrupted claim does not get silently
# collapsed into "queue empty" (rc=1), which would cause a worker to
# exit with jobs still pending. We synthesize the failure with a
# mode-000 file: `mv` only needs parent-dir write bits, `cat` needs
# the file's own read bit, and `rm -f` also needs only parent-dir bits.
#
# Running as root bypasses DAC on file reads, so `cat` would succeed
# and the rc=2 branch would not fire. Skip the test under root so
# CI-as-root environments do not record a spurious failure.

header "Test Q2: queue_pop returns rc=2 when claim file is unreadable"

Q2_QDIR="/tmp/lp_unit_q2_$$"

if (( EUID == 0 )); then
    pass "Q2 skipped — running as root, chmod 000 is bypassed"
    pass "Q2 skipped — running as root, chmod 000 is bypassed (2)"
else
    _u_run_subshell < <(
        source "$ROOT_DIR/lib/logging.sh"
        source "$ROOT_DIR/lib/queue.sh"

        queue_init "$Q2_QDIR"
        echo "content-the-cat-cannot-see" > "$Q2_QDIR/fake.job"
        chmod 000 "$Q2_QDIR/fake.job"

        set +e
        out=$(queue_pop "$Q2_QDIR" 2>/dev/null)
        rc=$?
        set -e

        if (( rc == 2 )); then
            echo "PASS queue_pop returned rc=2 on unreadable claim"
        else
            echo "FAIL expected rc=2, got $rc (out=$out)"
        fi
        if [[ -z "$out" ]]; then
            echo "PASS queue_pop printed nothing on the rc=2 path"
        else
            echo "FAIL queue_pop printed content on rc=2 path: $out"
        fi
    )
fi

# Restore dir perms so the outer cleanup can rm any lingering 000 files.
chmod -R u+rwx "$Q2_QDIR" 2>/dev/null || true
rm -rf "$Q2_QDIR"

# =============================================================================
# Q3 — FIFO + no-loss under two concurrent poppers
# =============================================================================
#
# Per-popper strict FIFO isn't guaranteed under contention — a popper can
# lose the mv race on an earlier candidate and end up with a later one
# first. What MUST hold is the set identity: every pushed job is delivered
# exactly once across all poppers, with no duplicates and nothing lost.

header "Test Q3: concurrent poppers deliver every job exactly once"

Q3_QDIR="/tmp/lp_unit_q3_$$"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/queue.sh"

    queue_init "$Q3_QDIR"

    # Seed 20 jobs, padded so sort order is predictable in the diff.
    for i in $(seq -w 1 20); do
        queue_push "$Q3_QDIR" "~/j/g$i.7z|lvol|d$i~"
    done

    r1="$Q3_QDIR/r1.log"
    r2="$Q3_QDIR/r2.log"
    : > "$r1"
    : > "$r2"

    (
        set +e
        while j=$(queue_pop "$Q3_QDIR" 2>/dev/null); do
            printf '%s\n' "$j" >> "$r1"
        done
    ) &
    (
        set +e
        while j=$(queue_pop "$Q3_QDIR" 2>/dev/null); do
            printf '%s\n' "$j" >> "$r2"
        done
    ) &
    wait || :

    total=$(cat "$r1" "$r2" | wc -l)
    uniq_count=$(cat "$r1" "$r2" | sort -u | wc -l)
    if (( total == 20 )); then
        echo "PASS all 20 jobs were popped in total"
    else
        echo "FAIL total popped=$total (expected 20)"
    fi
    if (( uniq_count == 20 )); then
        echo "PASS every job delivered exactly once (no duplicates)"
    else
        echo "FAIL unique count=$uniq_count (expected 20 — duplicates mean lost race)"
    fi

    leftover=$(find "$Q3_QDIR" -maxdepth 1 -name "*.job" | wc -l)
    if (( leftover == 0 )); then
        echo "PASS queue drained"
    else
        echo "FAIL $leftover .job files remain"
    fi
)

rm -rf "$Q3_QDIR"

# =============================================================================
# R7 — concurrent worker_job_begin for same pid: exactly one row survives
# =============================================================================
#
# worker_job_begin uses flock + awk rewrite to both remove any existing
# row for the given pid AND append the new one atomically. Under N=8
# concurrent calls with the same pid, we must end up with exactly one row
# (whichever call acquired the lock last wins), and the recovered job
# string must be a valid one from the set we wrote.

header "Test R7: concurrent worker_job_begin for same pid"

R7_QDIR="/tmp/lp_unit_r7_$$"

_u_run_subshell < <(
    export QUEUE_DIR="$R7_QDIR"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/worker_registry.sh"

    worker_registry_init
    reg="$(_wr_path)"

    for i in 1 2 3 4 5 6 7 8; do
        worker_job_begin 55555 "~/j/g${i}.7z|lvol|d${i}~" &
    done
    wait || :

    count=$(grep -c "^55555 " "$reg" 2>/dev/null)
    count="${count:-0}"
    if [[ "$count" == "1" ]]; then
        echo "PASS exactly one row for pid after 8 concurrent begins"
    else
        echo "FAIL $count rows for pid after concurrent begins"
    fi

    out=$(worker_registry_recover)
    if [[ "$out" =~ ^~/j/g[1-8]\.7z\|lvol\|d[1-8]~$ ]]; then
        echo "PASS recover returns a valid job from the concurrent set"
    else
        echo "FAIL recover returned: $out"
    fi

    # After recover, registry should be emptied.
    if ! grep -q "^55555 " "$reg" 2>/dev/null; then
        echo "PASS recover removed the pid row"
    else
        echo "FAIL pid row still present after recover"
    fi
)

rm -rf "$R7_QDIR"

# =============================================================================
# PR1 — precheck.sh on an archive with no Path entries → exit 2
# =============================================================================
#
# A text file pretending to be a .7z makes `7z l -slt` emit an error
# instead of Path lines. `contained` ends up empty, and precheck.sh's
# `[[ -z "$contained" ]]` branch exits 2 with the "empty or unreadable"
# message. No LVOL_MOUNT_POINT needed because the case statement is never
# reached on this path.

header "Test PR1: precheck.sh rejects archive with no Path entries"

PR1_ARCHIVE="/tmp/lp_unit_pr1_$$.7z"
printf 'not a real 7z archive\n' > "$PR1_ARCHIVE"

PR1_RC=0
PR1_LOG=$(mktemp)
bash "$ROOT_DIR/lib/precheck.sh" sd "$PR1_ARCHIVE" "games/x" \
    >"$PR1_LOG" 2>&1 || PR1_RC=$?

if (( PR1_RC == 2 )); then
    pass "precheck on empty/unreadable archive exit 2"
else
    fail "expected rc=2, got $PR1_RC"
    sed 's/^/      /' "$PR1_LOG"
fi
if grep -q "empty or unreadable" "$PR1_LOG"; then
    pass "precheck logs 'empty or unreadable'"
else
    fail "expected 'empty or unreadable' in log"
    sed 's/^/      /' "$PR1_LOG"
fi

rm -f "$PR1_ARCHIVE" "$PR1_LOG"

# =============================================================================
# PR2 — precheck.sh with an unknown adapter → exit 2
# =============================================================================
#
# Use a real fixture archive so `contained` is non-empty and we reach the
# case statement. The adapter `zzz` is not known, so precheck.sh hits the
# `*)` branch with log_warn + exit 2.

header "Test PR2: precheck.sh rejects unknown adapter"

PR2_RC=0
PR2_LOG=$(mktemp)
bash "$ROOT_DIR/lib/precheck.sh" zzz \
    "$FIXTURES_DIR/isos/game1.7z" "games/x" \
    >"$PR2_LOG" 2>&1 || PR2_RC=$?

if (( PR2_RC == 2 )); then
    pass "precheck on unknown adapter exit 2"
else
    fail "expected rc=2, got $PR2_RC"
    sed 's/^/      /' "$PR2_LOG"
fi
if grep -q "unknown adapter" "$PR2_LOG"; then
    pass "precheck logs 'unknown adapter'"
else
    fail "expected 'unknown adapter' in log"
    sed 's/^/      /' "$PR2_LOG"
fi

rm -f "$PR2_LOG"
