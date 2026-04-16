#!/usr/bin/env bash
# =============================================================================
# ASSERTION VALIDATION SUITE
# =============================================================================
# Proves that every meaningful assertion in test/run_tests.sh can actually
# detect a failure.  Each validation ("V-check") applies a targeted synthetic
# defect — a missing file, a wrong log line, leftover scratch state — and
# verifies the relevant assertion logic reports FAIL when it should.
#
# A CAUGHT result means the assertion is sensitive: it would have caught this
# specific kind of failure in a real run.
# A MISSED result means the assertion is vacuous for that case: it would pass
# even in the presence of the defect, providing false confidence.
#
# Each assertion is also validated in the POSITIVE direction (no defect → PASS)
# so we catch assertions that are broken in the opposite way (always failing).
#
# Usage: bash test/validate_tests.sh
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$ROOT_DIR/test/fixtures"
# Generate the test jobs file at runtime from $ROOT_DIR so this validator
# works in any clone location (WSL /mnt/c/..., Oracle Linux /tank/..., CI
# /home/runner/..., etc). A committed file with baked-in absolute paths
# would break the moment the repo moved off one machine.
TEST_JOBS="/tmp/iso_pipeline_validate_jobs_$$.jobs"
cat > "$TEST_JOBS" <<EOF
~$FIXTURES_DIR/isos/game1.7z|ftp|/remote/path/game1~
~$FIXTURES_DIR/isos/game2.7z|hdl|/dev/hdd0~
~$FIXTURES_DIR/isos/game3.7z|lvol|games/game3~
EOF
trap 'rm -f "$TEST_JOBS"' EXIT

VPASS=0
VFAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

caught() { echo -e "  ${GREEN}[CAUGHT]${RESET} $*"; (( VPASS++ )) || true; }
missed() { echo -e "  ${RED}[MISSED]${RESET} $*"; (( VFAIL++ )) || true; }
header() { echo -e "\n${BOLD}=== $* ===${RESET}"; }

# ── Inline assertion logic ─────────────────────────────────────────────────────
# Mirror the exact conditions used in run_tests.sh so we're validating the
# real logic, not a paraphrase of it.  Each function returns "PASS" or "FAIL"
# as a string so we can check it without touching global counters.

_check_extracted() {
    # run_tests.sh assert_extracted: file must exist at $base/$game/$game.iso
    local game="$1" base="$2"
    [[ -f "$base/$game/$game.iso" ]] && echo PASS || echo FAIL
}

_check_queue_empty() {
    # run_tests.sh assert_queue_empty: no .job or .claimed.* files in qdir
    local n
    n=$(find "$1" -maxdepth 1 \( -name "*.job" -o -name "*.claimed.*" \) \
            2>/dev/null | wc -l)
    (( n == 0 )) && echo PASS || echo FAIL
}

_check_no_scratch() {
    # run_tests.sh tests 11/12/14/18: no *.7z.* files anywhere under copy_dir
    local n
    n=$(find "$1" -name '*.7z.*' 2>/dev/null | wc -l)
    (( n == 0 )) && echo PASS || echo FAIL
}

_check_ledger_drained() {
    # run_tests.sh tests 11/13: ledger file absent or empty
    [[ ! -s "$1/.space_ledger" ]] && echo PASS || echo FAIL
}

