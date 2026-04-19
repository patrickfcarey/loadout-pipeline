#!/usr/bin/env bash
# test/suites/18_unit_config_jobs_edges.sh
#
# Edge-case unit tests for lib/config.sh (.env parser + numeric validation)
# and lib/jobs.sh (load_jobs + directory profile). Suite 14 (U3/U4) covered
# the happy path; this suite covers the boundary cases where the parser has
# to reject, coerce, or tolerate unusual input.
#
#   C1  .env with `KEY=` (empty value) — empty string, not unset
#   C2  .env with non-identifier key — line skipped, parser does not abort
#   C3  SPACE_OVERHEAD_PCT=-5 rejected with exit 2
#   C4  MAX_RECOVERY_ATTEMPTS=0 rejected, =abc rejected, unset defaults to 3
#   C5  SPACE_RETRY_BACKOFF_INITIAL_SEC=0.5 accepted (decimal)
#   C6  load_jobs on empty directory profile — return 1 with error log
#   C7  load_jobs on directory profile reads *.jobs in sorted order
#   C8  load_jobs rejects Unicode path (ASCII-only regex)
#
# set -e trap: use pre-increment / explicit arithmetic inside any
# `_u_run_subshell < <(...)` block. Expressions like `(( x++ ))` can return
# exit 1 and silently abort the subshell under the inherited set -e.
#
# Strategy: config.sh calls `exit 2` on validation failure, so we run it
# inside `bash -c` subshells and capture the rc. We pass a scratch ROOT_DIR
# per test containing the test .env, so the real .env is never touched.

_u_run_subshell() {
    while IFS= read -r line; do
        case "$line" in
            PASS*) pass "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
        esac
    done
}

# Build a scratch ROOT_DIR that has logging.sh + config.sh symlinked in (plus
# a strip.list stub config.sh references at load time) and a test .env of our
# choosing. Returns the created dir on stdout. Caller rm -rfs it when done.
_c_make_root() {
    local env_contents="$1"
    local dir
    dir="$(mktemp -d -t lp_unit_cfg_XXXXXX)"
    mkdir -p "$dir/lib"
    ln -sf "$ROOT_DIR/lib/logging.sh"     "$dir/lib/logging.sh"
    ln -sf "$ROOT_DIR/lib/config.sh"      "$dir/lib/config.sh"
    ln -sf "$ROOT_DIR/lib/job_format.sh"  "$dir/lib/job_format.sh"
    ln -sf "$ROOT_DIR/lib/jobs.sh"        "$dir/lib/jobs.sh"
    # config.sh references $ROOT_DIR/strip.list for EXTRACT_STRIP_LIST default.
    : > "$dir/strip.list"
    printf '%s' "$env_contents" > "$dir/.env"
    chmod 600 "$dir/.env"
    printf '%s\n' "$dir"
}

# =============================================================================
# C1 — .env with `KEY=` (empty value) → empty string assigned, not unset
# =============================================================================

header "Test C1: .env KEY= assigns empty string"

C1_ROOT="$(_c_make_root 'TEST_EMPTY_VAR=
MAX_UNZIP=2
MAX_DISPATCH=2
MAX_RECOVERY_ATTEMPTS=3
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"

