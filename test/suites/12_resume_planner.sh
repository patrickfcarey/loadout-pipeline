#!/usr/bin/env bash
# test/suites/12_resume_planner.sh
#
# Resume planner (lib/resume_planner.sh) pre-pass behaviour.
#
# The planner runs once, synchronously, between _pipeline_run_init and the
# JOBS enqueue loop in workers_start(). Its job is to drop every job whose
# content is already fully present at the adapter destination before any
# worker forks — making cold restarts after a power outage fast without
# sacrificing accuracy.
#
# Scenarios:
#   12A  fully satisfied sd job is dropped; sibling job still runs
#   12B  cold run with empty destinations — planner keeps everything
#   12C  partial satisfaction (one of two multi-file members missing) — kept
#   12D  strip-list member absent at dest does NOT force re-processing
#   12E  RESUME_PLANNER_IND=0 bypasses the planner; precheck still skips
#   12F  non-sd (stub) adapters are always kept regardless of state
#   12G  destination that resolves outside LVOL_MOUNT_POINT is refused

_rp_common_reset() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir"
}

# ── Test 12A: planner drops a fully-satisfied sd job ──────────────────────────
header "Test 12A: resume planner drops fully-satisfied sd job"
RP12A_SD="/tmp/iso_pipeline_test_rp12a_sd_$$"
RP12A_EXTRACT="/tmp/iso_pipeline_test_rp12a_extract_$$"
RP12A_QUEUE="/tmp/iso_pipeline_test_rp12a_queue_$$"
RP12A_JOBS="/tmp/iso_pipeline_test_rp12a_$$.jobs"
RP12A_LOG="/tmp/iso_pipeline_test_rp12a_$$.log"
_rp_common_reset "$RP12A_SD/a/1"
mkdir -p "$RP12A_SD/a/2"
# Pre-populate dest for game1 with the exact member the archive contains.
printf 'prepopulated game1 iso\n' > "$RP12A_SD/a/1/game1.iso"
{
    echo "---JOBS---"
    echo "~$ROOT_DIR/test/fixtures/isos/game1.7z|lvol|a/1~"
    echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|lvol|a/2~"
    echo "---END---"
} > "$RP12A_JOBS"
echo "  cmd: LVOL_MOUNT_POINT=$RP12A_SD EXTRACT_DIR=$RP12A_EXTRACT bash bin/loadout-pipeline.sh $RP12A_JOBS"
LVOL_MOUNT_POINT="$RP12A_SD" EXTRACT_DIR="$RP12A_EXTRACT" QUEUE_DIR="$RP12A_QUEUE" \
    bash "$PIPELINE" "$RP12A_JOBS" >"$RP12A_LOG" 2>&1

if grep -E 'resume planner: 1 of 2 already satisfied' "$RP12A_LOG" >/dev/null; then
    pass "12A planner reported 1 of 2 satisfied"
else
    fail "12A expected 'resume planner: 1 of 2 already satisfied' in log"
    sed 's/^/      /' "$RP12A_LOG"
fi
# game1 was dropped by the planner — it must NOT produce a [skip] log line
# (that would mean precheck ran, which only happens on survivors).
if grep -E '^\[skip\].*game1\.7z' "$RP12A_LOG" >/dev/null; then
    fail "12A [skip] log present for game1 — planner did not remove it"
else
    pass "12A planner removed game1 before precheck"
fi
if [[ ! -e "$RP12A_EXTRACT/game1" ]]; then
    pass "12A game1 was not extracted"
else
    fail "12A game1 extract dir unexpectedly present"
fi
if [[ -f "$RP12A_EXTRACT/game2/game2.iso" ]]; then
    pass "12A game2 extracted normally"
else
    fail "12A game2 missing from $RP12A_EXTRACT/game2/"
fi
rm -rf "$RP12A_SD" "$RP12A_EXTRACT" "$RP12A_QUEUE" "$RP12A_JOBS" "$RP12A_LOG"

# ── Test 12B: cold run — planner keeps everything ────────────────────────────
header "Test 12B: resume planner cold run keeps all jobs"
RP12B_SD="/tmp/iso_pipeline_test_rp12b_sd_$$"
RP12B_EXTRACT="/tmp/iso_pipeline_test_rp12b_extract_$$"
RP12B_QUEUE="/tmp/iso_pipeline_test_rp12b_queue_$$"
RP12B_JOBS="/tmp/iso_pipeline_test_rp12b_$$.jobs"
RP12B_LOG="/tmp/iso_pipeline_test_rp12b_$$.log"
_rp_common_reset "$RP12B_SD"
{
    echo "---JOBS---"
    echo "~$ROOT_DIR/test/fixtures/isos/game1.7z|lvol|b/1~"
    echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|lvol|b/2~"
    echo "---END---"
} > "$RP12B_JOBS"
echo "  cmd: LVOL_MOUNT_POINT=$RP12B_SD EXTRACT_DIR=$RP12B_EXTRACT bash bin/loadout-pipeline.sh $RP12B_JOBS"
LVOL_MOUNT_POINT="$RP12B_SD" EXTRACT_DIR="$RP12B_EXTRACT" QUEUE_DIR="$RP12B_QUEUE" \
    bash "$PIPELINE" "$RP12B_JOBS" >"$RP12B_LOG" 2>&1

