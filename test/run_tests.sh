#!/usr/bin/env bash
# End-to-end test runner for loadout-pipeline.
# Usage: bash test/run_tests.sh
# All tests run against test/example.jobs using generated fixture archives.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$ROOT_DIR/test/fixtures"
PIPELINE="$ROOT_DIR/bin/loadout-pipeline.sh"
TEST_JOBS="$ROOT_DIR/test/example.jobs"
EXTRACT_BASE="${EXTRACT_DIR:-/tmp/iso_pipeline}"

# Default SD destination for tests that don't set their own SD_MOUNT_POINT.
# Using a temp dir so the suite works on any machine without an actual SD card.
# Exported so all pipeline subprocesses pick it up automatically; tests that
# need isolation pass SD_MOUNT_POINT=<custom> inline to override it.
TEST_SD_DIR="/tmp/iso_pipeline_test_sd_default_$$"
mkdir -p "$TEST_SD_DIR"
export SD_MOUNT_POINT="$TEST_SD_DIR"

PASS=0
FAIL=0

# ── colours ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
DIM='\033[2m'

# ── per-test timing & result tracking ────────────────────────────────────────
# Every call to header() starts a new test "slot". pass() and fail() accumulate
# counts into the current slot. _finish_test() closes the slot, prints a brief
# inline footer, and appends a row to _test_log for the final summary table.

_test_name=""          # name of the currently running test
_test_start_ms=0       # epoch-millisecond when the current test began
_test_pass=0           # assertions passed in the current test
_test_fail=0           # assertions failed in the current test
declare -a _test_log=() # finalized rows: "name|pass|fail|duration_ms"

_now_ms() {
    # Milliseconds since epoch. Requires GNU coreutils date (+%s%3N).
    # Falls back to whole-second precision via $SECONDS when unavailable.
    local ms
    ms=$(date +%s%3N 2>/dev/null)
    [[ "$ms" =~ ^[0-9]+$ ]] && printf '%s' "$ms" || printf '%s' "$(( SECONDS * 1000 ))"
}

_term_cols() {
    local cols
    cols=$(tput cols 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ && $cols -gt 40 ]] && printf '%s' "$cols" || printf '%s' "80"
}

# Close the current test slot: print the inline footer and save the result row.
# Calling this when _test_name is empty is a safe no-op.
_finish_test() {
    [[ -z "$_test_name" ]] && return
    local end_ms duration_ms dur_str footer_color counts_str
    end_ms=$(_now_ms)
    duration_ms=$(( end_ms - _test_start_ms ))
    dur_str=$(awk "BEGIN { printf \"%.2f\", $duration_ms / 1000 }")
    if (( _test_fail > 0 )); then
        footer_color="$RED"
        counts_str="${_test_pass} passed, ${_test_fail} FAILED"
    else
        footer_color="$GREEN"
        counts_str="${_test_pass} passed"
    fi
    echo -e "  ${footer_color}↳ ${dur_str}s  ·  ${counts_str}${RESET}"
    _test_log+=("$_test_name|$_test_pass|$_test_fail|$duration_ms")
    _test_name=""   # guard against double-finalization
}

# ── output helpers ────────────────────────────────────────────────────────────

pass() {
    echo -e "  ${GREEN}[PASS]${RESET} $*"
    PASS=$(( PASS + 1 ))
    _test_pass=$(( _test_pass + 1 ))
}

fail() {
    echo -e "  ${RED}[FAIL]${RESET} $*"
    FAIL=$(( FAIL + 1 ))
    _test_fail=$(( _test_fail + 1 ))
}

