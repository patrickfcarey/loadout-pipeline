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
#   H1  hdl dvd + single .iso → inject_dvd
#   H2  hdl dvd + .cue/.bin contamination → reject
#   H3  hdl cd + .cue/.bin → inject_cd with the cue
#   H4  hdl cd + .iso alone → inject_cd with the iso (fallback)
#   H5  hdl cd + .cue + .iso → reject (ambiguous)
#   H6  hdl cd + .cue without .bin → reject
#   H7  hdl cd + .bin without .cue → reject
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

# =============================================================================
# H1–H7 — hdl_dump adapter image selection (Option A)
#
# The per-job <cd|dvd> format gates which image files are legal under $src and
# which inject subcommand is used. These tests exercise the selection logic
# without requiring a real hdl_dump binary: a shim captures the argv that
# would have been passed to the real binary, and we assert on it.
#
#   H1  dvd + single .iso → inject_dvd <iso>
#   H2  dvd + .iso + .cue/.bin → rejected
#   H3  cd + .cue + .bin → inject_cd <cue>  (cue preferred over iso fallback)
#   H4  cd + single .iso alone → inject_cd <iso>
#   H5  cd + .cue + .iso → rejected (ambiguous)
#   H6  cd + .cue without .bin → rejected
#   H7  cd + .bin without .cue → rejected
# =============================================================================

H_ROOT="/tmp/lp_unit_hdl_$$"
mkdir -p "$H_ROOT"

# Shim that captures what the adapter would have passed to real hdl_dump.
# Accepts any argv and writes it to $HDL_SHIM_CAPTURE.
H_SHIM="$H_ROOT/hdl_dump_shim"
cat > "$H_SHIM" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${HDL_SHIM_CAPTURE:?HDL_SHIM_CAPTURE not set}"
exit 0
SHIM
chmod 0755 "$H_SHIM"

# Runs the hdl adapter against a pre-populated src dir and returns
#   rc = adapter exit code
# with the shim capture left at $HDL_SHIM_CAPTURE and stderr+stdout at $2.
_h_run_adapter() {
    local src="$1" logfile="$2" format="$3" title="$4"
    local rc=0
    env -u ALLOW_STUB_ADAPTERS \
        HDL_DUMP_BIN="$H_SHIM" \
        HDL_INSTALL_TARGET="hdd0:" \
        HDL_SHIM_CAPTURE="$H_ROOT/capture.txt" \
        bash "$ROOT_DIR/adapters/hdl_dump.sh" \
            "$src" "${format}|${title}" \
            >"$logfile" 2>&1 || rc=$?
    echo "$rc"
}

# ── H1: dvd + single .iso ──────────────────────────────────────────────────
header "Test H1: hdl dvd + single .iso → inject_dvd"
H1_SRC="$H_ROOT/h1"; mkdir -p "$H1_SRC"
: > "$H1_SRC/game.iso"
H1_LOG="$H_ROOT/h1.log"
H1_RC=$(_h_run_adapter "$H1_SRC" "$H1_LOG" "dvd" "PS2 Title")
if [[ "$H1_RC" == 0 ]]; then
    pass "H1 adapter rc=0"
else
    fail "H1 expected rc=0, got $H1_RC"
    sed 's/^/      /' "$H1_LOG"
fi
if [[ -f "$H_ROOT/capture.txt" ]]; then
    mapfile -t H1_ARGS < "$H_ROOT/capture.txt"
    if [[ "${H1_ARGS[0]:-}" == "inject_dvd" && "${H1_ARGS[3]:-}" == "$H1_SRC/game.iso" ]]; then
        pass "H1 invoked inject_dvd with the .iso"
    else
        fail "H1 wrong shim argv: ${H1_ARGS[*]}"
    fi
fi
rm -f "$H_ROOT/capture.txt"