if grep -E 'resume planner: 0 of 2 already satisfied' "$RP12B_LOG" >/dev/null; then
    pass "12B planner reported 0 of 2 satisfied on cold run"
else
    fail "12B expected 'resume planner: 0 of 2 already satisfied' in log"
    sed 's/^/      /' "$RP12B_LOG"
fi
if [[ -f "$RP12B_EXTRACT/game1/game1.iso" && -f "$RP12B_EXTRACT/game2/game2.iso" ]]; then
    pass "12B both jobs extracted after cold planner pass"
else
    fail "12B expected both extracts to complete"
fi
rm -rf "$RP12B_SD" "$RP12B_EXTRACT" "$RP12B_QUEUE" "$RP12B_JOBS" "$RP12B_LOG"

# ── Test 12C: partial satisfaction keeps the job ─────────────────────────────
header "Test 12C: resume planner keeps partially-satisfied multi-file job"
RP12C_SD="/tmp/iso_pipeline_test_rp12c_sd_$$"
RP12C_EXTRACT="/tmp/iso_pipeline_test_rp12c_extract_$$"
RP12C_QUEUE="/tmp/iso_pipeline_test_rp12c_queue_$$"
RP12C_JOBS="/tmp/iso_pipeline_test_rp12c_$$.jobs"
RP12C_LOG="/tmp/iso_pipeline_test_rp12c_$$.log"
mkdir -p "$RP12C_SD/c/multi"
# Only game4.bin is present; game4.cue is missing. Archive is not satisfied.
printf 'only bin present\n' > "$RP12C_SD/c/multi/game4.bin"
{ echo '---JOBS---'; echo "~$ROOT_DIR/test/fixtures/isos/game4.7z|lvol|c/multi~"; echo '---END---'; } > "$RP12C_JOBS"
echo "  cmd: LVOL_MOUNT_POINT=$RP12C_SD EXTRACT_DIR=$RP12C_EXTRACT bash bin/loadout-pipeline.sh $RP12C_JOBS"
LVOL_MOUNT_POINT="$RP12C_SD" EXTRACT_DIR="$RP12C_EXTRACT" QUEUE_DIR="$RP12C_QUEUE" \
    bash "$PIPELINE" "$RP12C_JOBS" >"$RP12C_LOG" 2>&1

if grep -E 'resume planner: 0 of 1 already satisfied' "$RP12C_LOG" >/dev/null; then
    pass "12C planner kept the partially-satisfied job"
else
    fail "12C expected 'resume planner: 0 of 1 already satisfied' in log"
    sed 's/^/      /' "$RP12C_LOG"
fi
if [[ -f "$RP12C_EXTRACT/game4/game4.bin" && -f "$RP12C_EXTRACT/game4/game4.cue" ]]; then
    pass "12C game4 re-extracted in full"
else
    fail "12C game4 not fully re-extracted after partial-hit"
fi
rm -rf "$RP12C_SD" "$RP12C_EXTRACT" "$RP12C_QUEUE" "$RP12C_JOBS" "$RP12C_LOG"

