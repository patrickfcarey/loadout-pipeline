#!/usr/bin/env bash
# test/suites/01_prerequisites.sh
#
# Checks that the tools and fixture files required by the rest of the suite
# are present. If 7z is missing or any fixture archive cannot be generated,
# the suite exits immediately — there is no point running extract tests
# without a working extractor or valid input archives.

# ── tool availability ─────────────────────────────────────────────────────────

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

# ── fixture archive generation ────────────────────────────────────────────────

header "Setup: generating fixture archives"
bash "$FIXTURES_DIR/create_fixtures.sh"

while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    iso=$(job_line_archive "$line")
    if [[ -f "$iso" ]]; then
        pass "fixture archive ready: $iso"
    else
        fail "fixture archive missing: $iso — create_fixtures.sh may have failed"
    fi
done < "$TEST_JOBS"