# ── H2: dvd + .iso + .cue/.bin → reject ────────────────────────────────────
header "Test H2: hdl dvd rejects .cue/.bin contamination"
H2_SRC="$H_ROOT/h2"; mkdir -p "$H2_SRC"
: > "$H2_SRC/game.iso"
: > "$H2_SRC/game.cue"
: > "$H2_SRC/game.bin"
H2_LOG="$H_ROOT/h2.log"
H2_RC=$(_h_run_adapter "$H2_SRC" "$H2_LOG" "dvd" "PS2 Title")
if [[ "$H2_RC" == 1 ]]; then
    pass "H2 adapter rc=1"
else
    fail "H2 expected rc=1, got $H2_RC"
    sed 's/^/      /' "$H2_LOG"
fi
if grep -q "dvd-format job must not contain" "$H2_LOG"; then
    pass "H2 log mentions dvd/cue-bin rejection"
else
    fail "H2 missing dvd-format rejection message"
    sed 's/^/      /' "$H2_LOG"
fi
[[ ! -f "$H_ROOT/capture.txt" ]] && pass "H2 shim never invoked" \
    || fail "H2 shim invoked despite rejection"
rm -f "$H_ROOT/capture.txt"

# ── H3: cd + .cue + .bin → inject_cd with cue ──────────────────────────────
header "Test H3: hdl cd + .cue/.bin → inject_cd with cue"
H3_SRC="$H_ROOT/h3"; mkdir -p "$H3_SRC"
: > "$H3_SRC/game.cue"
: > "$H3_SRC/game.bin"
H3_LOG="$H_ROOT/h3.log"
H3_RC=$(_h_run_adapter "$H3_SRC" "$H3_LOG" "cd" "PS2 CD Title")
if [[ "$H3_RC" == 0 ]]; then
    pass "H3 adapter rc=0"
else
    fail "H3 expected rc=0, got $H3_RC"
    sed 's/^/      /' "$H3_LOG"
fi
if [[ -f "$H_ROOT/capture.txt" ]]; then
    mapfile -t H3_ARGS < "$H_ROOT/capture.txt"
    if [[ "${H3_ARGS[0]:-}" == "inject_cd" && "${H3_ARGS[3]:-}" == "$H3_SRC/game.cue" ]]; then
        pass "H3 invoked inject_cd with the .cue (not .bin)"
    else
        fail "H3 wrong shim argv: ${H3_ARGS[*]}"
    fi
fi
rm -f "$H_ROOT/capture.txt"

# ── H4: cd + single .iso alone → inject_cd with iso ────────────────────────
header "Test H4: hdl cd + .iso alone → inject_cd with iso (fallback)"
H4_SRC="$H_ROOT/h4"; mkdir -p "$H4_SRC"
: > "$H4_SRC/game.iso"
H4_LOG="$H_ROOT/h4.log"
H4_RC=$(_h_run_adapter "$H4_SRC" "$H4_LOG" "cd" "PS2 CD ISO")
if [[ "$H4_RC" == 0 ]]; then
    pass "H4 adapter rc=0"
else
    fail "H4 expected rc=0, got $H4_RC"
    sed 's/^/      /' "$H4_LOG"
fi
if [[ -f "$H_ROOT/capture.txt" ]]; then
    mapfile -t H4_ARGS < "$H_ROOT/capture.txt"
    if [[ "${H4_ARGS[0]:-}" == "inject_cd" && "${H4_ARGS[3]:-}" == "$H4_SRC/game.iso" ]]; then
        pass "H4 invoked inject_cd with the .iso"
    else
        fail "H4 wrong shim argv: ${H4_ARGS[*]}"
    fi
fi
rm -f "$H_ROOT/capture.txt"

# ── H5: cd + .cue + .iso → reject (ambiguous) ──────────────────────────────
header "Test H5: hdl cd rejects .cue + .iso (ambiguous)"
H5_SRC="$H_ROOT/h5"; mkdir -p "$H5_SRC"
: > "$H5_SRC/game.iso"
: > "$H5_SRC/game.cue"
: > "$H5_SRC/game.bin"
H5_LOG="$H_ROOT/h5.log"
H5_RC=$(_h_run_adapter "$H5_SRC" "$H5_LOG" "cd" "PS2 Mixed")
if [[ "$H5_RC" == 1 ]]; then
    pass "H5 adapter rc=1"
else
    fail "H5 expected rc=1, got $H5_RC"
    sed 's/^/      /' "$H5_LOG"
