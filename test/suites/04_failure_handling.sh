#!/usr/bin/env bash
# test/suites/04_failure_handling.sh
#
# Extract failure and SIGKILL recovery: verifies that the EXIT trap in
# extract.sh cleans up correctly on a normal rc=1 failure, that a re-run
# after failure succeeds, and that SIGKILL'd extracts leave no spool litter
# and that a subsequent run recovers the partial state.
#
# Shim factories are defined here because they are only needed by this suite.

# ── shim factories ────────────────────────────────────────────────────────────

# make_fail_shim <dir>
# Creates a 7z shim that passes `l`/`i` through to the real binary but fails
# `x` after writing a partial file — simulating a mid-extract error while
# keeping the EXIT trap active (SIGTERM-style failure, not SIGKILL).
make_fail_shim() {
    local dir="$1"
    local real_7z
    real_7z="$(command -v 7z)"
    mkdir -p "$dir"
    cat > "$dir/7z" <<SHIM
#!/usr/bin/env bash
# Test shim: pass \`l\` and \`i\` through; fail \`x\` after partial write.
REAL_7Z="$real_7z"
if [[ "\${1:-}" == "x" ]]; then
    out_dir=""
    for arg in "\$@"; do
        case "\$arg" in
            -o*) out_dir="\${arg#-o}" ;;
        esac
    done
    if [[ -n "\$out_dir" ]]; then
        mkdir -p "\$out_dir"
        printf 'partial' > "\$out_dir/PARTIAL_FILE"
    fi
    echo "[fail-shim] simulated mid-extract failure" >&2
    exit 1
fi
exec "\$REAL_7Z" "\$@"
SHIM
    chmod +x "$dir/7z"
}

# make_sigkill_shim <dir>
# Creates a 7z shim that, on `x`, writes partial output then sends SIGKILL to
# its parent (extract.sh), bypassing the EXIT trap entirely.
make_sigkill_shim() {
    local dir="$1"
    local real_7z
    real_7z="$(command -v 7z)"
    mkdir -p "$dir"
    cat > "$dir/7z" <<SHIM
#!/usr/bin/env bash
# Test shim: pass \`l\`/\`i\` through; on \`x\` write partial output then
# SIGKILL the parent (extract.sh), bypassing its EXIT trap entirely.
REAL_7Z="$real_7z"
if [[ "\${1:-}" == "x" ]]; then
    out_dir=""
    for arg in "\$@"; do
        case "\$arg" in -o*) out_dir="\${arg#-o}" ;; esac
    done
    if [[ -n "\$out_dir" ]]; then
        mkdir -p "\$out_dir"
        printf 'partial' > "\$out_dir/PARTIAL_FILE"
    fi
    echo "[sigkill-shim] sending SIGKILL to extract.sh (PPID=\$PPID)" >&2
    kill -9 \$PPID
    exit 1
fi
exec "\$REAL_7Z" "\$@"
SHIM
    chmod +x "$dir/7z"
}

# ── test 11: mid-extract failure leaves no scratch litter ───────────────────
#
# Shims `7z` on PATH with a wrapper that passes `l`/`i` through to the real
# binary (so precheck and size-listing still work) but fails `x` after writing
# a partial file to the output dir. The trap in lib/extract.sh must:
#   - release the space ledger reservation
#   - delete the scratch .7z.<pid> copy in COPY_DIR
#   - delete the partial $EXTRACT_DIR/<name>/ tree
# And the pipeline as a whole must return non-zero.

header "Test 11: mid-extract failure leaves no litter"

FAIL_SHIM_DIR="/tmp/iso_pipeline_test_shim_$$"
FAIL_COPY_DIR="/tmp/iso_pipeline_test_fail_copy_$$"
FAIL_EXTRACT_DIR="/tmp/iso_pipeline_test_fail_extract_$$"
FAIL_QUEUE_DIR="/tmp/iso_pipeline_test_fail_queue_$$"
FAIL_LOG="/tmp/iso_pipeline_test_fail_$$.log"

make_fail_shim "$FAIL_SHIM_DIR"
mkdir -p "$FAIL_COPY_DIR" "$FAIL_EXTRACT_DIR"

clean_extracts
assert_clean_slate

echo "  cmd: PATH=$FAIL_SHIM_DIR:\$PATH MAX_UNZIP=1 ... bash bin/loadout-pipeline.sh test/example.jobs"
set +e
PATH="$FAIL_SHIM_DIR:$PATH" \
    MAX_UNZIP=1 \
    COPY_DIR="$FAIL_COPY_DIR" \
    EXTRACT_DIR="$FAIL_EXTRACT_DIR" \
    QUEUE_DIR="$FAIL_QUEUE_DIR" \
    bash "$PIPELINE" "$TEST_JOBS" >"$FAIL_LOG" 2>&1
