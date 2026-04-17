#!/usr/bin/env bash
# test/suites/13_prereq.sh
#
# Unit tests for lib/prereq.sh — the preflight runtime-dependency check that
# fires before init_environment so a misconfigured host fails with a clear,
# actionable error instead of crashing inside a worker.
#
# Strategy: each test sources lib/prereq.sh in a subshell with a synthesized
# $PATH that either contains everything (happy path), nothing (empty-path
# worst case), or every required binary except a specific one (surgical
# missing-dependency simulation). Because check_prerequisites calls exit 1
# on any missing command, we capture the subshell's exit status directly
# rather than returning a sentinel from inside the function.

# ─── shared helper: build a PATH dir that mirrors the real $PATH ──────────────
# Creates a directory full of symlinks pointing at the real binaries for every
# command in lib/prereq.sh's required_commands list, optionally excluding one
# or more names. Used by the "missing only X" tests to simulate the absence
# of a single dependency without actually uninstalling anything.
#
# Parameters
#   $1  target_dir — directory to populate (created if missing)
#   $2+ omit…      — command names to skip (leave unlinked)
_p_build_fake_bin() {
    local target_dir="$1"; shift
    local omit=" $* "
    mkdir -p "$target_dir"
    local cmd src
    for cmd in stat realpath df du install find xargs ps flock 7z \
               mkdir mv cp rm ln chmod \
               awk sed grep sort head tail tr cut wc \
               bash printf echo date; do
        [[ "$omit" == *" $cmd "* ]] && continue
        src=$(command -v "$cmd" 2>/dev/null) || continue
        ln -sf "$src" "$target_dir/$cmd"
    done
}

# ── test P1: happy path — check_prerequisites succeeds on a healthy host ─────
#
# The test host already passed 01_prerequisites.sh (7z check), so every
# dependency the pipeline lists must resolve. If this test ever fails, either
# the required_commands list grew a new entry that the CI image is missing,
# or the host really is broken — both are worth knowing about up front.

header "Test P1: check_prerequisites succeeds on healthy host"

P1_SCRIPT=$(cat <<'SCRIPT'
set -euo pipefail
ROOT_DIR="$1"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/prereq.sh"
check_prerequisites
echo "PREREQ_OK"
SCRIPT
)

P1_OUT=$(bash -c "$P1_SCRIPT" -- "$ROOT_DIR" 2>&1)
P1_RC=$?

if (( P1_RC == 0 )); then
    pass "check_prerequisites exited 0 on healthy host"
else
    fail "check_prerequisites failed unexpectedly (rc=$P1_RC)"
    sed 's/^/      /' <<< "$P1_OUT"
fi

if grep -q '^PREREQ_OK$' <<< "$P1_OUT"; then
    pass "check_prerequisites returned (did not call exit)"
else
    fail "check_prerequisites did not return cleanly"
fi

# ── test P2: empty PATH → every core command reported missing ────────────────
#
# Pointing PATH at a nonexistent directory is the fastest way to make every
# `command -v` probe fail simultaneously. We verify: (a) the function exits
# non-zero, (b) the diagnostic mentions the "prerequisite check FAILED"
# banner, (c) a representative sample of required commands (7z, flock, stat)
# all appear in the "not found" list, and (d) the install-recipe hint is
# printed so a user can fix it without reading the source.

header "Test P2: check_prerequisites fails with empty PATH"

P2_SCRIPT=$(cat <<'SCRIPT'
set +e
ROOT_DIR="$1"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/prereq.sh"
PATH="/nonexistent_lp_prereq_dir_$$"
check_prerequisites
# unreachable on failure: check_prerequisites calls exit 1
echo "UNEXPECTED_RETURN"
SCRIPT
)

P2_LOG="/tmp/lp_prereq_p2_$$.log"
P2_RC=0
bash -c "$P2_SCRIPT" -- "$ROOT_DIR" >"$P2_LOG" 2>&1 || P2_RC=$?

if (( P2_RC == 1 )); then
    pass "check_prerequisites exited 1 with empty PATH"
else
    fail "expected exit 1, got $P2_RC"
    sed 's/^/      /' "$P2_LOG"
fi

if ! grep -q 'UNEXPECTED_RETURN' "$P2_LOG"; then
    pass "check_prerequisites called exit (did not fall through)"
else
    fail "check_prerequisites returned instead of exiting"
fi

if grep -q 'prerequisite check FAILED' "$P2_LOG"; then
    pass "failure banner present in diagnostic output"
else
    fail "expected 'prerequisite check FAILED' banner not found"
fi

for cmd in 7z flock stat; do
    if grep -qE "^\[ERROR\] +- ${cmd}\$" "$P2_LOG"; then
        pass "missing command listed: $cmd"
    else
        fail "missing command NOT listed: $cmd"
    fi
done

if grep -q 'README.md' "$P2_LOG"; then
    pass "diagnostic references README.md"
else
    fail "diagnostic should point users at README.md"
fi

if grep -qi 'apt-get install' "$P2_LOG" && grep -qi 'dnf install' "$P2_LOG"; then
    pass "diagnostic includes per-distro install recipes"
else
    fail "diagnostic should include Debian + Fedora install recipes"
fi

rm -f "$P2_LOG"

# ── test P3: only 7z missing → only 7z reported ──────────────────────────────
#
# The surgical case: build a fake PATH that contains every dependency except
# 7z. Verifies the reporter does NOT false-positive on present commands and
# DOES flag the one that's actually missing. This is the test that would have
# caught the "accidentally checks wrong binary name" class of bug.

header "Test P3: check_prerequisites reports only 7z when only 7z is missing"

