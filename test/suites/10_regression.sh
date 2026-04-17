#!/usr/bin/env bash
# test/suites/10_regression.sh
#
# Regression tests for specific bugs found in the NASA-style code review and
# fixed in the same pass. Each test is self-contained: it unit-tests a single
# library function or a specific input shape that used to trip the bug.
#
# Tests here must stay minimal — each one should pin ONE issue and survive as
# documentation of what "used to be broken" in case anyone later simplifies
# the fix and re-introduces the bug.

# ── test R1: jobs.sh rejects archive path that basenames to "." ──────────────
#
# Background (C1):
#   jobs.sh originally used a substring check `== *../* || == ../*` to reject
#   path traversal. That check missed the pathological input "/..7z" whose
#   basename after stripping ".7z" is "." — which extract.sh would then treat
#   as a legitimate (empty) stem and extract into $EXTRACT_DIR itself, clobber-
#   ing every sibling worker's output.
#
# Fix: jobs.sh:load_jobs now calls `basename "$archive" .7z` and rejects any
#      result that is empty or begins with a dot.
#
# Regression: we feed a job with archive path "/..7z" and expect load_jobs to
# exit non-zero. If someone ever simplifies the guard back to the substring
# check, this test fails loudly.

header "Test R1: jobs.sh rejects archive path that basenames to '.'"

R1_JOBS="/tmp/lp_regression_r1_$$.jobs"
R1_LOG="/tmp/lp_regression_r1_$$.log"

# "/..7z" is a real filesystem path (root dir + ..7z filename). basename with
# .7z suffix yields ".". The pipeline MUST refuse to load this job.
{ echo '---JOBS---'; echo '~/..7z|lvol|test/path~'; echo '---END---'; } > "$R1_JOBS"

R1_RC=0
bash "$PIPELINE" "$R1_JOBS" >"$R1_LOG" 2>&1 || R1_RC=$?

if (( R1_RC != 0 )); then
    pass "load_jobs rejected '/..7z' (exit $R1_RC)"
else
    fail "load_jobs accepted '/..7z' — path-traversal guard is broken"
    sed 's/^/      /' "$R1_LOG"
fi

if grep -qE 'invalid archive basename|basename' "$R1_LOG"; then
    pass "error message mentions invalid basename"
else
    fail "expected basename-related error message not found"
    sed 's/^/      /' "$R1_LOG"
fi

rm -f "$R1_JOBS" "$R1_LOG"

# ── test R2: _space_dev terminates on relative non-existent path ─────────────
#
# Background (C2):
#   `_space_dev` climbed the directory tree with `p="${p%/*}"` to find the
#   first existing ancestor. For a RELATIVE path like "foo" with no slash,
#   that shell parameter expansion returns the whole string unchanged —
#   creating an infinite loop.
#
# Fix: the climb now tracks the previous value and breaks out to "." when
#      the trimmed result equals the input.
#
# Regression: we invoke _space_dev with a bogus relative path in a subshell
# guarded by `timeout`. If the fix regresses, timeout terminates the subshell
# with exit 124 and the test fails.

header "Test R2: _space_dev terminates on bogus relative path"

R2_SCRIPT=$(cat <<'SCRIPT'
set -euo pipefail
ROOT_DIR="$1"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/space.sh"
# _space_dev is a private helper — access it directly. The relative path must
# be one that almost certainly does NOT exist anywhere we'd climb to.
_space_dev "lp_nonexistent_regression_path_$$"
SCRIPT
)

R2_RC=0
timeout 5 bash -c "$R2_SCRIPT" -- "$ROOT_DIR" >/dev/null 2>&1 || R2_RC=$?

if (( R2_RC == 0 )); then
    pass "_space_dev returned cleanly on relative non-existent path"
elif (( R2_RC == 124 )); then
    fail "_space_dev TIMED OUT — the infinite-loop bug has regressed"
else
    fail "_space_dev exited $R2_RC (expected 0)"
fi

# ── test R3: queue_pop returns 1 on empty queue (not 2) ──────────────────────
#
# Background (H1/H2):
#   queue_pop used `cat "$claimed" 2>/dev/null || return 1` which conflated
#   two very different outcomes: "queue is empty" and "claim file vanished
#   before cat could read it". The caller's while loop treated both as
#   end-of-queue and silently exited with jobs still pending.
#
# Fix: queue_pop now returns 1 for "empty" and 2 for "read error". Workers
#      treat 2 as a hard abort rather than a clean drain.
#
# Regression: we call queue_pop on a guaranteed-empty directory and verify
# the exit code is exactly 1. (Exercising the rc=2 branch deterministically
# requires race-condition injection, which is too fragile for a test.)

header "Test R3: queue_pop returns 1 on empty queue"

R3_QDIR="/tmp/lp_regression_r3_$$"
mkdir -p "$R3_QDIR"

R3_SCRIPT=$(cat <<'SCRIPT'
set -uo pipefail
ROOT_DIR="$1"
QDIR="$2"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/queue.sh"
queue_pop "$QDIR"
echo "RC=$?"
SCRIPT
)

R3_OUT=$(bash -c "$R3_SCRIPT" -- "$ROOT_DIR" "$R3_QDIR" 2>&1)

if grep -q '^RC=1$' <<< "$R3_OUT"; then
    pass "queue_pop returned 1 on empty queue"
else
    fail "queue_pop did not return 1 on empty queue — got: $R3_OUT"
fi

rm -rf "$R3_QDIR"

# ── test R4: worker_registry_recover preserves consecutive spaces ────────────
#
# Background (M3):
#   worker_registry_recover printed every entry's job string by assigning
#   `$1=""` in awk and then stripping the leading space. Assigning to $1
#   triggers field rebuild with OFS (default single space), which collapses
#   every run of whitespace inside the job — corrupting any path that
#   contained consecutive spaces.
#
# Fix: switched to an `index`-based split that keeps $0 byte-exact.
#
# Regression: we write a registry entry whose job contains two consecutive
# spaces and verify recover() emits it unchanged.

header "Test R4: worker_registry_recover preserves consecutive spaces"

R4_QDIR="/tmp/lp_regression_r4_$$"
mkdir -p "$R4_QDIR"

R4_SCRIPT=$(cat <<'SCRIPT'
set -euo pipefail
ROOT_DIR="$1"
QUEUE_DIR="$2"; export QUEUE_DIR
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/worker_registry.sh"
worker_registry_init
# Job contains two consecutive spaces inside the archive path. If the awk
# field-rebuild bug regresses, recover() will emit a single space.
printf '12345 extract ~/games/my  game.7z|lvol|games/g1~\n' > "$(_wr_path)"
worker_registry_recover
SCRIPT
)

R4_EXPECTED='~/games/my  game.7z|lvol|games/g1~'
R4_OUT=$(bash -c "$R4_SCRIPT" -- "$ROOT_DIR" "$R4_QDIR" 2>/dev/null)

if [[ "$R4_OUT" == "$R4_EXPECTED" ]]; then
    pass "worker_registry_recover preserved consecutive spaces"
else
    fail "worker_registry_recover corrupted the job string"
    echo "      expected: |$R4_EXPECTED|"
    echo "      got:      |$R4_OUT|"
fi

rm -rf "$R4_QDIR"
