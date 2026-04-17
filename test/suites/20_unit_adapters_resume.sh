#!/usr/bin/env bash
# test/suites/20_unit_adapters_resume.sh
#
# Unit tests for adapter stub gates, the lvol adapter's validation layer,
# and the resume-planner helpers. These all had only end-to-end coverage
# before this suite — a failure anywhere below used to surface as "some
# unrelated pipeline step broke" rather than pointing at the specific
# helper at fault.
#
#   A1  ALLOW_STUB_ADAPTERS=0 regression guard: no adapter is a stub;
#        ftp/rclone refuse when their required env vars are missing
#   A2  lvol.sh refuses when LVOL_MOUNT_POINT does not exist
#   A3  lvol.sh refuses when dest escapes LVOL_MOUNT_POINT
#   RP1 _resume_plan_dest_for_job containment (accept + refuse)
#   RP2 _resume_plan_archive_members returns 1 on an archive with no members
#   RP3 _resume_plan_archive_members drops strip-listed members
#   RP4 _resume_plan_job_is_satisfied cache hit + miss paths
#   RP5 RESUME_PLANNER_IND=0 leaves JOBS untouched
#
# set -e trap: process-substitution subshells inherit `set -e` from
# run_tests.sh. Banned idioms inside `_u_run_subshell < <(...)` blocks:
#   * `(( x++ ))` post-increment when x starts at 0 — use `x=$((x+1))`
#   * bare `(( expr ))` whose value evaluates to 0
#
# ALLOW_STUB_ADAPTERS: run_tests.sh exports this as 1 globally so the
# existing stub-adapter integration tests pass. A1 explicitly unsets it
# in each inline invocation so we test the default-refuse behaviour
# rather than the opt-in stub path.

_u_run_subshell() {
    while IFS= read -r line; do
        case "$line" in
            PASS*) pass "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
        esac
    done
}

# =============================================================================
# A1 — regression guard: no adapter in adapters/ is a stub;
#      real adapters refuse when their required env vars are missing
# =============================================================================

header "Test A1: no adapter is a stub; missing-env refusal for ftp/rclone"

A1_SRC="/tmp/lp_unit_a1_src_$$"
mkdir -p "$A1_SRC"