_check_no_partial_dirs() {
    # run_tests.sh test 11: no subdirectories under extract_dir
    local n
    n=$(find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    (( n == 0 )) && echo PASS || echo FAIL
}

_check_partial_present() {
    # run_tests.sh test 14: at least one PARTIAL_FILE under extract_dir
    local n
    n=$(find "$1" -name 'PARTIAL_FILE' 2>/dev/null | wc -l)
    (( n > 0 )) && echo PASS || echo FAIL
}

# ═════════════════════════════════════════════════════════════════════════════
# V1–V4  assert_extracted  (tests 1-8, 12, 14, 18)
# ═════════════════════════════════════════════════════════════════════════════
header "V1–V4: assert_extracted"

V_BASE="/tmp/lp_validate_extracted_$$"
mkdir -p "$V_BASE"

# V1: missing directory → FAIL
r=$(_check_extracted "ghost" "$V_BASE")
[[ "$r" == FAIL ]] \
    && caught "V1: missing game dir detected as absent" \
    || missed "V1: missing game dir NOT detected"

# V2: dir exists but .iso absent → FAIL
mkdir -p "$V_BASE/game1"
r=$(_check_extracted "game1" "$V_BASE")
[[ "$r" == FAIL ]] \
    && caught "V2: missing .iso inside dir detected" \
    || missed "V2: missing .iso inside dir NOT detected"

# V3: .iso present but wrong filename → FAIL
touch "$V_BASE/game1/wrong.iso"
r=$(_check_extracted "game1" "$V_BASE")
[[ "$r" == FAIL ]] \
    && caught "V3: wrong .iso filename detected as absent" \
    || missed "V3: wrong .iso filename NOT detected"

# V4: correct file present → PASS  (positive — must not false-positive)
touch "$V_BASE/game1/game1.iso"
r=$(_check_extracted "game1" "$V_BASE")
[[ "$r" == PASS ]] \
    && caught "V4: correct .iso passes assertion" \
    || missed "V4: correct .iso wrongly fails assertion"

rm -rf "$V_BASE"

# ═════════════════════════════════════════════════════════════════════════════
# V5–V8  assert_queue_empty  (test 4)
# ═════════════════════════════════════════════════════════════════════════════
header "V5–V8: assert_queue_empty"

V_QDIR="/tmp/lp_validate_queue_$$"
mkdir -p "$V_QDIR"

# V5: stray .job file → FAIL
touch "$V_QDIR/1234567890.12345.job"
r=$(_check_queue_empty "$V_QDIR")
[[ "$r" == FAIL ]] \
    && caught "V5: leftover .job file detected" \
    || missed "V5: leftover .job file NOT detected"
rm -f "$V_QDIR/1234567890.12345.job"

# V6: stray .claimed.* file → FAIL  (a mid-race orphan)
touch "$V_QDIR/9999999999.99999.job.claimed.88888"
r=$(_check_queue_empty "$V_QDIR")
[[ "$r" == FAIL ]] \
    && caught "V6: leftover .claimed file detected" \
    || missed "V6: leftover .claimed file NOT detected"
rm -f "$V_QDIR/9999999999.99999.job.claimed.88888"

# V7: unrelated file present → PASS  (sentinel or lock files must not trip it)
touch "$V_QDIR/.extract_done"
r=$(_check_queue_empty "$V_QDIR")
[[ "$r" == PASS ]] \
    && caught "V7: non-job sentinel file does not trip queue-empty check" \
    || missed "V7: non-job file incorrectly triggers queue-empty FAIL"
rm -f "$V_QDIR/.extract_done"

# V8: truly empty dir → PASS
r=$(_check_queue_empty "$V_QDIR")
[[ "$r" == PASS ]] \
    && caught "V8: empty queue dir passes assertion" \
    || missed "V8: empty queue dir wrongly fails assertion"

rm -rf "$V_QDIR"

# ═════════════════════════════════════════════════════════════════════════════
# V9–V10  assert_clean_slate  (pre-condition guard in every test)
# ═════════════════════════════════════════════════════════════════════════════
header "V9–V10: assert_clean_slate"

V_SLATE_BASE="/tmp/lp_validate_slate_$$"
mkdir -p "$V_SLATE_BASE"

# V9: an extract dir from a prior run still exists → must abort (exit 1)
mkdir -p "$V_SLATE_BASE/game1"
(
    # Inline assert_clean_slate logic for game1
    [[ -d "$V_SLATE_BASE/game1" ]] && exit 1 || exit 0
) 2>/dev/null
[[ $? -ne 0 ]] \
    && caught "V9: stale game dir triggers abort" \
    || missed "V9: stale game dir does NOT trigger abort"

# V10: no stale dirs present → must NOT abort
rm -rf "$V_SLATE_BASE/game1"
(
    [[ -d "$V_SLATE_BASE/game1" ]] && exit 1 || exit 0
) 2>/dev/null
[[ $? -eq 0 ]] \
    && caught "V10: clean slate exits 0" \
    || missed "V10: clean slate incorrectly aborts"

rm -rf "$V_SLATE_BASE"

# ═════════════════════════════════════════════════════════════════════════════
# V11–V14  Skip / precheck detection  (tests 7, 9)
# ═════════════════════════════════════════════════════════════════════════════
header "V11–V14: [skip] log detection (tests 7 and 9)"

V_LOG="/tmp/lp_validate_skip_$$.log"

# V11: no [skip] line in output → grep should NOT match (assertion would FAIL)
printf '[extract] Copying game3.7z\n[extract] Extracting ...\n' > "$V_LOG"
grep -E '^\[skip\].*game3\.7z.*already exists at destination' "$V_LOG" >/dev/null 2>&1 \
    && missed "V11: grep matched even without [skip] line" \
    || caught "V11: absent [skip] line not matched — assertion would FAIL correctly"

# V12: correct [skip] line present → grep must match
printf '[skip] /path/game3.7z (reason: already exists at destination)\n' >> "$V_LOG"
grep -E '^\[skip\].*game3\.7z.*already exists at destination' "$V_LOG" >/dev/null 2>&1 \
    && caught "V12: correct [skip] line matched — assertion would PASS correctly" \
    || missed "V12: correct [skip] line NOT matched — assertion would always FAIL"

# V13: [skip] for a different game → must NOT match game3 check
printf '[skip] /path/game1.7z (reason: already exists at destination)\n' > "$V_LOG"
grep -E '^\[skip\].*game3\.7z.*already exists at destination' "$V_LOG" >/dev/null 2>&1 \
    && missed "V13: grep matched game3 from a game1 skip line — pattern too broad" \
    || caught "V13: game1 skip line correctly does not match game3 grep"

# V14: multi-file archive skip (test 9 pattern)
printf '[skip] /path/game4.7z (reason: already exists at destination)\n' > "$V_LOG"
grep -E '^\[skip\].*game4\.7z.*already exists at destination' "$V_LOG" >/dev/null 2>&1 \
    && caught "V14: multi-file archive [skip] line matched correctly" \
    || missed "V14: multi-file archive [skip] line NOT matched"

rm -f "$V_LOG"

# ═════════════════════════════════════════════════════════════════════════════
# V15–V16  Partial-hit no-skip detection  (test 10)
# ═════════════════════════════════════════════════════════════════════════════
header "V15–V16: partial-hit does-not-skip detection (test 10)"

V_LOG="/tmp/lp_validate_partial_$$.log"

# V15: [skip] wrongly present → test 10 assertion should detect it as a FAIL
printf '[skip] /path/game4.7z (reason: already exists at destination)\n' > "$V_LOG"
grep -E '^\[skip\]' "$V_LOG" >/dev/null 2>&1 \
    && caught "V15: spurious [skip] on partial hit correctly detected" \
    || missed "V15: spurious [skip] on partial hit NOT detected"

# V16: no [skip] line → test 10 assertion correctly passes
printf '[extract] Extracting game4.7z\n' > "$V_LOG"
grep -E '^\[skip\]' "$V_LOG" >/dev/null 2>&1 \
    && missed "V16: grep matched [skip] in output that had no skip" \
    || caught "V16: no [skip] in output — partial-hit assertion passes correctly"

rm -f "$V_LOG"

# ═════════════════════════════════════════════════════════════════════════════
# V17–V20  Scratch-copy leak detection  (tests 11, 12, 14, 18)
# ═════════════════════════════════════════════════════════════════════════════
header "V17–V20: scratch copy leak detection (tests 11, 12, 14, 18)"

V_COPY="/tmp/lp_validate_copy_$$"
mkdir -p "$V_COPY/99999"

# V17: a leaked scratch copy exists → FAIL
touch "$V_COPY/99999/game1.7z.12345"
r=$(_check_no_scratch "$V_COPY")
[[ "$r" == FAIL ]] \
    && caught "V17: leaked *.7z.* scratch file detected" \
    || missed "V17: leaked scratch file NOT detected"

# V18: scratch copy in a nested spool subdir → still detected (recursive find)
rm -f "$V_COPY/99999/game1.7z.12345"
mkdir -p "$V_COPY/99999/spool"
touch "$V_COPY/99999/spool/game2.7z.67890"
r=$(_check_no_scratch "$V_COPY")
[[ "$r" == FAIL ]] \
    && caught "V18: leaked scratch in nested subdir detected" \
    || missed "V18: nested scratch file NOT detected"
rm -f "$V_COPY/99999/spool/game2.7z.67890"

# V19: unrelated file present → must NOT trigger false alarm
touch "$V_COPY/99999/game1.7z"          # archive itself (no dot-pid suffix)
r=$(_check_no_scratch "$V_COPY")
[[ "$r" == PASS ]] \
    && caught "V19: plain archive name does not trigger scratch-leak false alarm" \
    || missed "V19: plain archive name wrongly triggers scratch-leak FAIL"
rm -f "$V_COPY/99999/game1.7z"

# V20: truly clean → PASS
r=$(_check_no_scratch "$V_COPY")
[[ "$r" == PASS ]] \
    && caught "V20: clean copy dir passes scratch-leak assertion" \
    || missed "V20: clean copy dir wrongly fails scratch-leak assertion"

rm -rf "$V_COPY"

# ═════════════════════════════════════════════════════════════════════════════
# V21–V23  Partial extract-dir detection  (tests 11, 14)
# ═════════════════════════════════════════════════════════════════════════════
header "V21–V23: partial extract-dir detection (tests 11 and 14)"

V_EXTRACT="/tmp/lp_validate_extract_$$"
mkdir -p "$V_EXTRACT"

# V21: no partial dirs → assertion for test 11 passes (no leak)
r=$(_check_no_partial_dirs "$V_EXTRACT")
[[ "$r" == PASS ]] \
    && caught "V21: empty extract dir passes no-partial-dir check" \
    || missed "V21: empty extract dir wrongly fails no-partial-dir check"

# V22: a partial dir exists → test 11 assertion catches it
mkdir -p "$V_EXTRACT/game1_partial"
r=$(_check_no_partial_dirs "$V_EXTRACT")
[[ "$r" == FAIL ]] \
    && caught "V22: leftover partial dir detected by test 11 assertion" \
    || missed "V22: leftover partial dir NOT detected"

# V23: PARTIAL_FILE present → test 14 "trap bypass confirmed" assertion passes
touch "$V_EXTRACT/game1_partial/PARTIAL_FILE"
r=$(_check_partial_present "$V_EXTRACT")
[[ "$r" == PASS ]] \
    && caught "V23: PARTIAL_FILE presence confirms trap bypass correctly" \
    || missed "V23: PARTIAL_FILE presence NOT detected"

# V23b: PARTIAL_FILE absent → test 14 trap-bypass assertion fails correctly
rm -f "$V_EXTRACT/game1_partial/PARTIAL_FILE"
r=$(_check_partial_present "$V_EXTRACT")
[[ "$r" == FAIL ]] \
    && caught "V23b: absent PARTIAL_FILE correctly fails trap-bypass assertion" \
    || missed "V23b: absent PARTIAL_FILE NOT detected as failure"

rm -rf "$V_EXTRACT"

# ═════════════════════════════════════════════════════════════════════════════
# V24–V26  Space ledger drain detection  (tests 11, 13)
# ═════════════════════════════════════════════════════════════════════════════
header "V24–V26: space ledger drain detection (tests 11 and 13)"

V_QDIR="/tmp/lp_validate_ledger_$$"
mkdir -p "$V_QDIR"

# V24: non-empty ledger → FAIL (reservation was not released)
printf 'extract.12345 2049 102400 2049 524288\n' > "$V_QDIR/.space_ledger"
r=$(_check_ledger_drained "$V_QDIR")
[[ "$r" == FAIL ]] \
    && caught "V24: unreleased space reservation detected" \
    || missed "V24: unreleased space reservation NOT detected"

# V25: empty ledger file → PASS
: > "$V_QDIR/.space_ledger"
r=$(_check_ledger_drained "$V_QDIR")
[[ "$r" == PASS ]] \
    && caught "V25: empty ledger correctly passes drain check" \
    || missed "V25: empty ledger wrongly fails drain check"

# V26: ledger file absent entirely → PASS (init not run, still "drained")
rm -f "$V_QDIR/.space_ledger"
r=$(_check_ledger_drained "$V_QDIR")
[[ "$r" == PASS ]] \
    && caught "V26: absent ledger file passes drain check" \
    || missed "V26: absent ledger file wrongly fails drain check"

rm -rf "$V_QDIR"

# ═════════════════════════════════════════════════════════════════════════════
# V27–V30  Worker registry orphan detection  (tests 15, 18)
# ═════════════════════════════════════════════════════════════════════════════
header "V27–V30: worker registry orphan detection (tests 15 and 18)"

V_REG_DIR="/tmp/lp_validate_registry_$$"
mkdir -p "$V_REG_DIR"

# Load the real registry module so we test the actual implementation.
export QUEUE_DIR="$V_REG_DIR"
# shellcheck source=../lib/logging.sh
source "$ROOT_DIR/lib/logging.sh"
# shellcheck source=../lib/worker_registry.sh
source "$ROOT_DIR/lib/worker_registry.sh"

EXPECTED_JOB="~$ROOT_DIR/test/fixtures/isos/game1.7z|lvol|games/game1~"

worker_registry_init

# V27: orphaned entry returned by recover → equality check passes
worker_job_begin "99998" "$EXPECTED_JOB"
recovered=$(worker_registry_recover)
[[ "$recovered" == "$EXPECTED_JOB" ]] \
    && caught "V27: orphaned job string returned correctly by recover" \
    || missed "V27: orphaned job string NOT returned or wrong: '$recovered'"

# V28: recover called a second time → registry already cleared, returns empty
recovered2=$(worker_registry_recover)
[[ -z "$recovered2" ]] \
    && caught "V28: registry empty after first recovery" \
    || missed "V28: registry not empty after recovery: '$recovered2'"

# V29: wrong job string would be caught by equality check
worker_registry_init
worker_job_begin "99997" "~wrong_archive.7z|lvol|games/wrong~"
recovered3=$(worker_registry_recover)
[[ "$recovered3" != "$EXPECTED_JOB" ]] \
    && caught "V29: wrong job string would fail equality check in test 15" \
    || missed "V29: wrong job string incorrectly matches expected"

# V30: orphan detection grep — log line present vs absent  (test 18)
V_LOG="/tmp/lp_validate_orphan_$$.log"
printf '[pipeline] Starting 1 extract worker(s)...\n' > "$V_LOG"
grep -q "orphaned job(s) detected" "$V_LOG" 2>/dev/null \
    && missed "V30a: grep matched orphan line in output that had none" \
    || caught "V30a: absent orphan log line correctly not matched"

printf '[WARN]  1 orphaned job(s) detected — re-queuing for recovery\n' >> "$V_LOG"
grep -q "orphaned job(s) detected" "$V_LOG" 2>/dev/null \
    && caught "V30b: present orphan log line correctly matched" \
    || missed "V30b: present orphan log line NOT matched"

rm -rf "$V_REG_DIR" "$V_LOG"

# ═════════════════════════════════════════════════════════════════════════════
# V31–V34  Adapter stub log detection  (tests 16, 17)
# ═════════════════════════════════════════════════════════════════════════════
header "V31–V34: adapter stub log detection (tests 16 and 17)"

V_LOG="/tmp/lp_validate_adapter_$$.log"

# V31: rclone stub line absent → grep fails (assertion would FAIL)
printf '[extract] Extracting game1.7z\n' > "$V_LOG"
grep -q '\[rclone\] STUB' "$V_LOG" 2>/dev/null \
    && missed "V31: rclone grep matched without stub line" \
    || caught "V31: absent rclone stub line not matched — assertion would FAIL"

# V32: rclone stub line present → grep matches (assertion would PASS)
printf '[rclone] STUB — would transfer /some/dir → gdrive:backups/games/game1\n' >> "$V_LOG"
grep -q '\[rclone\] STUB' "$V_LOG" 2>/dev/null \
    && caught "V32: rclone stub line correctly matched" \
    || missed "V32: rclone stub line NOT matched"

# V33: rsync local target format — wrong format fails
printf '[rsync] STUB — would transfer /some/dir → /wrong/path\n' > "$V_LOG"
grep -q '\[rsync\] STUB.*→ /mnt/nas/games/game2' "$V_LOG" 2>/dev/null \
    && missed "V33: rsync grep matched wrong target path" \
    || caught "V33: wrong rsync target path correctly not matched"

# V34: rsync local target format — correct format passes
printf '[rsync] STUB — would transfer /some/dir → /mnt/nas/games/game2\n' > "$V_LOG"
grep -q '\[rsync\] STUB.*→ /mnt/nas/games/game2' "$V_LOG" 2>/dev/null \
    && caught "V34: correct rsync local target format matched" \
    || missed "V34: correct rsync local target format NOT matched"

rm -f "$V_LOG"

# ═════════════════════════════════════════════════════════════════════════════
# V35–V36  rsync remote target format  (test 17 remote branch)
# ═════════════════════════════════════════════════════════════════════════════
header "V35–V36: rsync remote target format (test 17)"

V_LOG="/tmp/lp_validate_rsync_remote_$$.log"

# V35: missing user@host prefix → grep fails
printf '[rsync] STUB — would transfer /some/dir → /mnt/nas/games/game2\n' > "$V_LOG"
grep -q '\[rsync\] STUB.*→ admin@nas\.local:/mnt/nas/games/game2' "$V_LOG" 2>/dev/null \
    && missed "V35: rsync remote grep matched a local-target line" \
    || caught "V35: local-target line correctly does not match remote-target grep"

# V36: correct remote format present → grep matches
printf '[rsync] STUB — would transfer /some/dir → admin@nas.local:/mnt/nas/games/game2\n' > "$V_LOG"
grep -q '\[rsync\] STUB.*→ admin@nas\.local:/mnt/nas/games/game2' "$V_LOG" 2>/dev/null \
    && caught "V36: correct rsync remote target format matched" \
    || missed "V36: correct rsync remote target format NOT matched"

rm -f "$V_LOG"

# ═════════════════════════════════════════════════════════════════════════════
# V37–V40  Phantom ledger GC  (test 19)
# ═════════════════════════════════════════════════════════════════════════════
# Exercises both code paths that consume the ledger owner-PID field:
#   - space_ledger_empty   (non-destructive liveness filter)
#   - _space_ledger_gc_phantoms (destructive rewrite)
# and the end-to-end space_reserve flow where a phantom holds all capacity.
header "V37–V40: phantom ledger GC (test 19)"

V_GC_QDIR="/tmp/lp_validate_gc_$$"
mkdir -p "$V_GC_QDIR"

while IFS= read -r line; do
    case "$line" in
        CAUGHT*) caught "${line#CAUGHT }" ;;
        MISSED*) missed "${line#MISSED }" ;;
    esac
