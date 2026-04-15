#!/usr/bin/env bash
# test/suites/11_wrapper_flatten.sh
#
# Wrapper-directory flatten behaviour in lib/extract.sh.
#
# Some 7z archives store their payload under a single top-level directory
# ("MyGame/game.iso" instead of "game.iso"). After extraction, extract.sh
# must lift the wrapper's contents up one level so dispatch sees the payload
# directly in $out_dir — matching the layout produced by archives that
# already stored their payload at the top level.
#
# Cases covered:
#   WF1  pure single-directory wrapper         → flatten, dispatch OK
#   WF2  wrapper + strip-list file at top      → strip removes cruft,
#                                                then flatten, dispatch OK
#   WF3  wrapper containing strip-list file    → flatten, post-flatten strip
#                                                removes the inner cruft
#   WF4  wrapper + unrelated loose file at top → ambiguous, job skipped,
#                                                sibling job still succeeds
#   WF5  two top-level directories             → ambiguous, job skipped,
#                                                sibling job still succeeds

header "Test 22: wrapper-directory flatten (extract stage)"

WF_WORK="/tmp/iso_pipeline_test_wf_$$"
WF_SRC="$WF_WORK/src"
WF_ISO="$WF_WORK/isos"
WF_EXTRACT="$WF_WORK/extract"
WF_SD="$WF_WORK/sd"
WF_JOBS="$WF_WORK/wf.jobs"
WF_LOG="$WF_WORK/wf.log"
mkdir -p "$WF_SRC" "$WF_ISO" "$WF_EXTRACT" "$WF_SD"

