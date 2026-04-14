#!/usr/bin/env bash
# test/suites/06_worker_registry.sh
#
# Worker registry and intra-run orphan recovery: unit-tests the registry API
# directly, then exercises the full intra-run recovery loop by killing
# unzip_worker (not just extract.sh) so worker_job_end is never called.

# ── test 15: worker registry unit — orphan detection and recovery ─────────────
#
# Directly exercises the worker_registry.sh API without the full pipeline.
# Simulates a worker that registered a job (worker_job_begin) but was killed
# before it could unregister (worker_job_end never called). Verifies that
# worker_registry_recover returns the orphaned job and then clears the registry.

header "Test 15: worker registry — orphan detection"

REG_QUEUE_DIR="/tmp/iso_pipeline_test_registry_$$"
mkdir -p "$REG_QUEUE_DIR"

# Run the subshell via process substitution so the while-read loop runs in
# THIS shell. A plain `... | while ...` would put the loop in a subshell and
# every pass/fail call would increment counters that vanish when the pipe
# closes — silently zeroing out this test's contribution to the summary.
while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < <(
    export QUEUE_DIR="$REG_QUEUE_DIR"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/worker_registry.sh"

    worker_registry_init

    # Simulate a worker that registered a job but was never able to unregister.
    worker_job_begin "99999" "~$ROOT_DIR/test/fixtures/isos/game1.7z|sd|games/game1~"

    recovered=$(worker_registry_recover)
    expected="~$ROOT_DIR/test/fixtures/isos/game1.7z|sd|games/game1~"
    if [[ "$recovered" == "$expected" ]]; then
        echo "PASS orphaned job returned by worker_registry_recover"
    else
        echo "FAIL worker_registry_recover returned: '$recovered' (expected: '$expected')"
    fi

    # Second call must return nothing — registry was cleared by first recover.
    recovered2=$(worker_registry_recover)
    if [[ -z "$recovered2" ]]; then
        echo "PASS registry empty after recovery"
    else
        echo "FAIL registry not empty after recovery: '$recovered2'"
    fi

    # worker_job_end on an already-removed entry must be a no-op (not an error).
    worker_job_end "99999"
    echo "PASS worker_job_end on missing entry is a no-op"
)

rm -rf "$REG_QUEUE_DIR"

# ── test 18: intra-run orphan recovery via worker registry ───────────────────
#
# Unlike test 14 (which kills extract.sh so the EXIT trap is bypassed), this
# test kills unzip_worker — the bash subshell running the job loop — so that
# worker_job_end is never called and the job is left registered as an orphan.
#
# The 7z shim uses a trigger flag so it fires the kill exactly once: the first
# `x` invocation kills the grandparent (unzip_worker via `ps -o ppid=`), writes
# partial output, and exits non-zero. All subsequent `x` calls pass through to
# the real 7z, so the recovery pass can complete normally.
#
# With MAX_UNZIP=1 there is one unzip_worker. Killing it after it pops game1
# leaves game1 orphaned in the registry while game2/game3 are still queued.
# workers_start detects the orphan, re-queues game1, and runs a second pass
# that completes all three jobs. The pipeline must exit 0 (the recovery pass
# is clean, and H1 ensures a clean pass resets the rc).
#
# Key assertions:
#   - pipeline rc = 0 (intra-run recovery succeeded)
#   - "orphaned job(s) detected" appears in output (registry path exercised)
#   - all games extracted after the single run (no second pipeline invocation)
#   - spool clean on exit

header "Test 18: intra-run orphan recovery via worker registry"