done < <(
    export QUEUE_DIR="$V_GC_QDIR"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/space.sh"

    space_init

    # A PID well above any plausible kernel.pid_max default (32768) — this
    # must NOT correspond to a live process. LIVE_PID is the subshell's
    # parent, which is alive throughout the test.
    DEAD_PID=9999999
    LIVE_PID=$$
    ledger="$(_space_ledger_path)"

    # V37: live-only ledger → space_ledger_empty must return non-zero (not empty).
    printf 'extract.%s 2049 102400 2049 204800 %s\n' "$LIVE_PID" "$LIVE_PID" > "$ledger"
    if ! space_ledger_empty; then
        echo "CAUGHT V37: live entry recognised — space_ledger_empty returned false"
    else
        echo "MISSED V37: space_ledger_empty returned true on a LIVE entry"
    fi

    # V38: phantom-only ledger → space_ledger_empty must return 0 (empty).
    printf 'extract.%s 2049 104857600 2049 209715200 %s\n' "$DEAD_PID" "$DEAD_PID" > "$ledger"
    if space_ledger_empty; then
        echo "CAUGHT V38: phantom-only ledger treated as empty"
    else
        echo "MISSED V38: phantom-only ledger was NOT treated as empty"
    fi

    # V39: mixed → _space_ledger_gc_phantoms drops phantom, keeps live.
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
        echo "CAUGHT V39: GC preserved live entry and dropped phantom"
    else
        echo "MISSED V39: GC mixed-case incorrect (phantom=$phantom_remaining live=$live_remaining)"
    fi

    # V40: phantom holds ALL capacity → space_reserve must succeed after GC.
    export SPACE_AVAIL_OVERRIDE_BYTES=2000000
    printf 'extract.%s 2049 1999999 2049 1999999 %s\n' "$DEAD_PID" "$DEAD_PID" > "$ledger"
    if space_reserve "extract.v40" "$QUEUE_DIR" 100000 "$QUEUE_DIR" 100000; then
        echo "CAUGHT V40: space_reserve succeeded after GCing phantom capacity"
    else
        echo "MISSED V40: space_reserve failed even though only a phantom held capacity"
    fi
    space_release "extract.v40"
)

