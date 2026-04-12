#!/usr/bin/env bash
# End-to-end test runner for loadout-pipeline.
# Usage: bash test/run_tests.sh
# All tests run against test/example.jobs using generated fixture archives.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$ROOT_DIR/test/fixtures"
PIPELINE="$ROOT_DIR/bin/loadout-pipeline.sh"
TEST_JOBS="$ROOT_DIR/test/example.jobs"
EXTRACT_BASE="/tmp/iso_pipeline"

PASS=0
FAIL=0

# ── output helpers ────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${RESET} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${RESET} $*"; FAIL=$((FAIL+1)); }
header() { echo -e "\n${BOLD}=== $* ===${RESET}"; }

# ── assertion helpers ─────────────────────────────────────────────────────────

# Assert a directory exists and contains the expected fixture files.
assert_extracted() {
    local game="$1"
    local dir="$EXTRACT_BASE/$game"
    if [[ -f "$dir/SYSTEM.CNF" && -f "$dir/dummy_data.bin" ]]; then
        pass "$game extracted → $dir"
    else
        fail "$game missing from $dir (SYSTEM.CNF or dummy_data.bin not found)"
    fi
}

# Assert a directory does NOT exist (used to confirm clean state before a test).
assert_not_extracted() {
    local game="$1"
    if [[ ! -d "$EXTRACT_BASE/$game" ]]; then
        pass "clean slate confirmed for $game"
    else
        fail "$EXTRACT_BASE/$game still exists from a prior run — clean up manually"
    fi
}

# Assert a queue directory is empty (no leftover .job or .claimed.* files).
assert_queue_empty() {
    local qdir="$1"
    local leftovers
    leftovers=$(find "$qdir" -maxdepth 1 \( -name "*.job" -o -name "*.claimed.*" \) 2>/dev/null | wc -l)
    if [[ "$leftovers" -eq 0 ]]; then
        pass "queue $qdir is empty after run"
    else
        fail "queue $qdir has $leftovers leftover file(s) after run"
    fi
}

clean_extracts() {
    rm -rf "$EXTRACT_BASE/game1" "$EXTRACT_BASE/game2" "$EXTRACT_BASE/game3"
}

# ── prerequisites ─────────────────────────────────────────────────────────────

header "Prerequisites"

if ! command -v 7z &>/dev/null; then
    echo "[ERROR] 7z not found. Install p7zip-full and retry."
    exit 1
fi
pass "7z is available ($(7z i 2>/dev/null | head -1))"

if [[ ! -f "$TEST_JOBS" ]]; then
    fail "test jobs file not found: $TEST_JOBS"
    exit 1
fi
pass "test jobs file found: $TEST_JOBS"

# ── setup: generate fixture archives ─────────────────────────────────────────

header "Setup: generating fixture archives"
bash "$FIXTURES_DIR/create_fixtures.sh"

for game in game1 game2 game3; do
    if [[ -f "$FIXTURES_DIR/isos/${game}.iso" ]]; then
        pass "fixture archive ready: ${game}.iso"
    else
        fail "fixture archive missing: ${game}.iso — create_fixtures.sh may have failed"
    fi
done

# ── test 1: default run ───────────────────────────────────────────────────────
#
# Runs with all defaults: MAX_UNZIP=2, default QUEUE_DIR.

header "Test 1: default run"
echo "  cmd: bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
bash "$PIPELINE" "$TEST_JOBS"
assert_extracted game1
assert_extracted game2
assert_extracted game3

# ── test 2: single unzip worker ───────────────────────────────────────────────
#
# Forces serial extraction (MAX_UNZIP=1). Validates that the queue drains
# correctly and no jobs are skipped when only one worker is running.

header "Test 2: serial extraction (MAX_UNZIP=1)"
echo "  cmd: MAX_UNZIP=1 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
MAX_UNZIP=1 bash "$PIPELINE" "$TEST_JOBS"
assert_extracted game1
assert_extracted game2
assert_extracted game3

# ── test 3: more workers than jobs ────────────────────────────────────────────
#
# Runs with more workers than there are jobs (5 workers, 3 jobs).
# Verifies that idle workers exit cleanly without deadlocking or double-processing.

header "Test 3: more workers than jobs (MAX_UNZIP=5, 3 jobs)"
echo "  cmd: MAX_UNZIP=5 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
MAX_UNZIP=5 bash "$PIPELINE" "$TEST_JOBS"
assert_extracted game1
assert_extracted game2
assert_extracted game3

# ── test 4: custom QUEUE_DIR ──────────────────────────────────────────────────
#
# Overrides QUEUE_DIR so this run's queue is isolated from the default location.
# After the run the custom queue dir should exist but be completely empty.

header "Test 4: custom QUEUE_DIR override"
CUSTOM_QUEUE="/tmp/iso_pipeline_test_queue_$$"
echo "  cmd: QUEUE_DIR=$CUSTOM_QUEUE MAX_UNZIP=2 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
QUEUE_DIR="$CUSTOM_QUEUE" MAX_UNZIP=2 bash "$PIPELINE" "$TEST_JOBS"
assert_extracted game1
assert_extracted game2
assert_extracted game3
assert_queue_empty "$CUSTOM_QUEUE"
rm -rf "$CUSTOM_QUEUE"

# ── test 5: idempotent re-run (no clean between runs) ─────────────────────────
#
# Runs the pipeline twice back-to-back without clearing /tmp/iso_pipeline.
# Verifies that init_environment and queue_init don't fail or corrupt state
# when the output directories already exist.

header "Test 5: idempotent re-run (extracted dirs already exist)"
echo "  cmd (run 1): bash bin/loadout-pipeline.sh test/example.jobs"
bash "$PIPELINE" "$TEST_JOBS"
echo "  cmd (run 2): bash bin/loadout-pipeline.sh test/example.jobs"
bash "$PIPELINE" "$TEST_JOBS"
assert_extracted game1
assert_extracted game2
assert_extracted game3

# ── summary ───────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Results: ${GREEN}$PASS passed${RESET}${BOLD}, ${RED}$FAIL failed${RESET}"
[[ $FAIL -eq 0 ]]