# Every adapter under adapters/ must be implemented — no "STATUS: STUB"
# banner, no hard "adapter is a stub" refusal. If a new stub slips in, its
# error string will trigger this guard.
A1_STUB_FOUND=0
for adapter_sh in "$ROOT_DIR"/adapters/*.sh; do
    if grep -qi 'STATUS:[[:space:]]*STUB' "$adapter_sh"; then
        fail "stub adapter present: $(basename "$adapter_sh")"
        A1_STUB_FOUND=1
    fi
done
if (( ! A1_STUB_FOUND )); then
    pass "no stub adapters found under adapters/"
fi

# ftp and rclone are real adapters — they refuse with a missing-env-var
# error when their required config is not set and ALLOW_STUB_ADAPTERS is off.
for adapter_spec in "ftp:FTP_HOST" "rclone:RCLONE_REMOTE"; do
    adapter="${adapter_spec%%:*}"
    envvar="${adapter_spec##*:}"
    A1_RC=0
    A1_LOG=$(mktemp)
    env -u ALLOW_STUB_ADAPTERS -u "$envvar" \
        bash "$ROOT_DIR/adapters/${adapter}.sh" \
        "$A1_SRC" "some/dest" >"$A1_LOG" 2>&1 || A1_RC=$?

    if (( A1_RC == 1 )); then
        pass "${adapter}: refuses with rc=1 when ${envvar} unset"
    else
        fail "${adapter}: expected rc=1, got $A1_RC"
        sed 's/^/      /' "$A1_LOG"
    fi
    if grep -q "${envvar}" "$A1_LOG"; then
        pass "${adapter}: log mentions missing ${envvar}"
    else
        fail "${adapter}: log missing ${envvar} error message"
        sed 's/^/      /' "$A1_LOG"
    fi

    rm -f "$A1_LOG"
done

rm -rf "$A1_SRC"

# =============================================================================
# A2 — lvol.sh refuses when LVOL_MOUNT_POINT does not exist
# =============================================================================

header "Test A2: lvol.sh refuses missing LVOL_MOUNT_POINT"

A2_SRC="/tmp/lp_unit_a2_src_$$"
mkdir -p "$A2_SRC"
A2_MOUNT="/tmp/lp_unit_a2_definitely_missing_$$"
# Make sure it really does not exist.
rm -rf "$A2_MOUNT"

A2_RC=0
A2_LOG=$(mktemp)
LVOL_MOUNT_POINT="$A2_MOUNT" \
    bash "$ROOT_DIR/adapters/lvol.sh" "$A2_SRC" "games/x" \
    >"$A2_LOG" 2>&1 || A2_RC=$?

if (( A2_RC == 1 )); then
    pass "lvol refuses with rc=1 when LVOL_MOUNT_POINT missing"
else
    fail "expected rc=1, got $A2_RC"
    sed 's/^/      /' "$A2_LOG"
fi
if grep -q "LVOL_MOUNT_POINT does not exist" "$A2_LOG"; then
    pass "lvol logs 'LVOL_MOUNT_POINT does not exist'"
else
    fail "expected 'LVOL_MOUNT_POINT does not exist' in log"
    sed 's/^/      /' "$A2_LOG"
fi

rm -rf "$A2_SRC" "$A2_LOG"

# =============================================================================
# A3 — lvol.sh refuses when dest escapes LVOL_MOUNT_POINT
# =============================================================================

header "Test A3: lvol.sh refuses dest escaping LVOL_MOUNT_POINT"

A3_SRC="/tmp/lp_unit_a3_src_$$"
A3_MOUNT="/tmp/lp_unit_a3_mount_$$"
mkdir -p "$A3_SRC" "$A3_MOUNT"

A3_RC=0
A3_LOG=$(mktemp)
LVOL_MOUNT_POINT="$A3_MOUNT" \
    bash "$ROOT_DIR/adapters/lvol.sh" "$A3_SRC" "../../etc/cron.d" \
    >"$A3_LOG" 2>&1 || A3_RC=$?

if (( A3_RC == 1 )); then
    pass "lvol refuses containment-escape with rc=1"
else
    fail "expected rc=1, got $A3_RC"
    sed 's/^/      /' "$A3_LOG"
fi
if grep -q "destination escapes LVOL_MOUNT_POINT" "$A3_LOG"; then
    pass "lvol logs containment escape"
else
    fail "expected 'destination escapes LVOL_MOUNT_POINT' in log"
    sed 's/^/      /' "$A3_LOG"
fi

rm -rf "$A3_SRC" "$A3_MOUNT" "$A3_LOG"

# =============================================================================
# RP1 — _resume_plan_dest_for_job containment
# =============================================================================

header "Test RP1: _resume_plan_dest_for_job containment"

RP1_MOUNT="/tmp/lp_unit_rp1_mount_$$"
mkdir -p "$RP1_MOUNT"

_u_run_subshell < <(
    export LVOL_MOUNT_POINT="$RP1_MOUNT"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/resume_planner.sh"

    # Valid dest — must print the canonical absolute path and return 0.
    out=$(_resume_plan_dest_for_job "games/x")
    rc=$?
    expected="$RP1_MOUNT/games/x"
    if (( rc == 0 )) && [[ "$out" == "$expected" ]]; then
        echo "PASS valid dest resolves under mount"
    else
        echo "FAIL rc=$rc out=$out (expected $expected)"
    fi

    # Escape dest — must return 1 and print nothing.
    set +e
    out=$(_resume_plan_dest_for_job "../../etc/passwd")
    rc=$?
    set -e
    if (( rc == 1 )) && [[ -z "$out" ]]; then
        echo "PASS escape dest rejected with rc=1 and no output"
    else
        echo "FAIL escape rc=$rc out=$out"
    fi
)

rm -rf "$RP1_MOUNT"

# =============================================================================
# RP2 — _resume_plan_archive_members returns 1 on archive with no members
# =============================================================================

header "Test RP2: _resume_plan_archive_members rejects empty archive"

RP2_ARCHIVE="/tmp/lp_unit_rp2_$$.7z"
printf 'this is not a real 7z archive\n' > "$RP2_ARCHIVE"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/resume_planner.sh"

    # Helpers expect the caches to be associative arrays in scope; the
    # real resume_plan() declares them `local -A` in its own frame.
    declare -A _resume_archive_cache=()
    declare -A _resume_dest_cache=()

    set +e
    out=$(_resume_plan_archive_members "$RP2_ARCHIVE" 2>/dev/null)
    rc=$?
    set -e
    if (( rc == 1 )); then
        echo "PASS unreadable archive returns rc=1"
    else
        echo "FAIL expected rc=1, got $rc"
    fi
    if [[ -z "$out" ]]; then
        echo "PASS unreadable archive prints nothing"
    else
        echo "FAIL printed: $out"
    fi
)

rm -f "$RP2_ARCHIVE"

# =============================================================================
# RP3 — _resume_plan_archive_members drops strip-listed members
# =============================================================================

header "Test RP3: _resume_plan_archive_members applies strip filter"

RP3_STRIP="/tmp/lp_unit_rp3_strip_$$.list"
printf 'game4.cue\n' > "$RP3_STRIP"

_u_run_subshell < <(
    export EXTRACT_STRIP_LIST="$RP3_STRIP"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/resume_planner.sh"

    declare -A _resume_archive_cache=()
    declare -A _resume_dest_cache=()

    set +e
    out=$(_resume_plan_archive_members "$FIXTURES_DIR/isos/game4.7z" 2>/dev/null)
    rc=$?
    set -e
    if (( rc == 0 )); then
        echo "PASS real archive returns rc=0"
    else
        echo "FAIL rc=$rc"
    fi
    if grep -q "^game4\.bin$" <<< "$out"; then
        echo "PASS non-strip member (game4.bin) present in output"
    else
        echo "FAIL game4.bin missing from output: $out"
    fi
    if grep -q "^game4\.cue$" <<< "$out"; then
        echo "FAIL game4.cue appeared despite strip filter"
    else
        echo "PASS strip-listed member (game4.cue) filtered out"
    fi
)

rm -f "$RP3_STRIP"

# =============================================================================
# RP4 — _resume_plan_job_is_satisfied hit + miss
# =============================================================================
#
# Create two destination dirs:
#   HIT  — contains both members of game4.7z → satisfied (rc=0)
#   MISS — contains only one member         → not satisfied (rc=1)
#
# Use a fresh EXTRACT_STRIP_LIST pointing at an empty file so the helper
# does not drop anything from the expected set.

header "Test RP4: _resume_plan_job_is_satisfied hit and miss"

RP4_STRIP="/tmp/lp_unit_rp4_strip_$$.list"
: > "$RP4_STRIP"
RP4_HIT="/tmp/lp_unit_rp4_hit_$$"
RP4_MISS="/tmp/lp_unit_rp4_miss_$$"
mkdir -p "$RP4_HIT" "$RP4_MISS"
printf 'hit-bin\n' > "$RP4_HIT/game4.bin"
printf 'hit-cue\n' > "$RP4_HIT/game4.cue"
# MISS dir only has one of the two members.
printf 'miss-bin-only\n' > "$RP4_MISS/game4.bin"

_u_run_subshell < <(
    export EXTRACT_STRIP_LIST="$RP4_STRIP"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/resume_planner.sh"

    declare -A _resume_archive_cache=()
    declare -A _resume_dest_cache=()

    set +e
    _resume_plan_job_is_satisfied "$FIXTURES_DIR/isos/game4.7z" "$RP4_HIT"
    rc=$?
    set -e
    if (( rc == 0 )); then
        echo "PASS fully-present dest reported as satisfied"
    else
        echo "FAIL full dest rc=$rc (expected 0)"
    fi

    set +e
    _resume_plan_job_is_satisfied "$FIXTURES_DIR/isos/game4.7z" "$RP4_MISS"
    rc=$?
    set -e
    if (( rc == 1 )); then
        echo "PASS partial dest reported as not satisfied"
    else
        echo "FAIL partial dest rc=$rc (expected 1)"
    fi

    # Missing dir: fast early-exit branch (local_root does not exist).
    set +e
    _resume_plan_job_is_satisfied "$FIXTURES_DIR/isos/game4.7z" "/tmp/lp_unit_rp4_ghost_$$"
    rc=$?
    set -e
    if (( rc == 1 )); then
        echo "PASS missing dest takes the fast-fail path"
    else
        echo "FAIL missing dest rc=$rc (expected 1)"
    fi
)

rm -rf "$RP4_HIT" "$RP4_MISS" "$RP4_STRIP"

# =============================================================================
# RP5 — RESUME_PLANNER_IND=0 leaves JOBS untouched
# =============================================================================

header "Test RP5: RESUME_PLANNER_IND=0 bypasses planner"

_u_run_subshell < <(
    export RESUME_PLANNER_IND=0
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/resume_planner.sh"

    JOBS=(
        "~/iso/a.7z|lvol|games/a~"
        "~/iso/b.7z|lvol|games/b~"
        "~/iso/c.7z|lvol|games/c~"
    )

    resume_plan

    if (( ${#JOBS[@]} == 3 )); then
        echo "PASS JOBS length unchanged"
    else
        echo "FAIL JOBS length=${#JOBS[@]} (expected 3)"
    fi
    if [[ "${JOBS[0]}" == "~/iso/a.7z|lvol|games/a~" && \
          "${JOBS[1]}" == "~/iso/b.7z|lvol|games/b~" && \
          "${JOBS[2]}" == "~/iso/c.7z|lvol|games/c~" ]]; then
        echo "PASS JOBS contents unchanged"
    else
        echo "FAIL JOBS contents mutated: ${JOBS[*]}"
    fi
)