rm -rf "$V_GC_QDIR"

# ═════════════════════════════════════════════════════════════════════════════
# V41–V43  load_jobs mid-string /../ rejection  (test 20)
# ═════════════════════════════════════════════════════════════════════════════
# The traversal regex in lib/jobs.sh must reject '..' anywhere — leading,
# trailing, or mid-string. V41/V42 are the M2 regression inputs; V43 is the
# over-broad negative check (legitimate '.' in filename must NOT be rejected).
header "V41–V43: load_jobs mid-string /../ rejection (test 20)"

V_TRAV_JOBS="/tmp/lp_validate_trav_$$.jobs"

while IFS= read -r line; do
    case "$line" in
        CAUGHT*) caught "${line#CAUGHT }" ;;
        MISSED*) missed "${line#MISSED }" ;;
    esac
done < <(
    export ROOT_DIR
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/jobs.sh"

    # V41: mid-string /../ in iso path MUST be rejected.
    printf '%s\n' "~/abs/../etc/passwd.7z|lvol|games/game1~" > "$V_TRAV_JOBS"
    JOBS=()
    if load_jobs "$V_TRAV_JOBS" 2>/dev/null; then
        echo "MISSED V41: mid-string /../ in iso path was NOT rejected"
    else
        echo "CAUGHT V41: mid-string /../ in iso path rejected"
    fi

    # V42: mid-string /../ in destination MUST be rejected.
    printf '%s\n' "~/abs/path/game.7z|lvol|games/../../../etc/passwd~" > "$V_TRAV_JOBS"
    JOBS=()
    if load_jobs "$V_TRAV_JOBS" 2>/dev/null; then
        echo "MISSED V42: mid-string /../ in destination was NOT rejected"
    else
        echo "CAUGHT V42: mid-string /../ in destination rejected"
    fi

    # V43: legitimate '.' in filename must still be ACCEPTED.
    printf '%s\n' "~/abs/path/game.v1.7z|lvol|games/game.v1~" > "$V_TRAV_JOBS"
    JOBS=()
    if load_jobs "$V_TRAV_JOBS" 2>/dev/null; then
        echo "CAUGHT V43: legitimate path with '.' in names accepted (guard not over-broad)"
    else
        echo "MISSED V43: legitimate path with '.' in names wrongly rejected"
    fi
)