fi
if grep -q "both \*\.cue and \*\.iso" "$H5_LOG"; then
    pass "H5 log mentions cue+iso ambiguity"
else
    fail "H5 missing ambiguity message"
    sed 's/^/      /' "$H5_LOG"
fi
rm -f "$H_ROOT/capture.txt"

# ── H6: cd + .cue without .bin → reject ────────────────────────────────────
header "Test H6: hdl cd rejects .cue with no .bin"
H6_SRC="$H_ROOT/h6"; mkdir -p "$H6_SRC"
: > "$H6_SRC/game.cue"
H6_LOG="$H_ROOT/h6.log"
H6_RC=$(_h_run_adapter "$H6_SRC" "$H6_LOG" "cd" "PS2 Orphan Cue")
if [[ "$H6_RC" == 1 ]]; then
    pass "H6 adapter rc=1"
else
    fail "H6 expected rc=1, got $H6_RC"
    sed 's/^/      /' "$H6_LOG"
fi
if grep -q "no \*\.bin" "$H6_LOG"; then
    pass "H6 log mentions missing .bin"
else
    fail "H6 missing 'no .bin' message"
    sed 's/^/      /' "$H6_LOG"
fi
rm -f "$H_ROOT/capture.txt"

# ── H7: cd + .bin without .cue → reject ────────────────────────────────────
header "Test H7: hdl cd rejects .bin with no .cue"
H7_SRC="$H_ROOT/h7"; mkdir -p "$H7_SRC"
: > "$H7_SRC/game.bin"
H7_LOG="$H_ROOT/h7.log"
H7_RC=$(_h_run_adapter "$H7_SRC" "$H7_LOG" "cd" "PS2 Orphan Bin")
if [[ "$H7_RC" == 1 ]]; then
    pass "H7 adapter rc=1"
else
    fail "H7 expected rc=1, got $H7_RC"
    sed 's/^/      /' "$H7_LOG"
fi
if grep -q "without \*\.cue" "$H7_LOG"; then
    pass "H7 log mentions missing .cue"
else
    fail "H7 missing 'without .cue' message"
    sed 's/^/      /' "$H7_LOG"
fi
rm -f "$H_ROOT/capture.txt"

rm -rf "$H_ROOT"

# =============================================================================
# A4 — lvol.sh invokes rsync with -c (checksum)
# =============================================================================
#
# 7z x -aoa resets file mtimes on every re-extraction, so rsync's default
# size+mtime skip would re-transfer every file on every re-run. The -c flag
# forces a content checksum comparison, keeping idempotent re-runs a near-
# zero-cost no-op. This test captures rsync's argv via a shim and asserts -c
# is present (either as a standalone flag or combined into -ac).
#
# The shim mimics rsync by copying $src/ to $dst/ so the adapter's post-rsync
# log_trace still sees a populated target. It also intercepts common rsync
# invocations used by other paths (reading its exit code explicitly).

header "Test A4: lvol.sh rsync invocation includes -c"

A4_SHIM_ROOT="/tmp/lp_unit_a4_$$"
A4_SRC="$A4_SHIM_ROOT/src"
A4_MOUNT="$A4_SHIM_ROOT/mount"
A4_CAPTURE="$A4_SHIM_ROOT/rsync_argv.txt"
mkdir -p "$A4_SRC" "$A4_MOUNT"
printf 'payload\n' > "$A4_SRC/game.iso"

cat > "$A4_SHIM_ROOT/rsync" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${A4_CAPTURE:?A4_CAPTURE not set}"
# Last two args are always src/ and target/ — do a minimal copy so the
# adapter's post-rsync checks (if any) see a populated destination.
_src="${@: -2:1}"
_dst="${@: -1:1}"
mkdir -p "$_dst"
cp -r "$_src". "$_dst" 2>/dev/null || cp -r "$_src"* "$_dst" 2>/dev/null || true
exit 0
SHIM
chmod 0755 "$A4_SHIM_ROOT/rsync"

