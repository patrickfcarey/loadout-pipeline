#!/usr/bin/env bash
# test/integration/suites/10_regression.sh
#
# Regression pins for specific bugs found in the NASA-style code review.
# Most regressions have no meaningful "real environment" dimension — the
# unit-suite tests under test/suites/10_regression.sh already exercise
# them deterministically. The ones listed here are the subset that do
# benefit from a real substrate, per the plan's scenario mapping table.

# ── R3: queue_pop rc=1 on empty ────────────────────────────────────────────

header "Int Test R3: queue_pop rc=0 on populated, rc=1 on empty (real substrate)"

R3_QDIR="$INT_QUEUE/r3"
rm -rf "$R3_QDIR"
mkdir -p "$R3_QDIR"

R3_OUT=$(
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/logging.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/queue.sh"
    set +e
    queue_pop "$R3_QDIR" >/dev/null; echo "empty_rc=$?"
    queue_push "$R3_QDIR" "~$INT_FIXTURES/small.7z|lvol|r3/pop~"
    content=$(queue_pop "$R3_QDIR"); echo "pop_rc=$?"
    echo "pop_content=$content"
)

if grep -q '^empty_rc=1$' <<< "$R3_OUT"; then
    pass "R3: queue_pop rc=1 on empty dir"
else
    fail "R3: queue_pop empty rc wrong: $R3_OUT"
fi

if grep -q '^pop_rc=0$' <<< "$R3_OUT" \
   && grep -q "pop_content=~$INT_FIXTURES/small.7z|lvol|r3/pop~" <<< "$R3_OUT"; then
    pass "R3: queue_pop returned pushed content byte-exact"
else
    fail "R3: queue_pop content mismatch: $R3_OUT"
fi

rm -rf "$R3_QDIR"

# ── R4: worker_registry_recover preserves consecutive spaces ───────────────
#
# Covered directly by Int Test 13 in suite 06. This block is a thin
# no-op wrapper so the regression suite listing in test output matches
# the unit-suite numbering.
header "Int Test R4: registry double-space preservation (covered by Test 13)"
pass "R4 covered by int worker registry suite (Test 13)"