rm -f "$V_TRAV_JOBS"

# ═════════════════════════════════════════════════════════════════════════════
# V44–V46  load_jobs basename-'.' rejection  (test R1 / C1 regression)
# ═════════════════════════════════════════════════════════════════════════════
# C1: "/..7z" passes the traversal regex (".." followed by "7", not "/" or
# end-of-string) but basename .7z yields "." — extract.sh would then compute
# out_dir as "$EXTRACT_DIR/." and clobber sibling workers' output. jobs.sh
# now computes the stripped basename and rejects anything empty or dot-led.
header "V44–V46: load_jobs basename-'.' rejection (R1 / C1 regression)"

V_BN_JOBS="/tmp/lp_validate_basename_$$.jobs"

while IFS= read -r line; do
    case "$line" in
        CAUGHT*) caught "${line#CAUGHT }" ;;
        MISSED*) missed "${line#MISSED }" ;;
    esac
done < <(
    export ROOT_DIR
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/jobs.sh"

    # V44: '/..7z' — basename .7z → '.' — MUST be rejected (C1 regression).
    printf '%s\n' "~/..7z|lvol|games/game1~" > "$V_BN_JOBS"
    JOBS=()
    if load_jobs "$V_BN_JOBS" 2>/dev/null; then
        echo "MISSED V44: '/..7z' was NOT rejected — C1 regression"
    else
        echo "CAUGHT V44: '/..7z' rejected by basename guard"
    fi

    # V45: '.hidden.7z' — basename begins with dot — MUST be rejected.
    printf '%s\n' "~/games/.hidden.7z|lvol|games/game1~" > "$V_BN_JOBS"
    JOBS=()
    if load_jobs "$V_BN_JOBS" 2>/dev/null; then
        echo "MISSED V45: '.hidden.7z' was NOT rejected"
    else
        echo "CAUGHT V45: '.hidden.7z' rejected (basename begins with dot)"
    fi

    # V46: legitimate 'game1.7z' MUST still be accepted (guard not over-broad).
    printf '%s\n' "~/games/game1.7z|lvol|games/game1~" > "$V_BN_JOBS"
    JOBS=()
    if load_jobs "$V_BN_JOBS" 2>/dev/null; then
        echo "CAUGHT V46: legitimate 'game1.7z' accepted (guard not over-broad)"
    else
        echo "MISSED V46: legitimate 'game1.7z' wrongly rejected by basename guard"
    fi
)