# ── Test 12D: strip-list parity — strip-list member absent ≠ unsatisfied ─────
header "Test 12D: resume planner treats strip-list members as absent-ok"
RP12D_WORK="/tmp/iso_pipeline_test_rp12d_$$"
RP12D_SD="$RP12D_WORK/sd"
RP12D_EXTRACT="$RP12D_WORK/extract"
RP12D_QUEUE="$RP12D_WORK/queue"
RP12D_JOBS="$RP12D_WORK/rp12d.jobs"
RP12D_LOG="$RP12D_WORK/rp12d.log"
RP12D_SRC="$RP12D_WORK/src"
RP12D_ARCHIVE="$RP12D_WORK/with_strip.7z"
mkdir -p "$RP12D_SD/d" "$RP12D_EXTRACT" "$RP12D_SRC"
# Build a fresh archive containing the strip-list target alongside real payload.
printf 'real payload iso\n'      > "$RP12D_SRC/with_strip.iso"
printf 'metadata scraped stuff\n' > "$RP12D_SRC/Vimm's Lair.txt"
( cd "$RP12D_SRC" && 7z a "$RP12D_ARCHIVE" ./* >/dev/null )
# Pre-populate dest with ONLY the real payload. The planner must recognise
# "Vimm's Lair.txt" as strip-listed and count the job as fully satisfied.
printf 'real payload iso\n' > "$RP12D_SD/d/with_strip.iso"
{ echo '---JOBS---'; echo "~$RP12D_ARCHIVE|lvol|d~"; echo '---END---'; } > "$RP12D_JOBS"
echo "  cmd: LVOL_MOUNT_POINT=$RP12D_SD EXTRACT_DIR=$RP12D_EXTRACT bash bin/loadout-pipeline.sh $RP12D_JOBS"
LVOL_MOUNT_POINT="$RP12D_SD" EXTRACT_DIR="$RP12D_EXTRACT" QUEUE_DIR="$RP12D_QUEUE" \
    bash "$PIPELINE" "$RP12D_JOBS" >"$RP12D_LOG" 2>&1

if grep -E 'resume planner: 1 of 1 already satisfied' "$RP12D_LOG" >/dev/null; then
    pass "12D planner ignored strip-listed member during presence check"
else
    fail "12D expected 'resume planner: 1 of 1 already satisfied' in log"
    sed 's/^/      /' "$RP12D_LOG"
fi
if [[ ! -e "$RP12D_EXTRACT/with_strip" ]]; then
    pass "12D extract did not run (job was dropped by planner)"
else
    fail "12D extract dir unexpectedly present"
fi
rm -rf "$RP12D_WORK"

# ── Test 12E: disable switch bypasses planner, precheck still skips ──────────
header "Test 12E: RESUME_PLANNER_IND=0 bypasses planner"
RP12E_SD="/tmp/iso_pipeline_test_rp12e_sd_$$"
RP12E_EXTRACT="/tmp/iso_pipeline_test_rp12e_extract_$$"
RP12E_QUEUE="/tmp/iso_pipeline_test_rp12e_queue_$$"
RP12E_JOBS="/tmp/iso_pipeline_test_rp12e_$$.jobs"
RP12E_LOG="/tmp/iso_pipeline_test_rp12e_$$.log"
mkdir -p "$RP12E_SD/e/1" "$RP12E_SD/e/2"
printf 'prepopulated game1 iso\n' > "$RP12E_SD/e/1/game1.iso"
{
    echo "---JOBS---"
    echo "~$ROOT_DIR/test/fixtures/isos/game1.7z|lvol|e/1~"
    echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|lvol|e/2~"
    echo "---END---"
} > "$RP12E_JOBS"
echo "  cmd: RESUME_PLANNER_IND=0 LVOL_MOUNT_POINT=$RP12E_SD bash bin/loadout-pipeline.sh $RP12E_JOBS"
RESUME_PLANNER_IND=0 LVOL_MOUNT_POINT="$RP12E_SD" EXTRACT_DIR="$RP12E_EXTRACT" QUEUE_DIR="$RP12E_QUEUE" \
    bash "$PIPELINE" "$RP12E_JOBS" >"$RP12E_LOG" 2>&1

if grep -E 'resume planner: disabled' "$RP12E_LOG" >/dev/null; then
    pass "12E planner logged disabled state"
else
    fail "12E expected 'resume planner: disabled' in log"
    sed 's/^/      /' "$RP12E_LOG"
fi
# Because the planner did NOT drop game1, the precheck path still fires and
# must emit its [skip] line — the disable switch must not break downstream skipping.
if grep -E '^\[skip\].*game1\.7z.*already exists at destination' "$RP12E_LOG" >/dev/null; then
    pass "12E precheck still skipped game1 via the legacy path"
else
    fail "12E expected [skip] log line for game1 from precheck"
    sed 's/^/      /' "$RP12E_LOG"
fi
if [[ -f "$RP12E_EXTRACT/game2/game2.iso" ]]; then
    pass "12E game2 extracted normally with planner disabled"
else
    fail "12E game2 missing from $RP12E_EXTRACT/game2/"
fi
rm -rf "$RP12E_SD" "$RP12E_EXTRACT" "$RP12E_QUEUE" "$RP12E_JOBS" "$RP12E_LOG"

# ── Test 12F: non-lvol adapters untouched by planner ────────────────────────
header "Test 12F: resume planner keeps non-lvol adapters"
RP12F_EXTRACT="/tmp/iso_pipeline_test_rp12f_extract_$$"
RP12F_QUEUE="/tmp/iso_pipeline_test_rp12f_queue_$$"
RP12F_JOBS="/tmp/iso_pipeline_test_rp12f_$$.jobs"
RP12F_LOG="/tmp/iso_pipeline_test_rp12f_$$.log"
{
    echo "---JOBS---"
    echo "~$ROOT_DIR/test/fixtures/isos/game1.7z|ftp|/remote/rp12f/game1~"
    echo "~$ROOT_DIR/test/fixtures/isos/game2.7z|hdl|dvd|Game2~"
    echo "---END---"
} > "$RP12F_JOBS"
echo "  cmd: EXTRACT_DIR=$RP12F_EXTRACT bash bin/loadout-pipeline.sh $RP12F_JOBS"
EXTRACT_DIR="$RP12F_EXTRACT" QUEUE_DIR="$RP12F_QUEUE" \
    bash "$PIPELINE" "$RP12F_JOBS" >"$RP12F_LOG" 2>&1

if grep -E 'resume planner: 0 of 2 already satisfied' "$RP12F_LOG" >/dev/null; then
    pass "12F planner reported 0 of 2 satisfied for non-lvol adapters"
else
    fail "12F expected 'resume planner: 0 of 2 already satisfied' in log"
    sed 's/^/      /' "$RP12F_LOG"
fi
if [[ -f "$RP12F_EXTRACT/game1/game1.iso" && -f "$RP12F_EXTRACT/game2/game2.iso" ]]; then
    pass "12F both non-lvol adapter jobs extracted normally"
else
    fail "12F expected both extracts to complete"
fi
rm -rf "$RP12F_EXTRACT" "$RP12F_QUEUE" "$RP12F_JOBS" "$RP12F_LOG"

# ── Test 12G: destination escape (via symlink) is refused ────────────────────
#
# load_jobs rejects literal '..' in the dest field, so the only way to exercise
# the planner's containment guard end-to-end is to set up a symlink under
# LVOL_MOUNT_POINT that resolves outside it. The planner must refuse to plan
# (emit a [WARN]) and keep the job; precheck then issues the authoritative
# exit-2 refusal and the pipeline overall returns non-zero.
header "Test 12G: resume planner refuses dest that escapes LVOL_MOUNT_POINT"
RP12G_WORK="/tmp/iso_pipeline_test_rp12g_$$"
RP12G_SD="$RP12G_WORK/sd"
RP12G_OUT="$RP12G_WORK/outside"
RP12G_EXTRACT="$RP12G_WORK/extract"
RP12G_QUEUE="$RP12G_WORK/queue"
RP12G_JOBS="$RP12G_WORK/rp12g.jobs"
RP12G_LOG="$RP12G_WORK/rp12g.log"
mkdir -p "$RP12G_SD" "$RP12G_OUT" "$RP12G_EXTRACT"
# Symlink escape_link points outside LVOL_MOUNT_POINT. A dest of
# "escape_link/target" resolves to "$RP12G_OUT/target" and fails containment.
ln -s "$RP12G_OUT" "$RP12G_SD/escape_link"
{ echo '---JOBS---'; echo "~$ROOT_DIR/test/fixtures/isos/game1.7z|lvol|escape_link/target~"; echo '---END---'; } > "$RP12G_JOBS"
echo "  cmd: LVOL_MOUNT_POINT=$RP12G_SD EXTRACT_DIR=$RP12G_EXTRACT bash bin/loadout-pipeline.sh $RP12G_JOBS"
set +e
LVOL_MOUNT_POINT="$RP12G_SD" EXTRACT_DIR="$RP12G_EXTRACT" QUEUE_DIR="$RP12G_QUEUE" \
    bash "$PIPELINE" "$RP12G_JOBS" >"$RP12G_LOG" 2>&1
rp12g_rc=$?
set -e

if grep -F 'resume planner: refusing to plan' "$RP12G_LOG" >/dev/null; then
    pass "12G planner refused to plan the escaping destination"
else
    fail "12G expected planner warning about refusing to plan"
    sed 's/^/      /' "$RP12G_LOG"
fi
if grep -E 'precheck: destination escapes LVOL_MOUNT_POINT' "$RP12G_LOG" >/dev/null; then
    pass "12G precheck rejected the escaping destination"
else
    fail "12G expected precheck containment rejection in log"
    sed 's/^/      /' "$RP12G_LOG"
fi
if (( rp12g_rc != 0 )); then
    pass "12G pipeline returned non-zero for escaping destination (rc=$rp12g_rc)"
else
    fail "12G pipeline returned 0 despite escaping destination"
fi
rm -rf "$RP12G_WORK"

unset -f _rp_common_reset
