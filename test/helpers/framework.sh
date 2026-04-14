#!/usr/bin/env bash
# test/helpers/framework.sh
#
# Shared test infrastructure sourced by run_tests.sh before any suite file.
# Provides: colour constants, per-test timing and counters, output helpers
# (pass/fail/header), the final summary printer, and all assertion/cleanup
# helpers used by the suites.
#
# Requires the caller to have already defined and exported:
#   ROOT_DIR       — repo root
#   FIXTURES_DIR   — test/fixtures/
#   PIPELINE       — bin/loadout-pipeline.sh
#   TEST_JOBS      — test/example.jobs
#   EXTRACT_BASE   — default extract scratch root
#   TEST_SD_DIR    — default SD destination for the suite
#   PASS / FAIL    — global counters (initialised to 0 by the orchestrator)

# ── colours ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'
DIM='\033[2m'

# ── per-test timing & result tracking ────────────────────────────────────────
# Every call to header() starts a new test "slot". pass() and fail() accumulate
# counts into the current slot. _finish_test() closes the slot, prints a brief
# inline footer, and appends a row to _test_log for the final summary table.

_test_name=""           # name of the currently running test
_test_start_ms=0        # epoch-millisecond when the current test began
_test_pass=0            # assertions passed in the current test
_test_fail=0            # assertions failed in the current test
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