rm -f "$V_BN_JOBS"

# ═════════════════════════════════════════════════════════════════════════════
# V47–V48  _space_dev termination on non-existent paths  (R2 / C2 regression)
# ═════════════════════════════════════════════════════════════════════════════
# C2: relative path with no '/' would spin forever in `p="${p%/*}"`. Each
# V-check runs under `timeout 5`; if the bug regresses, timeout fires with
# exit 124.
header "V47–V48: _space_dev termination (R2 / C2 regression)"

# V47: relative non-existent path must NOT infinite-loop. timeout 124 = bug.
V47_RC=0
timeout 5 bash -c '
    ROOT_DIR="$1"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/space.sh"
    _space_dev "lp_validate_nonexistent_$$"
' -- "$ROOT_DIR" >/dev/null 2>&1 || V47_RC=$?
if (( V47_RC == 0 )); then
    caught "V47: _space_dev terminated cleanly on relative non-existent path"
elif (( V47_RC == 124 )); then
    missed "V47: _space_dev TIMED OUT — C2 infinite-loop bug regressed"
else
    missed "V47: _space_dev exited $V47_RC (expected 0)"
fi

# V48: _space_dev '/' must print a numeric device id (catches a regression
# that emits empty or non-numeric output).
V48_OUT=$(timeout 5 bash -c '
    ROOT_DIR="$1"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/space.sh"
    _space_dev /
' -- "$ROOT_DIR" 2>/dev/null)
if [[ "$V48_OUT" =~ ^[0-9]+$ ]]; then
    caught "V48: _space_dev on '/' returned numeric device id ($V48_OUT)"
else
    missed "V48: _space_dev on '/' returned non-numeric: '$V48_OUT'"
fi

# ═════════════════════════════════════════════════════════════════════════════
# V49–V50  queue_pop rc discrimination  (R3 / H1 regression)
# ═════════════════════════════════════════════════════════════════════════════
# H1: queue_pop conflated "empty" with "read error on claimed file", causing
# workers to silently exit the drain loop on a transient read failure. The
# current contract:
#   rc=0 — job returned
#   rc=1 — queue empty (legitimate drain)
#   rc=2 — read error (NOT tested here — cannot be triggered deterministically
#          without race injection)
header "V49–V50: queue_pop rc discrimination (R3 / H1 regression)"

V_Q_DIR="/tmp/lp_validate_qpop_$$"
mkdir -p "$V_Q_DIR"

while IFS= read -r line; do
    case "$line" in
        CAUGHT*) caught "${line#CAUGHT }" ;;
        MISSED*) missed "${line#MISSED }" ;;
    esac
