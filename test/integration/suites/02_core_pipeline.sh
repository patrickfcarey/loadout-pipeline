#!/usr/bin/env bash
# test/integration/suites/02_core_pipeline.sh
#
# End-to-end happy-path runs on real substrates. Every scenario here
# drives bin/loadout-pipeline.sh against the real 256 MB tmpfs ($INT_EXTRACT)
# and the real loop-mounted vfat local volume ($INT_SD_VFAT), then verifies
# the output tree byte-for-byte against the decoded source tree.

# ─── helper: build a scenario-local jobs file ───────────────────────────────
_int_make_jobs() {
    local file="$1"; shift
    echo '---JOBS---' > "$file"
    while (( $# > 0 )); do
        echo "~$1~" >> "$file"
        shift
    done
    echo '---END---' >> "$file"
}

# ─── helper: extract archive members to an "expected" tree ─────────────────
_int_decode_expected() {
    local archive="$1" out="$2"
    mkdir -p "$out"
    ( cd "$out" && 7z x -y "$archive" >/dev/null )
}

# ─── Test 2: default run with three small archives ─────────────────────────

header "Int Test 2: default run (small + medium + multi → vfat SD)"

T2_JOBS="$INT_STATE/t2.jobs"
T2_EXTRACT="$INT_EXTRACT/t2"
rm -rf "$T2_EXTRACT"
mkdir -p "$T2_EXTRACT"

_int_make_jobs "$T2_JOBS" \
    "$INT_FIXTURES/small.7z|lvol|t2/small" \
    "$INT_FIXTURES/medium.7z|lvol|t2/medium" \
    "$INT_FIXTURES/multi.7z|lvol|t2/multi"

T2_LOG="$INT_STATE/t2.log"
set +e
EXTRACT_DIR="$T2_EXTRACT" QUEUE_DIR="$INT_QUEUE/t2" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T2_JOBS" >"$T2_LOG" 2>&1
t2_rc=$?
set -e

assert_rc "$t2_rc" 0 "Test 2 pipeline rc"

# Decode expected trees from the archives directly.
T2_EXP="$INT_STATE/t2_expected"
rm -rf "$T2_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$T2_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$T2_EXP/medium"
_int_decode_expected "$INT_FIXTURES/multi.7z"  "$T2_EXP/multi"

assert_tree_eq "$T2_EXP/small"  "$INT_SD_VFAT/t2/small"  "Test 2 small on vfat"
assert_tree_eq "$T2_EXP/medium" "$INT_SD_VFAT/t2/medium" "Test 2 medium on vfat"
assert_tree_eq "$T2_EXP/multi"  "$INT_SD_VFAT/t2/multi"  "Test 2 multi on vfat"

# ─── Test 3: serial extraction (MAX_UNZIP=1) ────────────────────────────────

header "Int Test 3: serial extraction on real substrate (MAX_UNZIP=1)"

T3_JOBS="$INT_STATE/t3.jobs"
T3_EXTRACT="$INT_EXTRACT/t3"
rm -rf "$T3_EXTRACT" "$INT_SD_VFAT/t3"
mkdir -p "$T3_EXTRACT"

_int_make_jobs "$T3_JOBS" \
    "$INT_FIXTURES/small.7z|lvol|t3/a" \
    "$INT_FIXTURES/small.7z|lvol|t3/b" \
    "$INT_FIXTURES/small.7z|lvol|t3/c"

set +e
MAX_UNZIP=1 \
EXTRACT_DIR="$T3_EXTRACT" QUEUE_DIR="$INT_QUEUE/t3" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T3_JOBS" >"$INT_STATE/t3.log" 2>&1
t3_rc=$?
set -e

assert_rc "$t3_rc" 0 "Test 3 pipeline rc"

T3_EXP="$INT_STATE/t3_expected"
rm -rf "$T3_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z" "$T3_EXP"
for sub in a b c; do
    assert_tree_eq "$T3_EXP" "$INT_SD_VFAT/t3/$sub" "Test 3 serial $sub on vfat"
done
rm -rf "$T3_EXP"

# ─── Test 4: more workers than jobs (MAX_UNZIP=5, 2 jobs) ──────────────────

header "Int Test 4: more workers than jobs on real substrate"

T4_JOBS="$INT_STATE/t4.jobs"
T4_EXTRACT="$INT_EXTRACT/t4"
rm -rf "$T4_EXTRACT" "$INT_SD_VFAT/t4"
mkdir -p "$T4_EXTRACT"

_int_make_jobs "$T4_JOBS" \
    "$INT_FIXTURES/small.7z|lvol|t4/a" \
    "$INT_FIXTURES/medium.7z|lvol|t4/b"

set +e
MAX_UNZIP=5 \
EXTRACT_DIR="$T4_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T4_JOBS" >"$INT_STATE/t4.log" 2>&1
t4_rc=$?
set -e

assert_rc "$t4_rc" 0 "Test 4 pipeline rc"
T4_EXP="$INT_STATE/t4_expected"
rm -rf "$T4_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$T4_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$T4_EXP/medium"
assert_tree_eq "$T4_EXP/small"  "$INT_SD_VFAT/t4/a" "Test 4 SD a on vfat"
assert_tree_eq "$T4_EXP/medium" "$INT_SD_VFAT/t4/b" "Test 4 SD b on vfat"
rm -rf "$T4_EXP"

# Queue must be fully drained after a successful run.
if [[ -d "$INT_QUEUE/t4" ]]; then
    leftover=$(find "$INT_QUEUE/t4" -maxdepth 3 \( -name "*.job" -o -name "*.claimed.*" \) 2>/dev/null | wc -l)
    if (( leftover == 0 )); then
        pass "Test 4 queue drained"
    else
        fail "Test 4 queue has $leftover leftover entries"
    fi
fi

# ─── Test 4b: directory profile (dir of *.jobs files) ──────────────────────
#
# Exercise full-directory profile support end-to-end against real substrates.
# Split the job set across two *.jobs files inside a directory and pass the
# directory path as the pipeline argument. All entries from all files must
# be processed exactly as if they had been concatenated into one file.

header "Int Test 4b: directory profile (dir passed instead of .jobs file)"

T4B_DIR="$INT_STATE/t4b_jobsdir"
T4B_EXTRACT="$INT_EXTRACT/t4b"
rm -rf "$T4B_DIR" "$T4B_EXTRACT" "$INT_SD_VFAT/t4b"
mkdir -p "$T4B_DIR" "$T4B_EXTRACT"

# Two halves of the job set in two separate files — both must be loaded.
_int_make_jobs "$T4B_DIR/a_small.jobs" \
    "$INT_FIXTURES/small.7z|lvol|t4b/small"
_int_make_jobs "$T4B_DIR/b_medium.jobs" \
    "$INT_FIXTURES/medium.7z|lvol|t4b/medium"
# A non-.jobs sibling must be ignored by the directory loader.
echo "ignored" > "$T4B_DIR/notes.txt"

set +e
EXTRACT_DIR="$T4B_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4b" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T4B_DIR" >"$INT_STATE/t4b.log" 2>&1
t4b_rc=$?
set -e

assert_rc "$t4b_rc" 0 "Test 4b pipeline rc (directory profile)"
T4B_EXP="$INT_STATE/t4b_expected"
rm -rf "$T4B_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$T4B_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$T4B_EXP/medium"
assert_tree_eq "$T4B_EXP/small"  "$INT_SD_VFAT/t4b/small"  "Test 4b SD small on vfat"
assert_tree_eq "$T4B_EXP/medium" "$INT_SD_VFAT/t4b/medium" "Test 4b SD medium on vfat"
rm -rf "$T4B_EXP"

# Negative: empty directory must fail load_jobs, not silently succeed.
T4B_EMPTY="$INT_STATE/t4b_empty"
rm -rf "$T4B_EMPTY"; mkdir -p "$T4B_EMPTY"
set +e
EXTRACT_DIR="$T4B_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4b_empty" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T4B_EMPTY" >"$INT_STATE/t4b_empty.log" 2>&1
t4b_empty_rc=$?
set -e
if (( t4b_empty_rc != 0 )); then
    pass "Test 4b empty directory profile rejected"
else
    fail "Test 4b empty directory profile was NOT rejected"
fi

# ─── Test 4c: single-directory wrapper flatten (extract stage) ─────────────
#
# Exercises the wrapper-flatten path in lib/extract.sh end-to-end against
# the real vfat SD substrate. Three scenarios packed into one scenario:
#
#   wrapper_ok.7z     — "MyGame/wrapper_ok.iso" wrapper → flatten → iso lands
#                       at the top level of the dispatch destination.
#   wrapper_strip.7z  — "MyGame/wrapper_strip.iso" + top-level Vimm's Lair.txt
#                       → pre-flatten strip removes the .txt, flatten lifts
#                       the iso. Tests strip-before-flatten ordering.
#   wrapper_ambig.7z  — "MyGame/wrapper_ambig.iso" + top-level unrelated.dat
#                       → ambiguity: flatten must refuse, this job must fail,
#                       but the two good jobs on the same run must still
#                       dispatch. Tests the fail-and-continue contract.

header "Int Test 4c: wrapper-directory flatten on real substrate"

T4C_JOBS="$INT_STATE/t4c.jobs"
T4C_EXTRACT="$INT_EXTRACT/t4c"
rm -rf "$T4C_EXTRACT" "$INT_SD_VFAT/t4c"
mkdir -p "$T4C_EXTRACT"

_int_make_jobs "$T4C_JOBS" \
    "$INT_FIXTURES/wrapper_ok.7z|lvol|t4c/ok" \
    "$INT_FIXTURES/wrapper_strip.7z|lvol|t4c/strip" \
    "$INT_FIXTURES/wrapper_ambig.7z|lvol|t4c/ambig"

T4C_LOG="$INT_STATE/t4c.log"
set +e
EXTRACT_DIR="$T4C_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4c" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$T4C_JOBS" >"$T4C_LOG" 2>&1
t4c_rc=$?
set -e

# Overall rc must be non-zero because wrapper_ambig fails permanently.
if (( t4c_rc != 0 )); then
    pass "Test 4c pipeline reported failure for ambiguous wrapper (rc=$t4c_rc)"
else
    fail "Test 4c pipeline returned 0 despite ambiguous wrapper job"
fi

# wrapper_ok: iso must land at top level of the dispatch dir, and the
# "MyGame" wrapper name must NOT appear on disk anywhere beneath it.
T4C_EXP="$INT_STATE/t4c_expected"
rm -rf "$T4C_EXP"
_int_decode_expected "$INT_FIXTURES/wrapper_ok.7z" "$T4C_EXP/ok"
assert_file_eq "$T4C_EXP/ok/MyGame/wrapper_ok.iso" \
    "$INT_SD_VFAT/t4c/ok/wrapper_ok.iso" \
    "Test 4c wrapper_ok byte-exact on vfat"
if [[ ! -e "$INT_SD_VFAT/t4c/ok/MyGame" ]]; then
    pass "Test 4c wrapper_ok: 'MyGame' wrapper dir absent under dispatch tree"
else
    fail "Test 4c wrapper_ok: 'MyGame' wrapper dir still present"
fi

# wrapper_strip: iso present, Vimm's Lair.txt absent (strip-before-flatten).
_int_decode_expected "$INT_FIXTURES/wrapper_strip.7z" "$T4C_EXP/strip"
assert_file_eq "$T4C_EXP/strip/MyGame/wrapper_strip.iso" \
    "$INT_SD_VFAT/t4c/strip/wrapper_strip.iso" \
    "Test 4c wrapper_strip byte-exact on vfat"
rm -rf "$T4C_EXP"
if [[ ! -e "$INT_SD_VFAT/t4c/strip/Vimm's Lair.txt" ]]; then
    pass "Test 4c wrapper_strip: strip-list file removed pre-flatten"
else
    fail "Test 4c wrapper_strip: Vimm's Lair.txt leaked to dispatch destination"
fi

# wrapper_ambig: NOTHING at the destination, and a flatten error in the log.
if [[ ! -e "$INT_SD_VFAT/t4c/ambig" ]]; then
    pass "Test 4c wrapper_ambig: ambiguous job did NOT dispatch"
else
    fail "Test 4c wrapper_ambig: unexpected content at $INT_SD_VFAT/t4c/ambig"
fi
if grep -F "cannot flatten wrapper for 'wrapper_ambig'" "$T4C_LOG" >/dev/null; then
    pass "Test 4c wrapper_ambig: flatten error logged"
else
    fail "Test 4c wrapper_ambig: expected flatten error in pipeline log"
fi

# ─── Test 4d: custom QUEUE_DIR override ──────────────────────────────────

header "Int Test 4d: custom QUEUE_DIR override on real substrate"

T4D_QUEUE="$INT_STATE/t4d_queue"
T4D_EXTRACT="$INT_EXTRACT/t4d"
rm -rf "$T4D_QUEUE" "$T4D_EXTRACT" "$INT_SD_VFAT/t4d"
mkdir -p "$T4D_EXTRACT"

_int_make_jobs "$INT_STATE/t4d.jobs" \
    "$INT_FIXTURES/small.7z|lvol|t4d/a" \
    "$INT_FIXTURES/medium.7z|lvol|t4d/b"

set +e
EXTRACT_DIR="$T4D_EXTRACT" QUEUE_DIR="$T4D_QUEUE" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$INT_STATE/t4d.jobs" >"$INT_STATE/t4d.log" 2>&1
t4d_rc=$?
set -e

assert_rc "$t4d_rc" 0 "Test 4d pipeline rc"

T4D_EXP="$INT_STATE/t4d_expected"
rm -rf "$T4D_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$T4D_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$T4D_EXP/medium"
assert_tree_eq "$T4D_EXP/small"  "$INT_SD_VFAT/t4d/a" "Test 4d SD a on vfat"
assert_tree_eq "$T4D_EXP/medium" "$INT_SD_VFAT/t4d/b" "Test 4d SD b on vfat"
rm -rf "$T4D_EXP"

assert_queue_empty "$T4D_QUEUE/extract"  "Test 4d custom extract queue"
assert_queue_empty "$T4D_QUEUE/dispatch" "Test 4d custom dispatch queue"
if [[ ! -d "$INT_QUEUE/t4d" ]]; then
    pass "Test 4d default queue path not created"
else
    fail "Test 4d default queue path $INT_QUEUE/t4d exists (override ignored)"
fi

# ─── Test 4e: idempotent re-run on vfat ──────────────────────────────────

header "Int Test 4e: idempotent re-run on real vfat substrate"

T4E_EXTRACT="$INT_EXTRACT/t4e"
rm -rf "$T4E_EXTRACT" "$INT_SD_VFAT/t4e"
mkdir -p "$T4E_EXTRACT"

_int_make_jobs "$INT_STATE/t4e.jobs" \
    "$INT_FIXTURES/small.7z|lvol|t4e/a" \
    "$INT_FIXTURES/medium.7z|lvol|t4e/b"

set +e
EXTRACT_DIR="$T4E_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4e" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$INT_STATE/t4e.jobs" >"$INT_STATE/t4e_run1.log" 2>&1
t4e_run1_rc=$?
set -e

assert_rc "$t4e_run1_rc" 0 "Test 4e run 1 pipeline rc"

T4E_EXP="$INT_STATE/t4e_expected"
rm -rf "$T4E_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$T4E_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$T4E_EXP/medium"
assert_tree_eq "$T4E_EXP/small"  "$INT_SD_VFAT/t4e/a" "Test 4e run 1 SD a"
assert_tree_eq "$T4E_EXP/medium" "$INT_SD_VFAT/t4e/b" "Test 4e run 1 SD b"

t4e_mtime_a=$(stat -c '%Y' "$INT_SD_VFAT/t4e/a/small.iso")
t4e_mtime_b=$(stat -c '%Y' "$INT_SD_VFAT/t4e/b/medium.iso")

# vfat mtime granularity is 2s — sleep past it so any rewrite is visible.
sleep 3

set +e
EXTRACT_DIR="$T4E_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4e" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
RESUME_PLANNER_IND=0 \
bash "$PIPELINE" "$INT_STATE/t4e.jobs" >"$INT_STATE/t4e_run2.log" 2>&1
t4e_run2_rc=$?
set -e

assert_rc "$t4e_run2_rc" 0 "Test 4e run 2 pipeline rc"
assert_tree_eq "$T4E_EXP/small"  "$INT_SD_VFAT/t4e/a" "Test 4e run 2 SD a intact"
assert_tree_eq "$T4E_EXP/medium" "$INT_SD_VFAT/t4e/b" "Test 4e run 2 SD b intact"
rm -rf "$T4E_EXP"

assert_mtime_unchanged "$INT_SD_VFAT/t4e/a/small.iso"  "$t4e_mtime_a" "Test 4e mtime a"
assert_mtime_unchanged "$INT_SD_VFAT/t4e/b/medium.iso" "$t4e_mtime_b" "Test 4e mtime b"

if grep -qF '[skip]' "$INT_STATE/t4e_run2.log"; then
    pass "Test 4e run 2 logged [skip]"
else
    fail "Test 4e run 2 did not log [skip]"
fi

# ─── Test 4f: custom EXTRACT_DIR override ────────────────────────────────

header "Int Test 4f: custom EXTRACT_DIR override on real substrate"

T4F_EXTRACT="$INT_EXTRACT/t4f_custom"
rm -rf "$T4F_EXTRACT" "$INT_SD_VFAT/t4f"
mkdir -p "$T4F_EXTRACT"

_int_make_jobs "$INT_STATE/t4f.jobs" \
    "$INT_FIXTURES/small.7z|lvol|t4f/a" \
    "$INT_FIXTURES/medium.7z|lvol|t4f/b"

set +e
EXTRACT_DIR="$T4F_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4f" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$INT_STATE/t4f.jobs" >"$INT_STATE/t4f.log" 2>&1
t4f_rc=$?
set -e

assert_rc "$t4f_rc" 0 "Test 4f pipeline rc"

T4F_EXP="$INT_STATE/t4f_expected"
rm -rf "$T4F_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$T4F_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$T4F_EXP/medium"
assert_tree_eq "$T4F_EXP/small"  "$INT_SD_VFAT/t4f/a" "Test 4f SD a on vfat"
assert_tree_eq "$T4F_EXP/medium" "$INT_SD_VFAT/t4f/b" "Test 4f SD b on vfat"
rm -rf "$T4F_EXP"

if [[ ! -d "$INT_EXTRACT/t4f" ]]; then
    pass "Test 4f default extract path not created"
else
    fail "Test 4f default extract path $INT_EXTRACT/t4f exists (override ignored)"
fi

# ─── Test 4g: wrapper flatten — inner strip + two-dir ambiguity ──────────
#
# Two additional wrapper-flatten scenarios not covered by Test 4c:
#   wrapper_inner_strip.7z — strip-list file is INSIDE the wrapper dir
#   wrapper_two_dirs.7z    — two top-level directories (ambiguous)

header "Int Test 4g: wrapper flatten — inner strip + two-dir ambiguity"

T4G_EXTRACT="$INT_EXTRACT/t4g"
rm -rf "$T4G_EXTRACT" "$INT_SD_VFAT/t4g"
mkdir -p "$T4G_EXTRACT"

_int_make_jobs "$INT_STATE/t4g.jobs" \
    "$INT_FIXTURES/wrapper_inner_strip.7z|lvol|t4g/inner" \
    "$INT_FIXTURES/wrapper_two_dirs.7z|lvol|t4g/twodirs"

T4G_LOG="$INT_STATE/t4g.log"
set +e
EXTRACT_DIR="$T4G_EXTRACT" QUEUE_DIR="$INT_QUEUE/t4g" \
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$PIPELINE" "$INT_STATE/t4g.jobs" >"$T4G_LOG" 2>&1
t4g_rc=$?
set -e

# Overall rc must be non-zero because wrapper_two_dirs fails permanently.
if (( t4g_rc != 0 )); then
    pass "Test 4g pipeline reported failure for two-dir wrapper (rc=$t4g_rc)"
else
    fail "Test 4g pipeline returned 0 despite ambiguous two-dir wrapper"
fi

# wrapper_inner_strip: iso at top level, strip-list file gone, wrapper gone.
T4G_EXP="$INT_STATE/t4g_expected"
rm -rf "$T4G_EXP"
_int_decode_expected "$INT_FIXTURES/wrapper_inner_strip.7z" "$T4G_EXP/inner"
assert_file_eq "$T4G_EXP/inner/MyGame/wrapper_inner_strip.iso" \
    "$INT_SD_VFAT/t4g/inner/wrapper_inner_strip.iso" \
    "Test 4g inner_strip byte-exact on vfat"
rm -rf "$T4G_EXP"
if [[ ! -e "$INT_SD_VFAT/t4g/inner/Vimm's Lair.txt" ]]; then
    pass "Test 4g inner_strip: strip-list file removed post-flatten"
else
    fail "Test 4g inner_strip: Vimm's Lair.txt leaked to dispatch destination"
fi
if [[ ! -e "$INT_SD_VFAT/t4g/inner/MyGame" ]]; then
    pass "Test 4g inner_strip: wrapper dir absent"
else
    fail "Test 4g inner_strip: MyGame wrapper dir still present"
fi

# wrapper_two_dirs: nothing dispatched, flatten error in log.
if [[ ! -e "$INT_SD_VFAT/t4g/twodirs" ]]; then
    pass "Test 4g two_dirs: ambiguous job did NOT dispatch"
else
    fail "Test 4g two_dirs: unexpected content at $INT_SD_VFAT/t4g/twodirs"
fi
if grep -F "cannot flatten wrapper for 'wrapper_two_dirs'" "$T4G_LOG" >/dev/null; then
    pass "Test 4g two_dirs: flatten error logged"
else
    fail "Test 4g two_dirs: expected flatten error in pipeline log"
fi