C1_OUT=$(ROOT_DIR="$C1_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
    if [[ -v TEST_EMPTY_VAR ]]; then
        if [[ -z "$TEST_EMPTY_VAR" ]]; then
            echo "EMPTY_OK"
        else
            echo "NONEMPTY:$TEST_EMPTY_VAR"
        fi
    else
        echo "UNSET"
    fi
' 2>&1)

if [[ "$C1_OUT" == *"EMPTY_OK"* ]]; then
    pass "KEY= exports an empty string"
elif [[ "$C1_OUT" == *"UNSET"* ]]; then
    fail "KEY= did not export anything (value unset)"
else
    fail "KEY= unexpected output: $C1_OUT"
fi

rm -rf "$C1_ROOT"

# =============================================================================
# C2 — .env with non-identifier key — line silently skipped
# =============================================================================
#
# The parser checks `[[ "$_dotenv_key" =~ [^a-zA-Z0-9_] ]] && continue`, so a
# key containing a character outside [A-Za-z0-9_] (e.g. '-') is silently
# skipped without aborting the parser. A legitimate variable on the next
# line must still be parsed and exported correctly — proving the parser did
# not trip set -e or exit early.

header "Test C2: .env non-identifier key silently skipped"

C2_ROOT="$(_c_make_root 'BAD-KEY=should_not_export
GOOD_KEY=ok_value
MAX_UNZIP=2
MAX_DISPATCH=2
MAX_RECOVERY_ATTEMPTS=3
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"

C2_OUT=$(ROOT_DIR="$C2_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
    echo "GOOD_KEY=${GOOD_KEY:-UNSET}"
    echo "BAD_KEY_SET=${BAD_KEY:+yes}${BAD_KEY-no}"
' 2>&1)

if grep -q "^GOOD_KEY=ok_value$" <<< "$C2_OUT"; then
    pass "valid sibling key parsed after bad line"
else
    fail "GOOD_KEY not set — parser aborted on bad line: $C2_OUT"
fi
if grep -q "^BAD_KEY_SET=no$" <<< "$C2_OUT"; then
    pass "non-identifier key was not exported"
else
    fail "BAD-KEY seems to have been exported: $C2_OUT"
fi

rm -rf "$C2_ROOT"

# =============================================================================
# C3 — SPACE_OVERHEAD_PCT=-5 → rejected with exit 2
# =============================================================================

header "Test C3: SPACE_OVERHEAD_PCT negative value rejected"

C3_ROOT="$(_c_make_root 'SPACE_OVERHEAD_PCT=-5
MAX_UNZIP=2
MAX_DISPATCH=2
MAX_RECOVERY_ATTEMPTS=3
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"

C3_LOG=$(mktemp)
C3_RC=0
ROOT_DIR="$C3_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
    echo "UNEXPECTED_PASS"
' >"$C3_LOG" 2>&1 || C3_RC=$?

if (( C3_RC == 2 )); then
    pass "SPACE_OVERHEAD_PCT=-5 exited with rc=2"
else
    fail "expected rc=2, got $C3_RC"
    sed 's/^/      /' "$C3_LOG"
fi
if grep -q 'SPACE_OVERHEAD_PCT' "$C3_LOG"; then
    pass "error message mentions SPACE_OVERHEAD_PCT"
else
    fail "error message did not name SPACE_OVERHEAD_PCT"
fi
if ! grep -q 'UNEXPECTED_PASS' "$C3_LOG"; then
    pass "config.sh aborted (did not fall through)"
else
    fail "config.sh fell through instead of exiting"
fi

rm -rf "$C3_ROOT"
rm -f "$C3_LOG"

# =============================================================================
# C4 — MAX_RECOVERY_ATTEMPTS: 0 rejected, abc rejected, unset defaults to 3
# =============================================================================

header "Test C4: MAX_RECOVERY_ATTEMPTS validation"

# Sub-case A: =0 → rejected (check requires >= 1).
C4A_ROOT="$(_c_make_root 'MAX_RECOVERY_ATTEMPTS=0
MAX_UNZIP=2
MAX_DISPATCH=2
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"
C4A_RC=0
C4A_LOG=$(mktemp)
ROOT_DIR="$C4A_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
' >"$C4A_LOG" 2>&1 || C4A_RC=$?
if (( C4A_RC == 2 )); then
    pass "MAX_RECOVERY_ATTEMPTS=0 rejected with rc=2"
else
    fail "MAX_RECOVERY_ATTEMPTS=0 unexpectedly accepted (rc=$C4A_RC)"
fi
rm -rf "$C4A_ROOT"
rm -f "$C4A_LOG"

# Sub-case B: =abc → rejected (regex mismatch).
C4B_ROOT="$(_c_make_root 'MAX_RECOVERY_ATTEMPTS=abc
MAX_UNZIP=2
MAX_DISPATCH=2
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"
C4B_RC=0
C4B_LOG=$(mktemp)
ROOT_DIR="$C4B_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
' >"$C4B_LOG" 2>&1 || C4B_RC=$?
if (( C4B_RC == 2 )); then
    pass "MAX_RECOVERY_ATTEMPTS=abc rejected with rc=2"
else
    fail "MAX_RECOVERY_ATTEMPTS=abc unexpectedly accepted (rc=$C4B_RC)"
fi
if grep -q 'MAX_RECOVERY_ATTEMPTS' "$C4B_LOG"; then
    pass "MAX_RECOVERY_ATTEMPTS=abc error names the var"
else
    fail "MAX_RECOVERY_ATTEMPTS=abc error did not name the var"
fi
rm -rf "$C4B_ROOT"
rm -f "$C4B_LOG"

# Sub-case C: unset → defaults to 3.
C4C_ROOT="$(_c_make_root 'MAX_UNZIP=2
MAX_DISPATCH=2
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"
C4C_OUT=$(ROOT_DIR="$C4C_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
    echo "MRA=$MAX_RECOVERY_ATTEMPTS"
' 2>&1)
if grep -q "^MRA=3$" <<< "$C4C_OUT"; then
    pass "MAX_RECOVERY_ATTEMPTS unset defaults to 3"
else
    fail "MAX_RECOVERY_ATTEMPTS default wrong: $C4C_OUT"
fi
rm -rf "$C4C_ROOT"

# =============================================================================
# C5 — SPACE_RETRY_BACKOFF_INITIAL_SEC=0.5 accepted (decimal)
# =============================================================================

header "Test C5: SPACE_RETRY_BACKOFF_INITIAL_SEC decimal accepted"

C5_ROOT="$(_c_make_root 'SPACE_RETRY_BACKOFF_INITIAL_SEC=0.5
SPACE_RETRY_BACKOFF_MAX_SEC=60
MAX_UNZIP=2
MAX_DISPATCH=2
MAX_RECOVERY_ATTEMPTS=3
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"
C5_OUT=$(ROOT_DIR="$C5_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
    echo "BACKOFF=$SPACE_RETRY_BACKOFF_INITIAL_SEC"
' 2>&1)
if grep -q "^BACKOFF=0.5$" <<< "$C5_OUT"; then
    pass "SPACE_RETRY_BACKOFF_INITIAL_SEC=0.5 accepted"
else
    fail "decimal value not accepted: $C5_OUT"
fi
rm -rf "$C5_ROOT"

# =============================================================================
# C6 — load_jobs on empty directory profile → return 1 with error
# =============================================================================

header "Test C6: load_jobs empty directory profile"

C6_EMPTY_DIR="/tmp/lp_unit_c6_$$"
mkdir -p "$C6_EMPTY_DIR"

C6_RC=0
C6_LOG=$(mktemp)
bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/jobs.sh"
    load_jobs "$2"
' -- "$ROOT_DIR" "$C6_EMPTY_DIR" >"$C6_LOG" 2>&1 || C6_RC=$?

if (( C6_RC == 1 )); then
    pass "empty directory profile returns rc=1"
else
    fail "empty directory profile rc=$C6_RC (expected 1)"
fi
if grep -q 'no .jobs files found' "$C6_LOG"; then
    pass "empty directory profile logs 'no .jobs files found'"
else
    fail "expected 'no .jobs files found' in log: $(cat "$C6_LOG")"
fi

rm -rf "$C6_EMPTY_DIR"
rm -f "$C6_LOG"

# =============================================================================
# C7 — directory profile reads *.jobs in sorted order
# =============================================================================

header "Test C7: load_jobs directory profile sorted order"

C7_DIR="/tmp/lp_unit_c7_$$"
mkdir -p "$C7_DIR"

# Create files in REVERSE order so readdir's native order differs from
# alphabetical; load_jobs must re-sort them to a,b,c.
cat > "$C7_DIR/c.jobs" <<'EOF'
---JOBS---
~/iso/game_c.7z|lvol|dest/c~
---END---
EOF
cat > "$C7_DIR/b.jobs" <<'EOF'
---JOBS---
~/iso/game_b.7z|lvol|dest/b~
---END---
EOF
cat > "$C7_DIR/a.jobs" <<'EOF'
---JOBS---
~/iso/game_a.7z|lvol|dest/a~
---END---
EOF

C7_OUT=$(bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/jobs.sh"
    load_jobs "$2" >/dev/null 2>&1
    for j in "${JOBS[@]}"; do
        echo "$j"
    done
' -- "$ROOT_DIR" "$C7_DIR")

C7_EXPECTED=$(printf '~/iso/game_a.7z|lvol|dest/a~\n~/iso/game_b.7z|lvol|dest/b~\n~/iso/game_c.7z|lvol|dest/c~')
if [[ "$C7_OUT" == "$C7_EXPECTED" ]]; then
    pass "directory profile reads *.jobs in a,b,c order"
else
    fail "order wrong — got:"
    sed 's/^/      /' <<< "$C7_OUT"
fi

rm -rf "$C7_DIR"

# =============================================================================
# C8 — load_jobs rejects Unicode path (ASCII-only regex)
# =============================================================================
#
# The _job_regex in lib/jobs.sh only allows [A-Za-z0-9_./ ()-] in the
# iso_path field — no Unicode. A path like `~/ゲーム/game.7z|lvol|games/g~`
# must be rejected. This test documents the current ASCII-only policy; if
# a future change loosens the regex to allow UTF-8, this test becomes the
# regression guard for the intentional change.

header "Test C8: load_jobs rejects Unicode iso path"

C8_FILE="/tmp/lp_unit_c8_$$.jobs"
{ echo '---JOBS---'; printf '~/\xe3\x82\xb2\xe3\x83\xbc\xe3\x83\xa0/game.7z|lvol|games/g~\n'; echo '---END---'; } > "$C8_FILE"

C8_RC=0
C8_LOG=$(mktemp)
bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/jobs.sh"
    load_jobs "$2"
' -- "$ROOT_DIR" "$C8_FILE" >"$C8_LOG" 2>&1 || C8_RC=$?

if (( C8_RC == 1 )); then
    pass "Unicode iso path rejected with rc=1"
else
    fail "Unicode path accepted (rc=$C8_RC)"
fi
if grep -q 'invalid job' "$C8_LOG"; then
    pass "Unicode path logs 'invalid job'"
else
    fail "expected 'invalid job' log: $(cat "$C8_LOG")"
fi

rm -f "$C8_FILE"
rm -f "$C8_LOG"

# =============================================================================
# C9 — DEBUG_IND accepts 0|1|2 and rejects everything else
# =============================================================================
#
# DEBUG_IND is gated by an enum-style case in lib/config.sh: only the
# literal values 0, 1, and 2 are valid. Anything else — "true", "yes", "3",
# or a typo like "debug" — must fail preflight with rc=2 so an operator
# asking for debug output gets debug output or a clear error. A silent
# degrade to level 0 would defeat the point of asking for a specific
# verbosity.

header "Test C9: DEBUG_IND validation"

# Sub-case A: =0 accepted.
C9A_ROOT="$(_c_make_root 'DEBUG_IND=0
MAX_UNZIP=2
MAX_DISPATCH=2
MAX_RECOVERY_ATTEMPTS=3
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"
C9A_RC=0
ROOT_DIR="$C9A_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
' >/dev/null 2>&1 || C9A_RC=$?
if (( C9A_RC == 0 )); then
    pass "DEBUG_IND=0 accepted"
else
    fail "DEBUG_IND=0 unexpectedly rejected (rc=$C9A_RC)"
fi
rm -rf "$C9A_ROOT"

# Sub-case B: =2 accepted.
C9B_ROOT="$(_c_make_root 'DEBUG_IND=2
MAX_UNZIP=2
MAX_DISPATCH=2
MAX_RECOVERY_ATTEMPTS=3
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"
C9B_RC=0
ROOT_DIR="$C9B_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
' >/dev/null 2>&1 || C9B_RC=$?
if (( C9B_RC == 0 )); then
    pass "DEBUG_IND=2 accepted"
else
    fail "DEBUG_IND=2 unexpectedly rejected (rc=$C9B_RC)"
fi
rm -rf "$C9B_ROOT"

# Sub-case C: =3 rejected (out of range) with rc=2 + named var in error.
C9C_ROOT="$(_c_make_root 'DEBUG_IND=3
MAX_UNZIP=2
MAX_DISPATCH=2
MAX_RECOVERY_ATTEMPTS=3
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"
C9C_RC=0
C9C_LOG=$(mktemp)
ROOT_DIR="$C9C_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
' >"$C9C_LOG" 2>&1 || C9C_RC=$?
if (( C9C_RC == 2 )); then
    pass "DEBUG_IND=3 rejected with rc=2"
else
    fail "DEBUG_IND=3 unexpectedly accepted (rc=$C9C_RC)"
fi
if grep -q 'DEBUG_IND' "$C9C_LOG"; then
    pass "DEBUG_IND=3 error names the var"
else
    fail "DEBUG_IND=3 error did not name the var: $(cat "$C9C_LOG")"
fi
rm -rf "$C9C_ROOT"
rm -f "$C9C_LOG"

# Sub-case D: =true rejected (non-numeric typo) with rc=2.
C9D_ROOT="$(_c_make_root 'DEBUG_IND=true
MAX_UNZIP=2
MAX_DISPATCH=2
MAX_RECOVERY_ATTEMPTS=3
DISPATCH_POLL_INITIAL_MS=50
DISPATCH_POLL_MAX_MS=500
')"
C9D_RC=0
ROOT_DIR="$C9D_ROOT" bash -c '
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
' >/dev/null 2>&1 || C9D_RC=$?
if (( C9D_RC == 2 )); then
    pass "DEBUG_IND=true rejected with rc=2"
else
    fail "DEBUG_IND=true unexpectedly accepted (rc=$C9D_RC)"
fi
rm -rf "$C9D_ROOT"

# =============================================================================
# C10 — load_jobs accepts apostrophes in iso_path and hdl title fields
# =============================================================================
#
# Real PS2/PSX game titles frequently contain apostrophes (e.g. "Tony Hawk's
# Pro Skater", "Ratchet & Clank: Going Commando"). The iso_path regex used
# to reject apostrophe entirely, forcing operators to rename archives
# before submitting. Apostrophes are safe because every pipeline code path
# double-quotes $archive and passes the hdl title as a distinct argv element.
#
# Destination remains restrictive (no apostrophe) because adapter destinations
# may be passed to external tools whose quoting behaviour varies.

header "Test C10: load_jobs accepts apostrophes in iso_path and hdl title"

C10_FILE="/tmp/lp_unit_c10_$$.jobs"
{ echo '---JOBS---'
  echo "~/iso/Tony Hawk's Pro Skater.7z|lvol|games/thps~"
  echo "~/iso/Ratchet.7z|hdl|dvd|Ratchet & Clank: Up Your Arsenal~"
  echo "~/iso/Ico.7z|hdl|cd|Ico (Shadow's Cousin)~"
  echo '---END---'
} > "$C10_FILE"

C10_OUT=$(bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/jobs.sh"
    load_jobs "$2" >/dev/null 2>&1
    for j in "${JOBS[@]}"; do
        echo "$j"
    done
' -- "$ROOT_DIR" "$C10_FILE")

if grep -qF "Tony Hawk's Pro Skater.7z" <<< "$C10_OUT"; then
    pass "apostrophe in iso_path accepted"
else
    fail "apostrophe in iso_path rejected: $C10_OUT"
fi
if grep -qF "Ratchet & Clank: Up Your Arsenal" <<< "$C10_OUT"; then
    pass "hdl title with & and : accepted"
else
    fail "hdl title with & and : rejected: $C10_OUT"
fi
if grep -qF "Ico (Shadow's Cousin)" <<< "$C10_OUT"; then
    pass "hdl title with apostrophe and parens accepted"
else
    fail "hdl title with apostrophe rejected: $C10_OUT"
fi

# Destination must still reject apostrophe — the restriction on the
# destination field protects downstream remote-tool quoting.
C10B_FILE="/tmp/lp_unit_c10b_$$.jobs"
{ echo '---JOBS---'
  echo "~/iso/game.7z|lvol|games/bad's_dest~"
  echo '---END---'
} > "$C10B_FILE"
C10B_RC=0
bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/jobs.sh"
    load_jobs "$2"
' -- "$ROOT_DIR" "$C10B_FILE" >/dev/null 2>&1 || C10B_RC=$?
if (( C10B_RC == 1 )); then
    pass "apostrophe in destination still rejected (rc=1)"
else
    fail "apostrophe in destination wrongly accepted (rc=$C10B_RC)"
fi

rm -f "$C10_FILE" "$C10B_FILE"

# =============================================================================
# C11 — load_jobs rejects duplicate archive basenames across jobs
# =============================================================================
#
# Two archives with the same basename (e.g. ps2/Mario.7z and psx/Mario.7z)
# would both drive extract.sh to compute out_dir=$EXTRACT_DIR/Mario and
# clobber each other when concurrent unzip workers process them. The
# detection happens once per run in the outer load_jobs frame so the O(N)
# scan does not get paid per recursive call on directory profiles.

header "Test C11: load_jobs rejects duplicate archive basenames"

# Sub-case A: duplicates within a single .jobs file.
C11A_FILE="/tmp/lp_unit_c11a_$$.jobs"
{ echo '---JOBS---'
  echo "~/ps2/Mario.7z|lvol|games/ps2_mario~"
  echo "~/psx/Mario.7z|lvol|games/psx_mario~"
  echo '---END---'
} > "$C11A_FILE"

C11A_RC=0
C11A_LOG=$(mktemp)
bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/jobs.sh"
    load_jobs "$2"
' -- "$ROOT_DIR" "$C11A_FILE" >"$C11A_LOG" 2>&1 || C11A_RC=$?

if (( C11A_RC == 1 )); then
    pass "duplicate basename in single file rejected with rc=1"
else
    fail "duplicate basename accepted (rc=$C11A_RC)"
    sed 's/^/      /' "$C11A_LOG"
fi
if grep -q 'duplicate archive basename' "$C11A_LOG"; then
    pass "error message names the collision"
else
    fail "expected 'duplicate archive basename' in log: $(cat "$C11A_LOG")"
fi
if grep -qF 'ps2/Mario.7z' "$C11A_LOG" && grep -qF 'psx/Mario.7z' "$C11A_LOG"; then
    pass "error message identifies both offending archives"
else
    fail "error log did not name both colliding archives"
    sed 's/^/      /' "$C11A_LOG"
fi

# Sub-case B: duplicates across two files in a directory profile.
# The collision straddles the recursion boundary, which means the check
# must be applied once at the OUTER load_jobs frame — not per recursive
# call. A per-file check would miss this case.
C11B_DIR="/tmp/lp_unit_c11b_$$"
mkdir -p "$C11B_DIR"
{ echo '---JOBS---'
  echo "~/vol1/SameName.7z|lvol|dest/a~"
  echo '---END---'
} > "$C11B_DIR/a.jobs"
{ echo '---JOBS---'
  echo "~/vol2/SameName.7z|lvol|dest/b~"
  echo '---END---'
} > "$C11B_DIR/b.jobs"

C11B_RC=0
C11B_LOG=$(mktemp)
bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/jobs.sh"
    load_jobs "$2"
' -- "$ROOT_DIR" "$C11B_DIR" >"$C11B_LOG" 2>&1 || C11B_RC=$?

if (( C11B_RC == 1 )); then
    pass "duplicate basename across directory profile rejected"
else
    fail "cross-file duplicate accepted (rc=$C11B_RC)"
    sed 's/^/      /' "$C11B_LOG"
fi

# Sub-case C: same basename with DIFFERENT extensions is fine (only .7z
# stems collide at extract time). Kept as a positive regression so a future
# tighter rule does not over-reject.
C11C_FILE="/tmp/lp_unit_c11c_$$.jobs"
{ echo '---JOBS---'
  echo "~/iso/game_a.7z|lvol|dest/a~"
  echo "~/iso/game_b.7z|lvol|dest/b~"
  echo "~/iso/game_c.7z|lvol|dest/c~"
  echo '---END---'
} > "$C11C_FILE"

C11C_RC=0
bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/jobs.sh"
    load_jobs "$2"
' -- "$ROOT_DIR" "$C11C_FILE" >/dev/null 2>&1 || C11C_RC=$?
if (( C11C_RC == 0 )); then
    pass "distinct basenames still accepted"
else
    fail "unique basename jobs wrongly rejected (rc=$C11C_RC)"
fi

rm -f "$C11A_FILE" "$C11A_LOG" "$C11B_LOG" "$C11C_FILE"
rm -rf "$C11B_DIR"