done < <(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/queue.sh"

    queue_init "$V_Q_DIR"

    # V49: empty queue → rc MUST be exactly 1.
    queue_pop "$V_Q_DIR" >/dev/null
    rc=$?
    if (( rc == 1 )); then
        echo "CAUGHT V49: queue_pop returned 1 on empty queue"
    else
        echo "MISSED V49: queue_pop returned $rc on empty queue (expected 1)"
    fi

    # V50: push, then pop → rc=0 and output byte-exact.
    V50_JOB='~/games/game1.7z|lvol|games/g1~'
    queue_push "$V_Q_DIR" "$V50_JOB"
    V50_OUT=$(queue_pop "$V_Q_DIR")
    rc=$?
    if (( rc == 0 )) && [[ "$V50_OUT" == "$V50_JOB" ]]; then
        echo "CAUGHT V50: queue_pop returned 0 with byte-exact job string"
    else
        echo "MISSED V50: queue_pop rc=$rc out='$V50_OUT' (expected rc=0 out='$V50_JOB')"
    fi
)

rm -rf "$V_Q_DIR"

# ═════════════════════════════════════════════════════════════════════════════
# V51–V53  worker_registry_recover byte-exact preservation  (R4 / M3 regression)
# ═════════════════════════════════════════════════════════════════════════════
# M3: the old awk rule `{ $1=""; sub(/^ /,""); print }` triggered field
# rebuild with OFS (single space), collapsing consecutive spaces inside job
# strings. The fix switched to an index-based split that keeps $0 byte-exact.
# V52 is the direct regression check — a job path with two consecutive spaces.
header "V51–V53: worker_registry_recover byte-exact (R4 / M3 regression)"