P3_BIN="/tmp/lp_prereq_p3_bin_$$"
_p_build_fake_bin "$P3_BIN" 7z

P3_SCRIPT=$(cat <<'SCRIPT'
set +e
ROOT_DIR="$1"
FAKE_BIN="$2"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/prereq.sh"
PATH="$FAKE_BIN"
check_prerequisites
echo "UNEXPECTED_RETURN"
SCRIPT
)

P3_LOG="/tmp/lp_prereq_p3_$$.log"
P3_RC=0
bash -c "$P3_SCRIPT" -- "$ROOT_DIR" "$P3_BIN" >"$P3_LOG" 2>&1 || P3_RC=$?

if (( P3_RC == 1 )); then
    pass "check_prerequisites exited 1 with only 7z missing"
else
    fail "expected exit 1, got $P3_RC"
    sed 's/^/      /' "$P3_LOG"
fi

if grep -qE '^\[ERROR\] +- 7z$' "$P3_LOG"; then
    pass "7z flagged as missing"
else
    fail "7z should be reported missing"
    sed 's/^/      /' "$P3_LOG"
fi

# None of the commands we DID provide should show up in the missing list.
# Pick a representative sample rather than every one — a single false positive
# is enough to prove the bug.
for cmd in stat flock find awk grep; do
    if grep -qE "^\[ERROR\] +- ${cmd}\$" "$P3_LOG"; then
        fail "$cmd incorrectly reported missing (it's in the fake PATH)"
    else
        pass "$cmd correctly recognized as present"
    fi
done

rm -rf "$P3_BIN"
rm -f "$P3_LOG"

# ── test P4: multiple missing → all listed ───────────────────────────────────
#
# Regression guard against a reporter that short-circuits on the first failure.
# We omit two representative commands from different package groups (7z from
# p7zip, flock from util-linux) and verify both appear in the error output.

header "Test P4: check_prerequisites reports every missing command"

P4_BIN="/tmp/lp_prereq_p4_bin_$$"
_p_build_fake_bin "$P4_BIN" 7z flock

P4_SCRIPT=$(cat <<'SCRIPT'
set +e
ROOT_DIR="$1"
FAKE_BIN="$2"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/prereq.sh"
PATH="$FAKE_BIN"
check_prerequisites
echo "UNEXPECTED_RETURN"
SCRIPT
)

P4_LOG="/tmp/lp_prereq_p4_$$.log"
P4_RC=0
bash -c "$P4_SCRIPT" -- "$ROOT_DIR" "$P4_BIN" >"$P4_LOG" 2>&1 || P4_RC=$?

if (( P4_RC == 1 )); then
    pass "check_prerequisites exited 1 with 7z + flock missing"
else
    fail "expected exit 1, got $P4_RC"
fi

for cmd in 7z flock; do
    if grep -qE "^\[ERROR\] +- ${cmd}\$" "$P4_LOG"; then
        pass "missing command listed: $cmd"
    else
        fail "missing command NOT listed: $cmd"
        sed 's/^/      /' "$P4_LOG"
    fi
done

rm -rf "$P4_BIN"
rm -f "$P4_LOG"

# ── test P5: pipeline entrypoint calls check_prerequisites before init ───────
#
# The whole point of the preflight check is that it fires BEFORE any
# filesystem side effects. We verify the wiring by running the real
# bin/loadout-pipeline.sh entrypoint with an empty PATH (forcing the
# prereq check to fail) and asserting that:
#   1. It exits non-zero.
#   2. The prereq failure banner appears in the output.
#   3. init_environment's "Initializing environment..." log line does NOT
#      appear — i.e., the preflight short-circuited before init ran.
#
# If somebody ever reorders bin/loadout-pipeline.sh so init_environment runs
# first, this test fails loudly.

header "Test P5: entrypoint fails fast when prerequisites are missing"

P5_LOG="/tmp/lp_prereq_p5_$$.log"
P5_RC=0
# Preserve a tiny PATH containing only bash itself so the shebang still
# resolves — everything else the pipeline shells out to must be missing.
P5_FAKE_BIN="/tmp/lp_prereq_p5_bin_$$"
mkdir -p "$P5_FAKE_BIN"
# Provide just enough for the entrypoint's own boot lines to run: bash itself,
# dirname (used by ROOT_DIR resolution), and the handful of coreutils the
# bundled dist needs during its preamble (basename, mktemp, cat, rm, grep, sed).
# Everything the pipeline's check_prerequisites actually tests (7z, flock, etc.)
# is deliberately absent so the preflight check fires.
for _cmd in bash dirname basename mktemp cat rm grep sed; do
    ln -sf "$(command -v "$_cmd")" "$P5_FAKE_BIN/$_cmd"
done
PATH="$P5_FAKE_BIN" bash "$PIPELINE" "$TEST_JOBS" >"$P5_LOG" 2>&1 || P5_RC=$?

if (( P5_RC != 0 )); then
    pass "pipeline exited non-zero with missing prerequisites (rc=$P5_RC)"
else
    fail "pipeline should have failed on missing prerequisites"
fi

if grep -q 'prerequisite check FAILED' "$P5_LOG"; then
    pass "prerequisite failure banner appeared in pipeline output"
else
    fail "pipeline did not emit the prereq failure banner"
    sed 's/^/      /' "$P5_LOG"
fi

if ! grep -q 'Initializing environment' "$P5_LOG"; then
    pass "init_environment did not run — preflight short-circuited first"
else
    fail "init_environment ran before the prereq check — ordering bug"
    sed 's/^/      /' "$P5_LOG"
fi

rm -rf "$P5_FAKE_BIN"
rm -f "$P5_LOG"