# make_registry_kill_shim <dir> <trigger_flag>
# Creates a 7z shim that, on the FIRST `x` call, kills the grandparent process
# (unzip_worker) so worker_job_end is never reached, then exits non-zero. On
# all subsequent `x` calls it passes straight through to the real binary so
# the recovery pass can succeed.
make_registry_kill_shim() {
    local dir="$1" trigger_flag="$2"
    local real_7z
    real_7z="$(command -v 7z)"
    mkdir -p "$dir"
    cat > "$dir/7z" <<SHIM
#!/usr/bin/env bash
# On the FIRST 'x' call: write a partial file, kill the grandparent
# (unzip_worker) so worker_job_end never runs, then exit non-zero.
# On subsequent 'x' calls: pass straight through to the real binary.
REAL_7Z="$real_7z"
TRIGGER_FLAG="$trigger_flag"
if [[ "\${1:-}" == "x" ]]; then
    if [[ ! -f "\$TRIGGER_FLAG" ]]; then
        touch "\$TRIGGER_FLAG"
        out_dir=""
        for arg in "\$@"; do
            case "\$arg" in -o*) out_dir="\${arg#-o}" ;; esac
        done
        [[ -n "\$out_dir" ]] && mkdir -p "\$out_dir" && printf 'partial' > "\$out_dir/PARTIAL_FILE"
        # \$PPID = extract.sh; its parent = unzip_worker (what we want to kill)
        grandparent=\$(ps -o ppid= -p \$PPID 2>/dev/null | tr -d ' ')
        echo "[registry-kill-shim] killing unzip_worker (PID=\$grandparent)" >&2
        kill -9 "\$grandparent" 2>/dev/null || true
        # Brief pause — ensures SIGKILL is delivered before extract.sh can
        # return and trigger worker_job_end in the now-dead worker.
        sleep 0.2
        exit 1
    fi
    exec "\$REAL_7Z" "\$@"
fi
exec "\$REAL_7Z" "\$@"
SHIM
    chmod +x "$dir/7z"
}

REG_KILL_SHIM_DIR="/tmp/iso_pipeline_test_reg_kill_shim_$$"
REG_KILL_TRIGGER="/tmp/iso_pipeline_test_reg_kill_trigger_$$"
REG_KILL_COPY_DIR="/tmp/iso_pipeline_test_reg_kill_copy_$$"
REG_KILL_EXTRACT_DIR="/tmp/iso_pipeline_test_reg_kill_extract_$$"
REG_KILL_QUEUE_DIR="/tmp/iso_pipeline_test_reg_kill_queue_$$"
REG_KILL_LOG="/tmp/iso_pipeline_test_reg_kill_$$.log"

make_registry_kill_shim "$REG_KILL_SHIM_DIR" "$REG_KILL_TRIGGER"

clean_extracts
assert_clean_slate

echo "  cmd: PATH=$REG_KILL_SHIM_DIR:\$PATH MAX_UNZIP=1 ... bash bin/loadout-pipeline.sh test/example.jobs"
set +e
PATH="$REG_KILL_SHIM_DIR:$PATH" \
    MAX_UNZIP=1 \
    COPY_DIR="$REG_KILL_COPY_DIR" \
    EXTRACT_DIR="$REG_KILL_EXTRACT_DIR" \
    QUEUE_DIR="$REG_KILL_QUEUE_DIR" \
    bash "$PIPELINE" "$TEST_JOBS" >"$REG_KILL_LOG" 2>&1
reg_kill_rc=$?
set -e

# Recovery pass completes the orphaned job cleanly → expect rc=0.
if [[ $reg_kill_rc -eq 0 ]]; then
    pass "pipeline returned 0 — intra-run orphan recovery succeeded"
else
    fail "pipeline returned non-zero (rc=$reg_kill_rc) — recovery may not have run"
    sed 's/^/      /' "$REG_KILL_LOG"
fi

# The recovery log line confirms the registry code path was triggered.
if grep -q "orphaned job(s) detected" "$REG_KILL_LOG"; then
    pass "orphan detection log message present (worker registry path confirmed)"
else
    fail "expected 'orphaned job(s) detected' log line not found in output"
    sed 's/^/      /' "$REG_KILL_LOG"
fi

assert_all_extracted "$REG_KILL_EXTRACT_DIR"

# Spool must be fully cleaned at the end of the (single) run.
spool_scratch=$(find "$REG_KILL_COPY_DIR" -name '*.7z.*' 2>/dev/null | wc -l)
if [[ "$spool_scratch" -eq 0 ]]; then
    pass "spool clean after intra-run orphan recovery"
else
    fail "$spool_scratch scratch file(s) remain under $REG_KILL_COPY_DIR after recovery"
    find "$REG_KILL_COPY_DIR" -name '*.7z.*' | sed 's/^/      /'
fi

rm -rf "$REG_KILL_SHIM_DIR" "$REG_KILL_TRIGGER" "$REG_KILL_COPY_DIR" \
       "$REG_KILL_EXTRACT_DIR" "$REG_KILL_QUEUE_DIR" "$REG_KILL_LOG"