V_WR_DIR="/tmp/lp_validate_wr_$$"
mkdir -p "$V_WR_DIR"

while IFS= read -r line; do
    case "$line" in
        CAUGHT*) caught "${line#CAUGHT }" ;;
        MISSED*) missed "${line#MISSED }" ;;
    esac
done < <(
    export QUEUE_DIR="$V_WR_DIR"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/worker_registry.sh"

    # V51: single-space job — recover emits byte-exact.
    worker_registry_init
    JOB1='~/games/game1.7z|lvol|games/g1~'
    printf '12345 %s\n' "$JOB1" > "$(_wr_path)"
    OUT1=$(worker_registry_recover)
    if [[ "$OUT1" == "$JOB1" ]]; then
        echo "CAUGHT V51: recover preserved single-space job byte-exact"
    else
        echo "MISSED V51: recover corrupted single-space job: '$OUT1'"
    fi

    # V52: DOUBLE-space job — recover emits byte-exact (M3 bug).
    worker_registry_init
    JOB2='~/games/my  game.7z|lvol|games/g1~'
    printf '12345 %s\n' "$JOB2" > "$(_wr_path)"
    OUT2=$(worker_registry_recover)
    if [[ "$OUT2" == "$JOB2" ]]; then
        echo "CAUGHT V52: recover preserved DOUBLE-space job byte-exact"
    else
        echo "MISSED V52: recover collapsed double space to single: '$OUT2'"
    fi

    # V53: empty registry — recover emits nothing.
    worker_registry_init
    OUT3=$(worker_registry_recover)
    if [[ -z "$OUT3" ]]; then
        echo "CAUGHT V53: recover on empty registry emitted nothing"
    else
        echo "MISSED V53: recover on empty registry emitted spurious output: '$OUT3'"
    fi
)

rm -rf "$V_WR_DIR"

# ═════════════════════════════════════════════════════════════════════════════
# V54–V55  Negative file existence — strip-list assertions  (test 21)
# ═════════════════════════════════════════════════════════════════════════════
# Test 21 uses `[[ ! -f "$dir/Vimm's Lair.txt" ]]` to assert the strip list
# was applied. V1–V4 only validate the POSITIVE existence pattern; these two
# V-checks validate the NEGATIVE existence pattern directly. Inverted logic
# so we use if/else instead of the &&/|| idiom to keep intent obvious.
header "V54–V55: strip-list negative file existence (test 21)"

V_STRIP_DIR="/tmp/lp_validate_strip_$$"
mkdir -p "$V_STRIP_DIR"

# V54: file IS present → the `! -f` assertion must return FALSE (so test 21
# would fail when the strip list regresses).
touch "$V_STRIP_DIR/Vimm's Lair.txt"
if [[ ! -f "$V_STRIP_DIR/Vimm's Lair.txt" ]]; then
    missed "V54: ! -f returned true even though the file exists — assertion vacuous"
else
    caught "V54: ! -f correctly flags file presence — would catch strip-list regression"
fi

# V55: file absent → the `! -f` assertion must return TRUE (positive path).
rm -f "$V_STRIP_DIR/Vimm's Lair.txt"
if [[ ! -f "$V_STRIP_DIR/Vimm's Lair.txt" ]]; then
    caught "V55: ! -f on absent file correctly returns true"
else
    missed "V55: ! -f on absent file wrongly returned false"
fi

rm -rf "$V_STRIP_DIR"

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════

echo -e "\n${BOLD}Results: ${GREEN}$VPASS caught${RESET}${BOLD}, ${RED}$VFAIL missed${RESET}"
if (( VFAIL > 0 )); then
    echo -e "${RED}One or more assertions are vacuous — they would pass even in the presence of the defect they claim to guard against.${RESET}"
    exit 1
fi