A4_RC=0
A4_LOG=$(mktemp)
PATH="$A4_SHIM_ROOT:$PATH" A4_CAPTURE="$A4_CAPTURE" \
    LVOL_MOUNT_POINT="$A4_MOUNT" \
    bash "$ROOT_DIR/adapters/lvol.sh" "$A4_SRC" "games/x" \
    >"$A4_LOG" 2>&1 || A4_RC=$?

if (( A4_RC == 0 )); then
    pass "A4 lvol adapter succeeded with rsync on PATH"
else
    fail "A4 lvol adapter rc=$A4_RC (expected 0)"
    sed 's/^/      /' "$A4_LOG"
fi

if [[ -f "$A4_CAPTURE" ]]; then
    # Read argv into an array; first element is typically the flag bundle.
    mapfile -t A4_ARGV < "$A4_CAPTURE"
    # -c may appear bundled with other short flags (e.g. -ac) or standalone.
    A4_HAS_C=0
    for _arg in "${A4_ARGV[@]}"; do
        case "$_arg" in
            -*c*) A4_HAS_C=1; break ;;
            -c)   A4_HAS_C=1; break ;;
        esac
    done
    if (( A4_HAS_C )); then
        pass "A4 rsync argv includes -c (checksum)"
    else
        fail "A4 rsync argv missing -c: ${A4_ARGV[*]}"
    fi
else
    fail "A4 rsync shim did not capture argv"
fi

rm -rf "$A4_SHIM_ROOT" "$A4_LOG"

# =============================================================================
# F1 — ftp.sh lftp script quotes paths and keeps credentials off argv
# =============================================================================
#
# Previously the ftp adapter inlined $FTP_USER, $FTP_PASS, $src, and
# $remote_path unquoted into lftp's command stream. A space in $src (allowed
# by the iso_path regex) split `mirror`'s arguments; a comma in $FTP_PASS
# corrupted `open -u user,pass`. The fix passes creds via
# `set ftp:default-{user,password}` (both inside lftp's scripting language,
# heredoc'd on stdin) and double-quotes the paths within the lftp script so
# lftp tokenises them as single args.
#
# Validation:
#   (a) Source path with a space reaches lftp as a single token.
#   (b) Credentials are NOT passed on lftp's argv.
#   (c) The heredoc contains `set ftp:default-user "<user>"` form.

header "Test F1: ftp.sh lftp quoting + credentials hidden from argv"

F1_ROOT="/tmp/lp_unit_f1_$$"
F1_SRC="$F1_ROOT/dir with space"
mkdir -p "$F1_SRC"
printf 'payload\n' > "$F1_SRC/game.iso"

# Shim: writes argv (one line each) and full stdin content to capture files.
cat > "$F1_ROOT/lftp" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${F1_ARGV:?F1_ARGV not set}"
cat > "${F1_STDIN:?F1_STDIN not set}"
exit 0
SHIM
chmod 0755 "$F1_ROOT/lftp"

F1_ARGV="$F1_ROOT/argv.txt"
F1_STDIN="$F1_ROOT/stdin.txt"
F1_LOG=$(mktemp)
F1_RC=0
env -u ALLOW_STUB_ADAPTERS \
    PATH="$F1_ROOT:$PATH" \
    F1_ARGV="$F1_ARGV" F1_STDIN="$F1_STDIN" \
    FTP_HOST="ftp.example.test" \
    FTP_USER="bob" \
    FTP_PASS="hunter2,with,commas" \
    FTP_PORT=21 \
    bash "$ROOT_DIR/adapters/ftp.sh" "$F1_SRC" "remote/games/x" \
    >"$F1_LOG" 2>&1 || F1_RC=$?

if (( F1_RC == 0 )); then
    pass "F1 ftp adapter succeeded with lftp shim"
else
    fail "F1 ftp adapter rc=$F1_RC (expected 0)"
    sed 's/^/      /' "$F1_LOG"
fi