fail_rc=$?
set -e

if [[ $fail_rc -ne 0 ]]; then
    pass "pipeline returned non-zero on mid-extract failure (rc=$fail_rc)"
else
    fail "pipeline returned 0 despite injected extract failures"
    sed 's/^/      /' "$FAIL_LOG"
fi

scratch_leftovers=$(find "$FAIL_COPY_DIR" -name '*.7z.*' 2>/dev/null | wc -l)
if [[ "$scratch_leftovers" -eq 0 ]]; then
    pass "no scratch .7z.<pid> copies leaked under $FAIL_COPY_DIR"
else
    fail "$scratch_leftovers scratch file(s) leaked under $FAIL_COPY_DIR"
    find "$FAIL_COPY_DIR" -name '*.7z.*' | sed 's/^/      /'
fi

partial_dirs=$(find "$FAIL_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
if [[ "$partial_dirs" -eq 0 ]]; then
    pass "no partial extract dirs left under $FAIL_EXTRACT_DIR"
else
    fail "$partial_dirs partial extract dir(s) remain under $FAIL_EXTRACT_DIR"
    find "$FAIL_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | sed 's/^/      /'
fi

# Ledger must be drained — the release trap ran even though extract failed.
if [[ ! -s "$FAIL_QUEUE_DIR/.space_ledger" ]]; then
    pass "space ledger fully released after failures"
else
    fail "space ledger still has entries after failures:"
    sed 's/^/      /' "$FAIL_QUEUE_DIR/.space_ledger"
fi

rm -rf "$FAIL_SHIM_DIR" "$FAIL_COPY_DIR" "$FAIL_EXTRACT_DIR" "$FAIL_QUEUE_DIR" "$FAIL_LOG"

# ── test 12: rerun after a failed run succeeds from scratch ─────────────────
#
# The failure-recovery contract we actually want to guarantee: a partial run
# leaves the system in a state where simply re-running the pipeline succeeds.
# This is a stronger and simpler contract than mid-run auto-retry.

header "Test 12: rerun after failed run succeeds"

FAIL_SHIM_DIR="/tmp/iso_pipeline_test_shim2_$$"
FAIL_COPY_DIR="/tmp/iso_pipeline_test_fail2_copy_$$"
FAIL_EXTRACT_DIR="/tmp/iso_pipeline_test_fail2_extract_$$"
FAIL_QUEUE_DIR="/tmp/iso_pipeline_test_fail2_queue_$$"

make_fail_shim "$FAIL_SHIM_DIR"

clean_extracts
assert_clean_slate

echo "  run 1 (injected failure): PATH=$FAIL_SHIM_DIR:\$PATH ..."
set +e
PATH="$FAIL_SHIM_DIR:$PATH" \
    MAX_UNZIP=2 \
    COPY_DIR="$FAIL_COPY_DIR" \
    EXTRACT_DIR="$FAIL_EXTRACT_DIR" \
    QUEUE_DIR="$FAIL_QUEUE_DIR" \
    bash "$PIPELINE" "$TEST_JOBS" >/dev/null 2>&1
set -e

echo "  run 2 (real 7z, same dirs): bash bin/loadout-pipeline.sh test/example.jobs"
MAX_UNZIP=2 \
    COPY_DIR="$FAIL_COPY_DIR" \
    EXTRACT_DIR="$FAIL_EXTRACT_DIR" \
    QUEUE_DIR="$FAIL_QUEUE_DIR" \
    bash "$PIPELINE" "$TEST_JOBS"

assert_all_extracted "$FAIL_EXTRACT_DIR"

# Rerun must also leave no leftover scratch copies anywhere under COPY_DIR.
scratch_leftovers=$(find "$FAIL_COPY_DIR" -name '*.7z.*' 2>/dev/null | wc -l)
if [[ "$scratch_leftovers" -eq 0 ]]; then
    pass "rerun left no scratch files under $FAIL_COPY_DIR"
else
    fail "rerun leaked $scratch_leftovers scratch file(s) under $FAIL_COPY_DIR"
fi

rm -rf "$FAIL_SHIM_DIR" "$FAIL_COPY_DIR" "$FAIL_EXTRACT_DIR" "$FAIL_QUEUE_DIR"

# ── test 14: SIGKILL'd extract — no spool litter, re-run succeeds ────────────
#
# Unlike test 11 (clean rc=1 failure where the EXIT trap fires), this test
# simulates a SIGKILL on the extract.sh bash process — the trap is bypassed.
# The shim writes a PARTIAL_FILE to the output dir then kills its own parent
# (extract.sh) with SIGKILL. Since workers_start rm -rf's COPY_SPOOL at the
# end of every run, scratch copies in the spool are still cleaned. But the
# partial EXTRACT_DIR is NOT cleaned (that was the trap's job), so it persists.
#
# Re-run with real 7z: workers_start orphan-sweeps any dead spool dirs,
# 7z x -aoa overwrites the partial extract, and all games complete.

header "Test 14: SIGKILL'd extract — spool cleaned, re-run recovers"

KILL_SHIM_DIR="/tmp/iso_pipeline_test_kill_shim_$$"
KILL_COPY_DIR="/tmp/iso_pipeline_test_kill_copy_$$"
KILL_EXTRACT_DIR="/tmp/iso_pipeline_test_kill_extract_$$"
KILL_QUEUE_DIR="/tmp/iso_pipeline_test_kill_queue_$$"
KILL_LOG="/tmp/iso_pipeline_test_kill_$$.log"

make_sigkill_shim "$KILL_SHIM_DIR"

clean_extracts
assert_clean_slate

echo "  run 1 (SIGKILL shim): PATH=$KILL_SHIM_DIR:\$PATH MAX_UNZIP=1 ..."
set +e
PATH="$KILL_SHIM_DIR:$PATH" \
    MAX_UNZIP=1 \
    COPY_DIR="$KILL_COPY_DIR" \
    EXTRACT_DIR="$KILL_EXTRACT_DIR" \
    QUEUE_DIR="$KILL_QUEUE_DIR" \
    bash "$PIPELINE" "$TEST_JOBS" >"$KILL_LOG" 2>&1
kill_rc=$?
set -e

if [[ $kill_rc -ne 0 ]]; then
    pass "pipeline returned non-zero after SIGKILL'd extracts (rc=$kill_rc)"
else
    fail "pipeline returned 0 despite SIGKILL'd extract processes"
    sed 's/^/      /' "$KILL_LOG"
fi

# Scratch copies live in COPY_SPOOL ($KILL_COPY_DIR/<pipeline_pid>/). Even
# though the trap never fired, workers_start rm -rf'd the spool at the end.
spool_scratch=$(find "$KILL_COPY_DIR" -name '*.7z.*' 2>/dev/null | wc -l)
if [[ "$spool_scratch" -eq 0 ]]; then
    pass "spool scratch copies cleaned by workers_start on exit"
else
    fail "$spool_scratch scratch file(s) remain under $KILL_COPY_DIR after SIGKILL run"
    find "$KILL_COPY_DIR" -name '*.7z.*' | sed 's/^/      /'
fi

# Partial extract dirs ARE present — the trap didn't fire so EXTRACT_DIR was
# not cleaned. This is expected and is exactly what the re-run must handle.
partial_files=$(find "$KILL_EXTRACT_DIR" -name 'PARTIAL_FILE' 2>/dev/null | wc -l)
if [[ "$partial_files" -gt 0 ]]; then
    pass "partial EXTRACT_DIR content present after SIGKILL (trap bypass confirmed)"
else
    fail "expected partial content in $KILL_EXTRACT_DIR after SIGKILL but found none"
fi

echo "  run 2 (real 7z, same dirs): bash bin/loadout-pipeline.sh test/example.jobs"
MAX_UNZIP=1 \
    COPY_DIR="$KILL_COPY_DIR" \
    EXTRACT_DIR="$KILL_EXTRACT_DIR" \
    QUEUE_DIR="$KILL_QUEUE_DIR" \
    bash "$PIPELINE" "$TEST_JOBS"

assert_all_extracted "$KILL_EXTRACT_DIR"

# No spool subdirs or scratch copies should remain after the clean re-run.
spool_scratch=$(find "$KILL_COPY_DIR" -name '*.7z.*' 2>/dev/null | wc -l)
if [[ "$spool_scratch" -eq 0 ]]; then
    pass "rerun left no scratch files under $KILL_COPY_DIR"
else
    fail "rerun leaked $spool_scratch scratch file(s) under $KILL_COPY_DIR"
fi

rm -rf "$KILL_SHIM_DIR" "$KILL_COPY_DIR" "$KILL_EXTRACT_DIR" "$KILL_QUEUE_DIR" "$KILL_LOG"