header() {
    # Finalize the previous test before starting a new one.
    _finish_test
    # Open the new test slot.
    _test_name="$*"
    _test_start_ms=$(_now_ms)
    _test_pass=0
    _test_fail=0
    # Print a full-width horizontal rule with the test name embedded.
    local cols title pad remaining
    cols=$(_term_cols)
    title="─── $*  "
    remaining=$(( cols - ${#title} ))
    if (( remaining > 0 )); then
        pad=$(printf '─%.0s' $(seq 1 "$remaining"))
    else
        pad=""
    fi
    echo -e "\n${BOLD}${title}${pad}${RESET}"
}

# ── final summary table ───────────────────────────────────────────────────────
# Prints a columnar table of every test's status, assertion counts, and wall
# time. Called once at the very end of the script, after all tests have run.

_print_summary() {
    _finish_test   # close the last test slot if still open

    local cols
    cols=$(_term_cols)

    # Fixed column widths (characters):
    #   Status  Time     Pass  Fail
    #     6      8         4     4
    # Test-name column gets whatever remains after fixed cols + spacing.
    local w_status=6 w_time=8 w_pass=4 w_fail=4
    local w_fixed=$(( w_status + 2 + w_time + 2 + w_pass + 2 + w_fail + 2 ))
    local w_name=$(( cols - w_fixed - 2 ))   # 2 = leading indent
    (( w_name < 20 )) && w_name=20

    local thick_hr thin_hr
    thick_hr=$(printf '━%.0s' $(seq 1 "$cols"))
    thin_hr=$(printf  '─%.0s' $(seq 1 "$cols"))

    local total_pass=0 total_fail=0 total_dur=0
    local entry name pass_n fail_n dur_ms

    printf '\n%s\n' "$thick_hr"
    printf "${BOLD}  %-${w_status}s  %-${w_time}s  %${w_pass}s  %${w_fail}s  %s${RESET}\n" \
        "Status" "Time" "Pass" "Fail" "Test"
    printf '%s\n' "$thin_hr"

    for entry in "${_test_log[@]}"; do
        IFS='|' read -r name pass_n fail_n dur_ms <<< "$entry"
        local dur_str color status_str display_name
        dur_str=$(awk "BEGIN { printf \"%6.2fs\", $dur_ms / 1000 }")
        if (( fail_n > 0 )); then
            color="$RED";   status_str="FAIL"
        else
            color="$GREEN"; status_str="PASS"
        fi
        # Truncate the test name if it overflows the name column.
        display_name="$name"
        if (( ${#display_name} > w_name )); then
            display_name="${display_name:0:$(( w_name - 1 ))}…"
        fi
        printf "  ${color}%-${w_status}s${RESET}  %${w_time}s  %${w_pass}s  %${w_fail}s  %s\n" \
            "$status_str" "$dur_str" "$pass_n" "$fail_n" "$display_name"
        total_pass=$(( total_pass + pass_n ))
        total_fail=$(( total_fail + fail_n ))
        total_dur=$(( total_dur + dur_ms ))
    done

    local total_dur_str total_color total_status
    total_dur_str=$(awk "BEGIN { printf \"%6.2fs\", $total_dur / 1000 }")
    if (( total_fail > 0 )); then
        total_color="$RED";   total_status="FAIL"
    else
        total_color="$GREEN"; total_status="PASS"
    fi

    local n_tests="${#_test_log[@]}"
    printf '%s\n' "$thin_hr"
    printf "  ${total_color}${BOLD}%-${w_status}s${RESET}  ${BOLD}%${w_time}s  %${w_pass}s  %${w_fail}s${RESET}  ${DIM}%s tests${RESET}\n" \
        "$total_status" "$total_dur_str" "$total_pass" "$total_fail" "$n_tests"
    printf '%s\n' "$thick_hr"
}

# ── job-line parser ──────────────────────────────────────────────────────────
#
# Test job lines look like ~iso|adapter|dest~. Strip the surrounding ~ and
# split on |. Emits the archive path on stdout.

job_line_archive() {
    local line="$1" stripped iso
    stripped="${line#\~}"
    stripped="${stripped%\~}"
    IFS='|' read -r iso _ _ <<< "$stripped"
    printf '%s' "$iso"
}

# ── assertion helpers ─────────────────────────────────────────────────────────

# Assert a single game's extracted iso exists at the expected base dir.
# $1 = game name, $2 = optional base dir override (defaults to $EXTRACT_BASE)
assert_extracted() {
    local game="$1"
    local base="${2:-$EXTRACT_BASE}"
    local file="$base/$game/$game.iso"
    if [[ -f "$file" ]]; then
        pass "$game extracted → $file"
    else
        fail "$game missing: $file not found"
    fi
}

# Assert every game in the job file was extracted correctly.
# $1 = optional base dir override (defaults to $EXTRACT_BASE)
assert_all_extracted() {
    local base="${1:-$EXTRACT_BASE}"
    local line iso game
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        iso=$(job_line_archive "$line")
        game="$(basename "$iso" .7z)"
        assert_extracted "$game" "$base"
    done < "$TEST_JOBS"
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

# Remove extracted output for all games listed in the job file.
# ${EXTRACT_BASE:?} causes an immediate abort if EXTRACT_BASE is unset or empty,
# preventing an accidental rm -rf against /.
#
# Also resets TEST_SD_DIR: once the real SD adapter has dispatched a game,
# precheck would skip it on the next run. Resetting here keeps each test
# that calls clean_extracts starting from a fresh dispatch destination.
clean_extracts() {
    local line iso game
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        iso=$(job_line_archive "$line")
        game="$(basename "$iso" .7z)"
        rm -rf "${EXTRACT_BASE:?}/$game"
    done < "$TEST_JOBS"
    if [[ -n "${TEST_SD_DIR:-}" ]]; then
        rm -rf "$TEST_SD_DIR"
        mkdir -p "$TEST_SD_DIR"
    fi
}

# Abort the test run if any expected output directory still exists after
# clean_extracts. A false clean would cause subsequent tests to pass against
# stale data rather than freshly extracted output.
assert_clean_slate() {
    local line iso game
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        iso=$(job_line_archive "$line")
        game="$(basename "$iso" .7z)"
        if [[ -d "$EXTRACT_BASE/$game" ]]; then
            echo "  [ABORT] Pre-condition failed: $EXTRACT_BASE/$game still exists."
            echo "          Remove it and re-run:  rm -rf $EXTRACT_BASE/$game"
            exit 1
        fi
    done < "$TEST_JOBS"
    pass "clean slate verified for all jobs"
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

while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    iso=$(job_line_archive "$line")
    if [[ -f "$iso" ]]; then
        pass "fixture archive ready: $iso"
    else
        fail "fixture archive missing: $iso — create_fixtures.sh may have failed"
    fi
done < "$TEST_JOBS"

# ── test 1: default run ───────────────────────────────────────────────────────
#
# Runs with all defaults: MAX_UNZIP=2, default QUEUE_DIR.

header "Test 1: default run"
echo "  cmd: bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
assert_clean_slate
bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted

# ── test 2: single unzip worker ───────────────────────────────────────────────
#
# Forces serial extraction (MAX_UNZIP=1). Validates that the queue drains
# correctly and no jobs are skipped when only one worker is running.

header "Test 2: serial extraction (MAX_UNZIP=1)"
echo "  cmd: MAX_UNZIP=1 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
assert_clean_slate
MAX_UNZIP=1 bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted

# ── test 3: more workers than jobs ────────────────────────────────────────────
#
# Runs with more workers than there are jobs (5 workers, 3 jobs).
# Verifies that idle workers exit cleanly without deadlocking or double-processing.

header "Test 3: more workers than jobs (MAX_UNZIP=5, 3 jobs)"
echo "  cmd: MAX_UNZIP=5 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
assert_clean_slate
MAX_UNZIP=5 bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted

# ── test 4: custom QUEUE_DIR ──────────────────────────────────────────────────
#
# Overrides QUEUE_DIR so this run's queue is isolated from the default location.
# After the run the custom queue dir should exist but both sub-queues should be empty.

header "Test 4: custom QUEUE_DIR override"
CUSTOM_QUEUE="/tmp/iso_pipeline_test_queue_$$"
echo "  cmd: QUEUE_DIR=$CUSTOM_QUEUE MAX_UNZIP=2 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
assert_clean_slate
QUEUE_DIR="$CUSTOM_QUEUE" MAX_UNZIP=2 bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted
assert_queue_empty "$CUSTOM_QUEUE/extract"
assert_queue_empty "$CUSTOM_QUEUE/dispatch"
rm -rf "$CUSTOM_QUEUE"

# ── test 5: idempotent re-run (no clean between runs) ─────────────────────────
#
# Runs the pipeline twice back-to-back without clearing the extract dir.
# Verifies that init_environment and queue_init do not fail or corrupt state
# when output directories already exist from a previous run.

header "Test 5: idempotent re-run (extracted dirs already exist)"
echo "  cmd (run 1): bash bin/loadout-pipeline.sh test/example.jobs"
bash "$PIPELINE" "$TEST_JOBS"
echo "  cmd (run 2): bash bin/loadout-pipeline.sh test/example.jobs"
bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted

# ── test 6: custom EXTRACT_DIR ───────────────────────────────────────────────
#
# Overrides EXTRACT_DIR so extraction happens in an isolated location.
# Confirms files land in the custom directory, not the default /tmp/iso_pipeline.
# Uses an explicit base dir override on assertions to avoid mutating EXTRACT_BASE.

header "Test 6: custom EXTRACT_DIR override"
CUSTOM_EXTRACT="/tmp/iso_pipeline_test_extract_$$"
CUSTOM_SD6="/tmp/iso_pipeline_test_sd6_$$"
mkdir -p "$CUSTOM_SD6"
echo "  cmd: EXTRACT_DIR=$CUSTOM_EXTRACT SD_MOUNT_POINT=$CUSTOM_SD6 bash bin/loadout-pipeline.sh test/example.jobs"
EXTRACT_DIR="$CUSTOM_EXTRACT" SD_MOUNT_POINT="$CUSTOM_SD6" bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted "$CUSTOM_EXTRACT"
rm -rf "$CUSTOM_EXTRACT" "$CUSTOM_SD6"

# ── test 7: precheck skip when content already at destination ─────────────────
#
# Prepopulates the SD destination with the expected iso, then runs the pipeline.
# Expects: a [skip] log line for the SD job, the SD job's extract dir to NOT
# be created (precheck short-circuits before copy/extract), and the FTP + HDL
# jobs to still run normally (their exists stubs always return "not present").

header "Test 7: precheck skip when content exists at destination"
CUSTOM_SD="/tmp/iso_pipeline_test_sd_$$"
CUSTOM_EXTRACT7="/tmp/iso_pipeline_test_extract7_$$"
TEST_LOG="/tmp/iso_pipeline_test7_$$.log"
mkdir -p "$CUSTOM_SD/games/game3"
printf 'pre-existing stub iso\n' > "$CUSTOM_SD/games/game3/game3.iso"
echo "  cmd: SD_MOUNT_POINT=$CUSTOM_SD EXTRACT_DIR=$CUSTOM_EXTRACT7 bash bin/loadout-pipeline.sh test/example.jobs"
SD_MOUNT_POINT="$CUSTOM_SD" EXTRACT_DIR="$CUSTOM_EXTRACT7" \
    bash "$PIPELINE" "$TEST_JOBS" >"$TEST_LOG" 2>&1 || true

if grep -E '^\[skip\].*game3\.7z.*already exists at destination' "$TEST_LOG" >/dev/null; then
    pass "game3 skip event logged"
else
    fail "expected [skip] log line for game3 with reason 'already exists at destination'"
    echo "      --- captured output ---"
    sed 's/^/      /' "$TEST_LOG"
    echo "      -----------------------"
fi

if [[ ! -e "$CUSTOM_EXTRACT7/game3/game3.iso" ]]; then
    pass "game3 not extracted (precheck short-circuited before extract)"
else
    fail "game3 extracted despite precheck hit: $CUSTOM_EXTRACT7/game3/game3.iso exists"
fi

assert_extracted game1 "$CUSTOM_EXTRACT7"
assert_extracted game2 "$CUSTOM_EXTRACT7"

rm -rf "$CUSTOM_SD" "$CUSTOM_EXTRACT7" "$TEST_LOG"

# ── test 8: multi-file archive end-to-end ───────────────────────────────────
#
# game4.7z contains TWO members (game4.bin + game4.cue). Verifies that the
# pipeline extracts both, preserving the original filenames, and that the
# dispatch stage happens exactly once for the multi-member archive.

header "Test 8: multi-file archive (.bin + .cue)"
MULTI_EXTRACT="/tmp/iso_pipeline_test_multi_$$"
MULTI_JOBS="/tmp/iso_pipeline_test_multi_$$.jobs"
echo "~$ROOT_DIR/test/fixtures/isos/game4.7z|sd|games/game4~" > "$MULTI_JOBS"
echo "  cmd: EXTRACT_DIR=$MULTI_EXTRACT bash bin/loadout-pipeline.sh $MULTI_JOBS"
EXTRACT_DIR="$MULTI_EXTRACT" bash "$PIPELINE" "$MULTI_JOBS"

if [[ -f "$MULTI_EXTRACT/game4/game4.bin" ]]; then
    pass "game4.bin extracted with original filename preserved"
else
    fail "game4.bin missing from $MULTI_EXTRACT/game4/"
fi
if [[ -f "$MULTI_EXTRACT/game4/game4.cue" ]]; then
    pass "game4.cue extracted with original filename preserved"
else
    fail "game4.cue missing from $MULTI_EXTRACT/game4/"
fi

rm -rf "$MULTI_EXTRACT" "$MULTI_JOBS"

# ── test 9: precheck skip for a multi-file archive ───────────────────────────
#
# Prepopulates BOTH .bin and .cue at the SD destination; the pipeline should
# short-circuit before any copy/extract happens.

header "Test 9: precheck skip when all members already at destination"
MULTI_SD="/tmp/iso_pipeline_test_multi_sd_$$"
MULTI_EXTRACT9="/tmp/iso_pipeline_test_multi9_$$"
MULTI_JOBS9="/tmp/iso_pipeline_test_multi9_$$.jobs"
MULTI_LOG9="/tmp/iso_pipeline_test_multi9_$$.log"
mkdir -p "$MULTI_SD/games/game4"
printf 'prepopulated bin\n' > "$MULTI_SD/games/game4/game4.bin"
printf 'prepopulated cue\n' > "$MULTI_SD/games/game4/game4.cue"
echo "~$ROOT_DIR/test/fixtures/isos/game4.7z|sd|games/game4~" > "$MULTI_JOBS9"
echo "  cmd: SD_MOUNT_POINT=$MULTI_SD EXTRACT_DIR=$MULTI_EXTRACT9 bash bin/loadout-pipeline.sh $MULTI_JOBS9"
SD_MOUNT_POINT="$MULTI_SD" EXTRACT_DIR="$MULTI_EXTRACT9" \
    bash "$PIPELINE" "$MULTI_JOBS9" >"$MULTI_LOG9" 2>&1 || true

if grep -E '^\[skip\].*game4\.7z.*already exists at destination' "$MULTI_LOG9" >/dev/null; then
    pass "multi-file archive skip event logged"
else
    fail "expected [skip] log line for game4"
    sed 's/^/      /' "$MULTI_LOG9"
fi

if [[ ! -e "$MULTI_EXTRACT9/game4" ]]; then
    pass "multi-file archive not extracted (short-circuited)"
else
    fail "game4 extracted despite precheck skip"
fi

rm -rf "$MULTI_SD" "$MULTI_EXTRACT9" "$MULTI_JOBS9" "$MULTI_LOG9"

# ── test 10: precheck does NOT skip when only some members present ──────────
#
# Prepopulates ONLY game4.bin — the .cue is missing. Precheck must treat this
# as "not fully present" and let the pipeline re-extract so the destination
# ends up consistent.

header "Test 10: precheck partial hit does not skip"
PARTIAL_SD="/tmp/iso_pipeline_test_partial_sd_$$"
PARTIAL_EXTRACT="/tmp/iso_pipeline_test_partial_$$"
PARTIAL_JOBS="/tmp/iso_pipeline_test_partial_$$.jobs"
PARTIAL_LOG="/tmp/iso_pipeline_test_partial_$$.log"
mkdir -p "$PARTIAL_SD/games/game4"
printf 'only bin present\n' > "$PARTIAL_SD/games/game4/game4.bin"
echo "~$ROOT_DIR/test/fixtures/isos/game4.7z|sd|games/game4~" > "$PARTIAL_JOBS"
echo "  cmd: SD_MOUNT_POINT=$PARTIAL_SD EXTRACT_DIR=$PARTIAL_EXTRACT bash bin/loadout-pipeline.sh $PARTIAL_JOBS"
SD_MOUNT_POINT="$PARTIAL_SD" EXTRACT_DIR="$PARTIAL_EXTRACT" \
    bash "$PIPELINE" "$PARTIAL_JOBS" >"$PARTIAL_LOG" 2>&1

if grep -E '^\[skip\]' "$PARTIAL_LOG" >/dev/null; then
    fail "precheck incorrectly skipped a partial hit"
    sed 's/^/      /' "$PARTIAL_LOG"
else
    pass "precheck did not skip on partial hit"
fi
if [[ -f "$PARTIAL_EXTRACT/game4/game4.bin" && -f "$PARTIAL_EXTRACT/game4/game4.cue" ]]; then
    pass "game4 re-extracted in full"
else
    fail "game4 not fully re-extracted after partial hit"
fi

rm -rf "$PARTIAL_SD" "$PARTIAL_EXTRACT" "$PARTIAL_JOBS" "$PARTIAL_LOG"

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

make_fail_shim() {
    # $1 = dir to create shim in
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

# ── test 16: rclone adapter stub runs end-to-end ──────────────────────────────
#
# Runs a single job through the full pipeline using the rclone adapter.
# The adapter is still a stub, but this verifies extract→dispatch wiring works
# and the job validates against the adapter regex in jobs.sh.

header "Test 16: rclone adapter stub"

RCLONE_EXTRACT="/tmp/iso_pipeline_test_rclone_$$"
RCLONE_JOBS="/tmp/iso_pipeline_test_rclone_$$.jobs"
RCLONE_LOG="/tmp/iso_pipeline_test_rclone_$$.log"
echo "~$ROOT_DIR/test/fixtures/isos/game1.7z|rclone|remote/games/game1~" > "$RCLONE_JOBS"

echo "  cmd: EXTRACT_DIR=$RCLONE_EXTRACT bash bin/loadout-pipeline.sh $RCLONE_JOBS"
EXTRACT_DIR="$RCLONE_EXTRACT" bash "$PIPELINE" "$RCLONE_JOBS" >"$RCLONE_LOG" 2>&1

if [[ -f "$RCLONE_EXTRACT/game1/game1.iso" ]]; then
    pass "game1 extracted for rclone adapter"
else
    fail "game1 not extracted for rclone adapter"
    sed 's/^/      /' "$RCLONE_LOG"
fi

if grep -q '\[rclone\] STUB' "$RCLONE_LOG"; then
    pass "rclone stub dispatch log line present"
else
    fail "expected [rclone] STUB log line not found"
    sed 's/^/      /' "$RCLONE_LOG"
fi

rm -rf "$RCLONE_EXTRACT" "$RCLONE_JOBS" "$RCLONE_LOG"

# ── test 17: rsync adapter stub runs end-to-end ──────────────────────────────
#
# Same structure as test 16 but for the rsync adapter. Verifies both local
# (no RSYNC_HOST) and remote (with RSYNC_HOST) target formatting via the stub
# log line.

header "Test 17: rsync adapter stub — local target"

RSYNC_EXTRACT="/tmp/iso_pipeline_test_rsync_$$"
RSYNC_JOBS="/tmp/iso_pipeline_test_rsync_$$.jobs"
RSYNC_LOG="/tmp/iso_pipeline_test_rsync_$$.log"
echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|rsync|games/game2~" > "$RSYNC_JOBS"

echo "  cmd: EXTRACT_DIR=$RSYNC_EXTRACT RSYNC_DEST_BASE=/mnt/nas bash bin/loadout-pipeline.sh $RSYNC_JOBS"
EXTRACT_DIR="$RSYNC_EXTRACT" \
    RSYNC_DEST_BASE="/mnt/nas" \
    bash "$PIPELINE" "$RSYNC_JOBS" >"$RSYNC_LOG" 2>&1

if [[ -f "$RSYNC_EXTRACT/game2/game2.iso" ]]; then
    pass "game2 extracted for rsync adapter"
else
    fail "game2 not extracted for rsync adapter"
    sed 's/^/      /' "$RSYNC_LOG"
fi

if grep -q '\[rsync\] STUB.*→ /mnt/nas/games/game2' "$RSYNC_LOG"; then
    pass "rsync local target formatted correctly in stub log"
else
    fail "expected rsync local target log line not found"
    sed 's/^/      /' "$RSYNC_LOG"
fi

# Re-run with a remote host set — verify user@host: prefix appears.
RSYNC_REMOTE_LOG="/tmp/iso_pipeline_test_rsync_remote_$$.log"
RSYNC_REMOTE_EXTRACT="/tmp/iso_pipeline_test_rsync_remote_$$"
echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|rsync|games/game2~" > "$RSYNC_JOBS"

EXTRACT_DIR="$RSYNC_REMOTE_EXTRACT" \
    RSYNC_DEST_BASE="/mnt/nas" \
    RSYNC_HOST="nas.local" \
    RSYNC_USER="admin" \
    bash "$PIPELINE" "$RSYNC_JOBS" >"$RSYNC_REMOTE_LOG" 2>&1

if grep -q '\[rsync\] STUB.*→ admin@nas\.local:/mnt/nas/games/game2' "$RSYNC_REMOTE_LOG"; then
    pass "rsync remote target formatted correctly in stub log"
else
    fail "expected rsync remote target log line not found"
    sed 's/^/      /' "$RSYNC_REMOTE_LOG"
fi

rm -rf "$RSYNC_EXTRACT" "$RSYNC_REMOTE_EXTRACT" "$RSYNC_JOBS" "$RSYNC_LOG" "$RSYNC_REMOTE_LOG"

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

make_registry_kill_shim() {
    # $1 = dir to create shim in
    # $2 = trigger flag path (stable across shim invocations for this test run)
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

# ── test 20: mid-string /../ rejection in load_jobs (M2 regression) ──────────
#
# The traversal defense in jobs.sh must reject '..' path segments anywhere,
# not only at path boundaries. Prior to the M2 fix, the right anchor was
# '(/$|$)' which only matched when '..' was the last segment — so crafted
# destinations like 'games/../../../etc/passwd' slipped past validation and
# only got caught later by the sd adapter's runtime containment check (and
# not at all for other adapters, which leak to their remote).

header "Test 20: mid-string /../ rejection in load_jobs (M2 regression)"

TRAV_JOBS="/tmp/iso_pipeline_test_trav_$$.jobs"
TRAV_LOG="/tmp/iso_pipeline_test_trav_$$.log"

while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < <(
    export ROOT_DIR
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/jobs.sh"

    # Case A: mid-string traversal in the destination field.
    printf '%s\n' "~/abs/path/game.7z|sd|games/../../../etc/passwd~" > "$TRAV_JOBS"
    JOBS=()
    if load_jobs "$TRAV_JOBS" 2>"$TRAV_LOG"; then
        echo "FAIL mid-string traversal in destination was NOT rejected"
    else
        echo "PASS mid-string traversal in destination rejected"
    fi

    # Case B: mid-string traversal in the ISO path.
    printf '%s\n' "~/abs/../etc/passwd.7z|sd|games/game1~" > "$TRAV_JOBS"
    JOBS=()
    if load_jobs "$TRAV_JOBS" 2>"$TRAV_LOG"; then
        echo "FAIL mid-string traversal in iso path was NOT rejected"
    else
        echo "PASS mid-string traversal in iso path rejected"
    fi

    # Case C: legitimate paths with '.' in filenames (not as segments) still pass.
    printf '%s\n' "~/abs/path/game.v1.7z|sd|games/game.v1~" > "$TRAV_JOBS"
    JOBS=()
    if load_jobs "$TRAV_JOBS" 2>"$TRAV_LOG"; then
        echo "PASS legitimate path with '.' in names still accepted"
    else
        echo "FAIL legitimate path with '.' in names wrongly rejected"
    fi
)

rm -f "$TRAV_JOBS" "$TRAV_LOG"

# ── test 21: real game ISO — multi-file archive (bin+cue) ────────────────────
#
# Exercises the full pipeline end-to-end with an actual 196 MB PS2 game
# archive: "Ultimate Board Game Collection (USA).7z". This test verifies:
#   1. The expanded iso_path character set accepts spaces and parentheses.
#   2. A real multi-member archive (.bin, .cue, Vimm's Lair.txt) extracts
#      all members correctly under their original names.
#   3. The sd adapter copies all members to the ps2/ destination folder.
#
# The test is skipped gracefully when the archive is absent so the suite
# still passes in CI and on machines without the file. To run the full
# test, place the archive in test/fixtures/isos/ manually.

header "Test 21: real game ISO — Ultimate Board Game Collection (USA)"

REAL_ARCHIVE=$(find "$FIXTURES_DIR/isos" -name "Ultimate Board Game Collection*" 2>/dev/null | head -1)
REAL_JOBS="$ROOT_DIR/test/real_isos.jobs"
REAL_EXTRACT="/tmp/iso_pipeline_test_real_isos_$$"
REAL_SD_DIR="/tmp/iso_pipeline_test_real_isos_sd_$$"
REAL_LOG="/tmp/iso_pipeline_test_real_isos_$$.log"

if [[ -z "$REAL_ARCHIVE" ]]; then
    pass "Test 21 skipped — real archive not present in test/fixtures/isos/ (place it there to enable)"
else
    echo "  archive: $REAL_ARCHIVE ($(du -sh "$REAL_ARCHIVE" 2>/dev/null | cut -f1))"
    mkdir -p "$REAL_EXTRACT" "$REAL_SD_DIR"

    set +e
    EXTRACT_DIR="$REAL_EXTRACT" \
    SD_MOUNT_POINT="$REAL_SD_DIR" \
    bash "$PIPELINE" "$REAL_JOBS" >"$REAL_LOG" 2>&1
    real_rc=$?
    set -e

    if [[ $real_rc -eq 0 ]]; then
        pass "pipeline completed successfully for real game archive"
    else
        fail "pipeline returned rc=$real_rc for real game archive"
        sed 's/^/      /' "$REAL_LOG"
    fi

    REAL_GAME_DIR="$REAL_EXTRACT/Ultimate Board Game Collection (USA)"
    if [[ -d "$REAL_GAME_DIR" ]]; then
        pass "extracted directory created: $(basename "$REAL_GAME_DIR")"
    else
        fail "extracted directory not created: $REAL_GAME_DIR"
    fi

    # Verify game content members were extracted (strip.list removes Vimm's Lair.txt).
    real_content_members=(
        "Ultimate Board Game Collection (USA).bin"
        "Ultimate Board Game Collection (USA).cue"
    )
    for member in "${real_content_members[@]}"; do
        if [[ -f "$REAL_GAME_DIR/$member" ]]; then
            pass "extracted member present: $member"
        else
            fail "extracted member missing: $member"
        fi
    done

    # Verify Vimm's Lair.txt was stripped from the extracted directory.
    if [[ ! -f "$REAL_GAME_DIR/Vimm's Lair.txt" ]]; then
        pass "Vimm's Lair.txt stripped from extracted directory (not dispatched)"
    else
        fail "Vimm's Lair.txt was NOT stripped — strip.list may not have been applied"
    fi

    # Verify the sd adapter copied game content into the ps2/ destination folder.
    REAL_SD_DEST="$REAL_SD_DIR/ps2"
    for member in "${real_content_members[@]}"; do
        if [[ -f "$REAL_SD_DEST/$member" ]]; then
            pass "sd adapter: member present at ps2/$member"
        else
            fail "sd adapter: member missing from ps2/$member"
        fi
    done

    # Verify Vimm's Lair.txt was never dispatched to the sd destination.
    if [[ ! -f "$REAL_SD_DEST/Vimm's Lair.txt" ]]; then
        pass "Vimm's Lair.txt absent from sd destination (correctly never dispatched)"
    else
        fail "Vimm's Lair.txt reached the sd destination — strip logic did not run before dispatch"
    fi

    rm -rf "$REAL_EXTRACT" "$REAL_SD_DIR" "$REAL_LOG"
fi

# ── cleanup ───────────────────────────────────────────────────────────────────

rm -rf "$TEST_SD_DIR"

# ── summary ───────────────────────────────────────────────────────────────────

_finish_test
_print_summary
[[ $FAIL -eq 0 ]]