if [[ -f "$F1_STDIN" ]]; then
    # (a) Source path appears quoted inside the mirror command.
    if grep -qF "mirror -R --continue --verbose \"$F1_SRC\" \"/remote/games/x\"" "$F1_STDIN"; then
        pass "F1 mirror args are double-quoted (paths with spaces tokenise correctly)"
    else
        fail "F1 mirror args not quoted as expected"
        sed 's/^/      /' "$F1_STDIN"
    fi
    # (c) Creds live in `set ftp:default-...` form, double-quoted.
    if grep -qF 'set ftp:default-user "bob"' "$F1_STDIN"; then
        pass "F1 FTP_USER passed via set ftp:default-user"
    else
        fail "F1 missing set ftp:default-user line"
        sed 's/^/      /' "$F1_STDIN"
    fi
    if grep -qF 'set ftp:default-password "hunter2,with,commas"' "$F1_STDIN"; then
        pass "F1 FTP_PASS with commas passed intact via set ftp:default-password"
    else
        fail "F1 FTP_PASS either missing or mangled"
        sed 's/^/      /' "$F1_STDIN"
    fi
else
    fail "F1 lftp shim did not receive stdin"
fi

if [[ -f "$F1_ARGV" ]]; then
    # (b) No credentials on argv.
    if grep -q 'bob' "$F1_ARGV" || grep -q 'hunter2' "$F1_ARGV"; then
        fail "F1 credentials leaked to lftp argv: $(cat "$F1_ARGV")"
    else
        pass "F1 credentials absent from lftp argv"
    fi
else
    fail "F1 lftp shim did not capture argv"
fi

rm -rf "$F1_ROOT" "$F1_LOG"

# =============================================================================
# PR3 — precheck anchored matching (hdl + ftp + rclone)
# =============================================================================
#
# Substring matching in the precheck's destination probes caused false-
# positive skips: a probe for title "Zelda" matched a remote "Zelda II";
# a member "disc1" matched a remote "disc10"; and member "SLUS_200.71"
# matched "SLUS_200.710". Each adapter's precheck now anchors its match —
# hdl to end-of-line after a space, ftp/rclone to whole-line via grep -xF.
#
# All three scenarios use a tiny real archive (game1.7z, single member
# game1.iso) so the precheck's `7z l -slt` call gives a deterministic
# member list.

header "Test PR3: precheck anchored matching rejects false-positive prefix hits"

PR3_ARCHIVE="$FIXTURES_DIR/isos/game1.7z"
PR3_ROOT="/tmp/lp_unit_pr3_$$"
mkdir -p "$PR3_ROOT"

# ── PR3a: hdl_dump toc returns "Zelda II" but title is "Zelda" → must NOT skip
PR3A_BIN="$PR3_ROOT/hdl_dump_zelda2"
cat > "$PR3A_BIN" <<'SHIM'
#!/usr/bin/env bash
# Mimic the hdl_dump toc output format: title is the trailing whitespace-
# separated column. An installed "Zelda II" entry must not be mistaken for
# "Zelda" by the precheck.
if [[ "$1" == "toc" ]]; then
    cat <<'TOC'
type  size   name       title
----  -----  ---------  ----------
cd    700MB  PP.SLUS01  Zelda II
TOC
    exit 0
fi
exit 1
SHIM
chmod 0755 "$PR3A_BIN"

PR3A_RC=0
PR3A_LOG=$(mktemp)
env -u ALLOW_STUB_ADAPTERS \
    HDL_DUMP_BIN="$PR3A_BIN" HDL_INSTALL_TARGET="hdd0:" \
    bash "$ROOT_DIR/lib/precheck.sh" hdl "$PR3_ARCHIVE" "cd|Zelda" \
    >"$PR3A_LOG" 2>&1 || PR3A_RC=$?
# rc=1 means "not present, proceed" — the correct outcome now that "Zelda"
# no longer substring-matches "Zelda II".
if (( PR3A_RC == 1 )); then
    pass "PR3a hdl 'Zelda' does NOT match installed 'Zelda II' (rc=1 proceed)"
else
    fail "PR3a false skip: expected rc=1, got $PR3A_RC"
    sed 's/^/      /' "$PR3A_LOG"
fi

# Positive companion: exact title match must still cause a skip (rc=0).
PR3A2_BIN="$PR3_ROOT/hdl_dump_zelda"
cat > "$PR3A2_BIN" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "toc" ]]; then
    cat <<'TOC'