# ── WF1: pure single-directory wrapper ───────────────────────────────────
mkdir -p "$WF_SRC/wf1/MyGame1"
printf 'wf1 iso\n' > "$WF_SRC/wf1/MyGame1/game1.iso"
( cd "$WF_SRC/wf1" && 7z a "$WF_ISO/wf1.7z" ./* >/dev/null )

# ── WF2: wrapper + strip-list file (Vimm's Lair.txt) at top level ────────
mkdir -p "$WF_SRC/wf2/MyGame2"
printf 'wf2 iso\n' > "$WF_SRC/wf2/MyGame2/game2.iso"
printf 'scraped metadata\n' > "$WF_SRC/wf2/Vimm's Lair.txt"
( cd "$WF_SRC/wf2" && 7z a "$WF_ISO/wf2.7z" ./* >/dev/null )

# ── WF3: wrapper containing strip-list file INSIDE it ────────────────────
mkdir -p "$WF_SRC/wf3/MyGame3"
printf 'wf3 iso\n' > "$WF_SRC/wf3/MyGame3/game3.iso"
printf 'inner metadata\n' > "$WF_SRC/wf3/MyGame3/Vimm's Lair.txt"
( cd "$WF_SRC/wf3" && 7z a "$WF_ISO/wf3.7z" ./* >/dev/null )

# ── WF4: wrapper + unrelated loose file (NOT on strip list) ──────────────
mkdir -p "$WF_SRC/wf4/MyGame4"
printf 'wf4 iso\n' > "$WF_SRC/wf4/MyGame4/game4.iso"
printf 'unknown sibling\n' > "$WF_SRC/wf4/unknown.dat"
( cd "$WF_SRC/wf4" && 7z a "$WF_ISO/wf4.7z" ./* >/dev/null )

# ── WF5: two top-level directories (ambiguous) ───────────────────────────
mkdir -p "$WF_SRC/wf5/DirA" "$WF_SRC/wf5/DirB"
printf 'wf5 A\n' > "$WF_SRC/wf5/DirA/a.iso"
printf 'wf5 B\n' > "$WF_SRC/wf5/DirB/b.iso"
( cd "$WF_SRC/wf5" && 7z a "$WF_ISO/wf5.7z" ./* >/dev/null )

# Build a jobs file with all five wrapper cases. Ambiguous jobs (WF4, WF5)
# are expected to fail extract but MUST NOT prevent WF1/WF2/WF3 from
# dispatching successfully on the same run.
{
    echo "~$WF_ISO/wf1.7z|sd|wf1/out~"
    echo "~$WF_ISO/wf2.7z|sd|wf2/out~"
    echo "~$WF_ISO/wf3.7z|sd|wf3/out~"
    echo "~$WF_ISO/wf4.7z|sd|wf4/out~"
    echo "~$WF_ISO/wf5.7z|sd|wf5/out~"
} > "$WF_JOBS"

echo "  cmd: EXTRACT_DIR=$WF_EXTRACT SD_MOUNT_POINT=$WF_SD bash bin/loadout-pipeline.sh $WF_JOBS"
set +e
EXTRACT_DIR="$WF_EXTRACT" SD_MOUNT_POINT="$WF_SD" \
    bash "$PIPELINE" "$WF_JOBS" >"$WF_LOG" 2>&1
wf_rc=$?
set -e

# Overall rc: expected non-zero because WF4/WF5 fail permanently.
if (( wf_rc != 0 )); then
    pass "pipeline reported failure (rc=$wf_rc) for ambiguous wrapper jobs"
else
    fail "pipeline returned 0 despite ambiguous wrapper jobs (expected non-zero)"
    sed 's/^/      /' "$WF_LOG"
fi

# WF1: flattened payload reaches SD.
if [[ -f "$WF_SD/wf1/out/game1.iso" ]]; then
    pass "WF1 single-dir wrapper flattened and dispatched"
else
    fail "WF1 expected $WF_SD/wf1/out/game1.iso after flatten"
fi
# WF1 must NOT leave the wrapper name on disk.
if [[ ! -e "$WF_SD/wf1/out/MyGame1" ]]; then
    pass "WF1 wrapper directory name stripped from dispatch tree"
else
    fail "WF1 wrapper dir 'MyGame1' still present under dispatch destination"
fi

# WF2: strip removed Vimm's Lair.txt (pre-flatten), wrapper flattened.
if [[ -f "$WF_SD/wf2/out/game2.iso" ]]; then
    pass "WF2 wrapper+strip-top flattened and dispatched"
else
    fail "WF2 expected $WF_SD/wf2/out/game2.iso"
fi
if [[ ! -e "$WF_SD/wf2/out/Vimm's Lair.txt" ]]; then
    pass "WF2 strip-list file removed (pre-flatten pass)"
else
    fail "WF2 Vimm's Lair.txt still present at dispatch destination"
fi

# WF3: wrapper flattened, post-flatten strip removed Vimm's Lair.txt.
if [[ -f "$WF_SD/wf3/out/game3.iso" ]]; then
    pass "WF3 wrapper flattened and dispatched"
else
    fail "WF3 expected $WF_SD/wf3/out/game3.iso"
fi
if [[ ! -e "$WF_SD/wf3/out/Vimm's Lair.txt" ]]; then
    pass "WF3 inner strip-list file removed (post-flatten pass)"
else
    fail "WF3 inner Vimm's Lair.txt still present at dispatch destination"
fi

# WF4: ambiguous (wrapper + unrelated loose file) → nothing at destination.
if [[ ! -e "$WF_SD/wf4/out" ]]; then
    pass "WF4 ambiguous (dir+file) job did NOT dispatch"
else
    fail "WF4 ambiguous job unexpectedly dispatched to $WF_SD/wf4/out"
fi
if grep -F "cannot flatten wrapper for 'wf4'" "$WF_LOG" >/dev/null; then
    pass "WF4 ambiguous job logged a flatten error"
else
    fail "WF4 expected a 'cannot flatten wrapper for wf4' log line"
    sed 's/^/      /' "$WF_LOG"
fi

# WF5: ambiguous (two top-level directories) → nothing at destination.
if [[ ! -e "$WF_SD/wf5/out" ]]; then
    pass "WF5 ambiguous (two dirs) job did NOT dispatch"
else
    fail "WF5 ambiguous job unexpectedly dispatched to $WF_SD/wf5/out"
fi
if grep -F "cannot flatten wrapper for 'wf5'" "$WF_LOG" >/dev/null; then
    pass "WF5 ambiguous job logged a flatten error"
else
    fail "WF5 expected a 'cannot flatten wrapper for wf5' log line"
fi

rm -rf "$WF_WORK"