type  size   name       title
----  -----  ---------  -----
cd    700MB  PP.SLUS01  Zelda
TOC
    exit 0
fi
exit 1
SHIM
chmod 0755 "$PR3A2_BIN"

PR3A2_RC=0
env -u ALLOW_STUB_ADAPTERS \
    HDL_DUMP_BIN="$PR3A2_BIN" HDL_INSTALL_TARGET="hdd0:" \
    bash "$ROOT_DIR/lib/precheck.sh" hdl "$PR3_ARCHIVE" "cd|Zelda" \
    >/dev/null 2>&1 || PR3A2_RC=$?
if (( PR3A2_RC == 0 )); then
    pass "PR3a hdl exact 'Zelda' match still skips (rc=0)"
else
    fail "PR3a exact match regression: expected rc=0, got $PR3A2_RC"
fi

# ── PR3b: rclone lsf returns "game1.iso0" but archive has "game1.iso"
# → grep -xF must NOT treat it as a match; precheck should proceed.
PR3B_BIN="$PR3_ROOT/rclone_stub"
cat > "$PR3B_BIN" <<'SHIM'
#!/usr/bin/env bash
# rclone lsf emits one filename per line.
if [[ "$1" == "lsf" ]]; then
    printf 'game1.iso0\nsome_other_file\n'
    exit 0
fi
exit 0
SHIM
chmod 0755 "$PR3B_BIN"

PR3B_ROOT="$PR3_ROOT/rclone_path"
mkdir -p "$PR3B_ROOT"
ln -sf "$PR3B_BIN" "$PR3B_ROOT/rclone"

PR3B_RC=0
PR3B_LOG=$(mktemp)
env -u ALLOW_STUB_ADAPTERS \
    PATH="$PR3B_ROOT:$PATH" \
    RCLONE_REMOTE="test_remote" \
    bash "$ROOT_DIR/lib/precheck.sh" rclone "$PR3_ARCHIVE" "games/game1" \
    >"$PR3B_LOG" 2>&1 || PR3B_RC=$?
if (( PR3B_RC == 1 )); then
    pass "PR3b rclone 'game1.iso' does NOT match remote 'game1.iso0' (rc=1 proceed)"
else
    fail "PR3b false skip: expected rc=1, got $PR3B_RC"
    sed 's/^/      /' "$PR3B_LOG"
fi

# ── PR3c: curl --list-only returns "game1.iso.bak" but archive has
# "game1.iso" → must NOT substring-match; precheck should proceed.
PR3C_BIN="$PR3_ROOT/curl_stub"
cat > "$PR3C_BIN" <<'SHIM'
#!/usr/bin/env bash
# Mimic curl --list-only: emits one filename per line to stdout.
# This stub returns a superstring file — the real basename must not match.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list-only)
            printf 'game1.iso.bak\nREADME.txt\n'
            exit 0
            ;;
        *) shift ;;
    esac
done
exit 0
SHIM
chmod 0755 "$PR3C_BIN"

PR3C_ROOT="$PR3_ROOT/ftp_path"
mkdir -p "$PR3C_ROOT"
ln -sf "$PR3C_BIN" "$PR3C_ROOT/curl"

PR3C_RC=0
PR3C_LOG=$(mktemp)
env -u ALLOW_STUB_ADAPTERS \
    PATH="$PR3C_ROOT:$PATH" \
    FTP_HOST="ftp.example.test" FTP_USER="bob" FTP_PASS="x" \
    bash "$ROOT_DIR/lib/precheck.sh" ftp "$PR3_ARCHIVE" "games/game1" \
    >"$PR3C_LOG" 2>&1 || PR3C_RC=$?
if (( PR3C_RC == 1 )); then
    pass "PR3c ftp 'game1.iso' does NOT match remote 'game1.iso.bak' (rc=1 proceed)"
else
    fail "PR3c false skip: expected rc=1, got $PR3C_RC"
    sed 's/^/      /' "$PR3C_LOG"
fi

rm -rf "$PR3_ROOT" "$PR3A_LOG" "$PR3B_LOG" "$PR3C_LOG"
