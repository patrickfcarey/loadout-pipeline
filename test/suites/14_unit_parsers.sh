#!/usr/bin/env bash
# test/suites/14_unit_parsers.sh
#
# Direct unit tests for the pure-parser / config-validator functions. These
# previously had only end-to-end coverage (the "does the pipeline run" tests),
# which meant a regression in parse_job_line or strip_list_contains would only
# surface as a cryptic mid-pipeline failure. The tests here source the target
# files in a subshell and call the functions directly so a failure points at
# a specific function with a specific input.
#
# Coverage
#   U1  parse_job_line (lib/job_format.sh) — happy path and every malformed form
#   U2  strip_list_contains (lib/strip_list.sh) — comments, blanks, whitespace,
#       slash entries, missing file
#   U3  load_jobs (lib/jobs.sh) — CRLF endings, comment/blank lines, every valid
#       adapter, missing file, dot-basename rejection, shell-injection rejection
#   U4  config.sh .env parser — CRLF, comment, blank, password with '=', numeric
#       validation (MAX_UNZIP=0, DISPATCH_POLL_INITIAL_MS > DISPATCH_POLL_MAX_MS)

# ─── helper: run a subshell script, capture rc and stderr separately ─────────
# All subshell tests take the same shape: source the target file, call the
# function, echo PASS/FAIL lines for the caller to re-emit. This helper keeps
# that boilerplate in one place and uses the while-read pattern from suite
# 06 so counters stay in the parent shell.
_u_run_subshell() {
    while IFS= read -r line; do
        case "$line" in
            PASS*) pass "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
        esac
    done
}

# =============================================================================
# U1 — parse_job_line: every happy and failure mode
# =============================================================================

header "Test U1: parse_job_line (lib/job_format.sh)"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/job_format.sh"

    # Happy path: three non-empty fields, returns 0, emits three lines.
    if out=$(parse_job_line "~/abs/path/game.7z|lvol|games/game1~") && [[ -n "$out" ]]; then
        { read -r iso; read -r adapter; read -r dest; } <<< "$out"
        if [[ "$iso" == "/abs/path/game.7z" && "$adapter" == "lvol" && "$dest" == "games/game1" ]]; then
            echo "PASS happy path parsed into three correct fields"
        else
            echo "FAIL happy path fields mismatched: iso='$iso' adapter='$adapter' dest='$dest'"
        fi
    else
        echo "FAIL happy path rejected by parser"
    fi

    # Missing leading '~' must fail.
    if parse_job_line "/abs/game.7z|lvol|dest~" >/dev/null 2>&1; then
        echo "FAIL missing leading tilde was accepted"
    else
        echo "PASS missing leading tilde rejected"
    fi

    # Missing trailing '~' must fail.
    if parse_job_line "~/abs/game.7z|lvol|dest" >/dev/null 2>&1; then
        echo "FAIL missing trailing tilde was accepted"
    else
        echo "PASS missing trailing tilde rejected"
    fi

    # Empty iso_path field (~||lvol|dest~-style) must fail.
    if parse_job_line "~|lvol|dest~" >/dev/null 2>&1; then
        echo "FAIL empty iso_path was accepted"
    else
        echo "PASS empty iso_path rejected"
    fi

    # Empty adapter field must fail.
    if parse_job_line "~/abs/game.7z||dest~" >/dev/null 2>&1; then
        echo "FAIL empty adapter was accepted"
    else
        echo "PASS empty adapter rejected"
    fi

    # Empty dest field must fail.
    if parse_job_line "~/abs/game.7z|lvol|~" >/dev/null 2>&1; then
        echo "FAIL empty dest was accepted"
    else
        echo "PASS empty dest rejected"
    fi

    # Zero delimiters (just a tilde-wrapped word) must fail.
    if parse_job_line "~whatever~" >/dev/null 2>&1; then
        echo "FAIL zero-delimiter input was accepted"
    else
        echo "PASS zero-delimiter input rejected"
    fi

    # A single '~' character is neither a valid open+close pair nor a valid
    # body — the parser should reject it. This is the minimal malformed form.
    if parse_job_line "~" >/dev/null 2>&1; then
        echo "FAIL single-tilde input was accepted"
    else
        echo "PASS single-tilde input rejected"
    fi

    # Empty string must fail.
    if parse_job_line "" >/dev/null 2>&1; then
        echo "FAIL empty string was accepted"
    else
        echo "PASS empty string rejected"
    fi

    # An extra '|' field makes the third read absorb the rest — verify the
    # parser at minimum returns three fields (the `read -r a b c` contract).
    # parse_job_line's contract is three-field output; a fourth pipe becomes
    # part of the dest. That's a known-accepted form; document it as a PASS
    # so a future change that tightens the contract is a conscious decision.
    out=$(parse_job_line "~/abs/game.7z|lvol|dest|extra~" 2>/dev/null) || out=""
    if [[ -n "$out" ]]; then
        lines=$(printf '%s\n' "$out" | wc -l)
        if [[ "$lines" -eq 3 ]]; then
            echo "PASS extra pipe absorbed into dest (three-field contract held)"
        else
            echo "FAIL parser emitted $lines lines for four-field input (expected 3)"
        fi
    else
        echo "PASS extra pipe rejected outright"
    fi

    # Archive name with spaces and parentheses must survive unchanged.
    out=$(parse_job_line "~/games/Game Name (USA).7z|lvol|ps2~") || out=""
    if [[ "$out" == $'/games/Game Name (USA).7z\nlvol\nps2' ]]; then
        echo "PASS spaces and parentheses preserved in iso_path"
    else
        echo "FAIL spaces/parens mangled: '$out'"
    fi
)

# =============================================================================
# U2 — strip_list_contains: edge cases
# =============================================================================

header "Test U2: strip_list_contains (lib/strip_list.sh)"

U2_STRIP="/tmp/lp_unit_strip_$$.list"
cat > "$U2_STRIP" <<'EOF'
# a comment line — must be ignored
Vimm's Lair.txt
   # indented comment — must be ignored

readme.txt
has/slash.txt
EOF

_u_run_subshell < <(
    export EXTRACT_STRIP_LIST="$U2_STRIP"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/strip_list.sh"

    # Exact match of a real entry.
    if strip_list_contains "Vimm's Lair.txt"; then
        echo "PASS exact match found"
    else
        echo "FAIL Vimm's Lair.txt should match strip list"
    fi

    # Trailing whitespace in the list entry must be trimmed before comparison.
    if strip_list_contains "readme.txt"; then
        echo "PASS trailing-whitespace entry matched cleanly"
    else
        echo "FAIL 'readme.txt' should match despite trailing spaces in list"
    fi

    # Comment line must not match its literal content.
    if ! strip_list_contains "# a comment line — must be ignored"; then
        echo "PASS comment line not treated as a filename entry"
    else
        echo "FAIL comment line was treated as an entry"
    fi

    # Entry containing '/' must be silently ignored by this helper.
    if ! strip_list_contains "has/slash.txt"; then
        echo "PASS slash-containing entry ignored (per helper contract)"
    else
        echo "FAIL slash-containing entry should not match here"
    fi

    # Filename not in the list at all.
    if ! strip_list_contains "definitely-not-in-the-list.iso"; then
        echo "PASS non-member filename correctly not matched"
    else
        echo "FAIL unrelated filename incorrectly matched"
    fi

    # Empty string must not match anything.
    if ! strip_list_contains ""; then
        echo "PASS empty filename does not match"
    else
        echo "FAIL empty filename matched the strip list"
    fi

    # Missing strip list file → return 1 (nothing to strip).
    EXTRACT_STRIP_LIST="/nonexistent/path/$$.list"
    if ! strip_list_contains "anything"; then
        echo "PASS missing strip list returns 1"
    else
        echo "FAIL missing strip list should return 1"
    fi
)

rm -f "$U2_STRIP"

# =============================================================================
# U3 — load_jobs: CRLF, comment/blank, all adapters, dot-basename, injection
# =============================================================================

header "Test U3: load_jobs edge cases (lib/jobs.sh)"

U3_DIR="/tmp/lp_unit_loadjobs_$$"
mkdir -p "$U3_DIR"

# Case A — CRLF line endings: must parse identically to LF-only files.
printf '~/abs/game.7z|lvol|dest~\r\n' > "$U3_DIR/crlf.jobs"

# Case B — mixed blanks and full-line comments among valid jobs.
cat > "$U3_DIR/mixed.jobs" <<'EOF'
# header comment
~/abs/a.7z|lvol|d1~

# another comment

~/abs/b.7z|ftp|/d/2~
EOF

# Case C — every valid adapter name appears at least once.
cat > "$U3_DIR/all_adapters.jobs" <<'EOF'
~/abs/a.7z|ftp|/d1~
~/abs/b.7z|hdl|/dev/hdd0~
~/abs/c.7z|lvol|d3~
~/abs/d.7z|rclone|remote/d4~
~/abs/e.7z|rsync|d5~
EOF

# Case D — dot basename. After `basename ... .7z` this stem is empty / a dot
# and must be rejected (would otherwise collide with $EXTRACT_DIR root).
printf '~/..7z|lvol|dest~\n' > "$U3_DIR/dot_basename.jobs"

# Case E — only blanks and comments. load_jobs must NOT error, but should warn
# and leave JOBS empty.
cat > "$U3_DIR/empty_effective.jobs" <<'EOF'
# nothing here

# still nothing
EOF

# Case F — shell-injection-ish characters in dest. The destination char class
# is restrictive (no $ ; & ` etc), so a destination containing a dollar sign
# must be rejected by the regex.
printf '~/abs/game.7z|lvol|dest$INJECT~\n' > "$U3_DIR/injection.jobs"

# Case G — relative iso path (no leading slash) must be rejected.
printf '~abs/game.7z|lvol|dest~\n' > "$U3_DIR/relative.jobs"

_u_run_subshell < <(
    export ROOT_DIR
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/jobs.sh"

    # A: CRLF endings accepted.
    JOBS=()
    if load_jobs "$U3_DIR/crlf.jobs" 2>/dev/null && [[ ${#JOBS[@]} -eq 1 ]]; then
        echo "PASS CRLF line endings accepted"
    else
        echo "FAIL CRLF-terminated job was not accepted (JOBS count=${#JOBS[@]})"
    fi

    # B: mixed blank/comment input.
    JOBS=()
    if load_jobs "$U3_DIR/mixed.jobs" 2>/dev/null && [[ ${#JOBS[@]} -eq 2 ]]; then
        echo "PASS mixed blank/comment lines produced 2 jobs"
    else
        echo "FAIL mixed blank/comment input gave ${#JOBS[@]} jobs (expected 2)"
    fi

    # C: every valid adapter accepted.
    JOBS=()
    if load_jobs "$U3_DIR/all_adapters.jobs" 2>/dev/null && [[ ${#JOBS[@]} -eq 5 ]]; then
        echo "PASS all five adapter names accepted"
    else
        echo "FAIL all-adapters file gave ${#JOBS[@]} jobs (expected 5)"
    fi

    # D: dot-basename rejection.
    JOBS=()
    if load_jobs "$U3_DIR/dot_basename.jobs" 2>/dev/null; then
        echo "FAIL dot-basename ( /..7z ) was accepted"
    else
        echo "PASS dot-basename rejected"
    fi

    # E: effectively empty file — returns 0 with warning, JOBS empty.
    JOBS=()
    if load_jobs "$U3_DIR/empty_effective.jobs" 2>/dev/null && [[ ${#JOBS[@]} -eq 0 ]]; then
        echo "PASS effectively-empty file returns 0 with empty JOBS"
    else
        echo "FAIL effectively-empty file unexpected behaviour (rc=$? JOBS=${#JOBS[@]})"
    fi

    # F: shell metacharacter in dest must be rejected by the regex.
    JOBS=()
    if load_jobs "$U3_DIR/injection.jobs" 2>/dev/null; then
        echo "FAIL dest with '\$' character was accepted"
    else
        echo "PASS dest with shell metacharacter rejected"
    fi

    # G: relative iso path rejected (no leading slash).
    JOBS=()
    if load_jobs "$U3_DIR/relative.jobs" 2>/dev/null; then
        echo "FAIL relative iso path was accepted"
    else
        echo "PASS relative iso path rejected"
    fi

    # H: missing file → non-zero return (the function logs and returns 1).
    JOBS=()
    if load_jobs "/tmp/lp_unit_nonexistent_$$_$RANDOM.jobs" 2>/dev/null; then
        echo "FAIL missing jobs file did not return non-zero"
    else
        echo "PASS missing jobs file rejected"
    fi
)

rm -rf "$U3_DIR"

# =============================================================================
# U4 — config.sh .env + numeric validation
# =============================================================================
#
# config.sh is normally sourced by the entrypoint after ROOT_DIR is set. It
# runs its validation at source time (not inside a function), so we test it by
# spinning up a scratch ROOT_DIR with a crafted .env and sourcing it in a
# subshell. Validation failures call `exit 2`, so we capture the exit code.

header "Test U4: config.sh .env parser and numeric validation"

U4_ROOT="/tmp/lp_unit_config_$$"
mkdir -p "$U4_ROOT/lib"
# Minimal logging.sh shim so config.sh's callers (none at load time, but the
# entrypoint sources it — we mimic the subset config.sh itself touches).
# config.sh does not actually call any logging function directly; it echoes to
# stderr via plain `echo`, so we can source it standalone.
cp "$ROOT_DIR/lib/config.sh" "$U4_ROOT/lib/config.sh"

# ── Case A: CRLF .env with a comment, a blank, and a password containing '=' ──
printf '# comment line\r\nMAX_UNZIP=3\r\n\r\nFTP_PASS=pw=with=equals\r\n' > "$U4_ROOT/.env"

U4A_OUT=$(
    unset MAX_UNZIP FTP_PASS
    ROOT_DIR="$U4_ROOT"
    set +e
    source "$U4_ROOT/lib/config.sh" 2>/dev/null
    rc=$?
    set -e
    echo "rc=$rc"
    echo "MAX_UNZIP=${MAX_UNZIP}"
    echo "FTP_PASS=${FTP_PASS}"
)

if grep -q '^rc=0$' <<< "$U4A_OUT"; then
    pass "config loaded CRLF .env without error"
else
    fail "config.sh failed on CRLF .env"
    sed 's/^/      /' <<< "$U4A_OUT"
fi

if grep -q '^MAX_UNZIP=3$' <<< "$U4A_OUT"; then
    pass "MAX_UNZIP=3 parsed from CRLF .env"
else
    fail "MAX_UNZIP not parsed (got: $(grep MAX_UNZIP <<< "$U4A_OUT"))"
fi

if grep -q '^FTP_PASS=pw=with=equals$' <<< "$U4A_OUT"; then
    pass "password containing '=' preserved intact"
else
    fail "password with '=' was truncated: $(grep FTP_PASS <<< "$U4A_OUT")"
fi

# ── Case B: final line without trailing newline — must still be applied ──────
printf 'MAX_UNZIP=7' > "$U4_ROOT/.env"       # no trailing \n deliberately

U4B_OUT=$(
    unset MAX_UNZIP
    ROOT_DIR="$U4_ROOT"
    set +e
    source "$U4_ROOT/lib/config.sh" 2>/dev/null
    echo "MAX_UNZIP=$MAX_UNZIP"
)
if grep -q '^MAX_UNZIP=7$' <<< "$U4B_OUT"; then
    pass "final-line-no-newline .env applied"
else
    fail "final-line-no-newline dropped: $U4B_OUT"
fi

# ── Case C: MAX_UNZIP=0 triggers numeric-validation exit 2 ───────────────────
printf 'MAX_UNZIP=0\n' > "$U4_ROOT/.env"

U4C_RC=0
(
    unset MAX_UNZIP
    ROOT_DIR="$U4_ROOT"
    source "$U4_ROOT/lib/config.sh"
) >/dev/null 2>&1 || U4C_RC=$?

if (( U4C_RC == 2 )); then
    pass "MAX_UNZIP=0 rejected with exit 2"
else
    fail "expected exit 2 for MAX_UNZIP=0, got $U4C_RC"
fi

# ── Case D: MAX_UNZIP=not-a-number triggers exit 2 ───────────────────────────
printf 'MAX_UNZIP=abc\n' > "$U4_ROOT/.env"

U4D_RC=0
(
    unset MAX_UNZIP
    ROOT_DIR="$U4_ROOT"
    source "$U4_ROOT/lib/config.sh"
) >/dev/null 2>&1 || U4D_RC=$?

if (( U4D_RC == 2 )); then
    pass "MAX_UNZIP=abc rejected with exit 2"
else
    fail "expected exit 2 for MAX_UNZIP=abc, got $U4D_RC"
fi

# ── Case E: DISPATCH_POLL_INITIAL_MS > DISPATCH_POLL_MAX_MS triggers exit 2 ──
printf 'DISPATCH_POLL_INITIAL_MS=1000\nDISPATCH_POLL_MAX_MS=500\n' > "$U4_ROOT/.env"

U4E_RC=0
U4E_ERR=$( (
    unset DISPATCH_POLL_INITIAL_MS DISPATCH_POLL_MAX_MS
    ROOT_DIR="$U4_ROOT"
    source "$U4_ROOT/lib/config.sh"
) 2>&1 ) || U4E_RC=$?

if (( U4E_RC == 2 )) && grep -q 'DISPATCH_POLL_INITIAL_MS' <<< "$U4E_ERR"; then
    pass "DISPATCH_POLL_INITIAL_MS > _MAX_MS rejected with actionable error"
else
    fail "expected exit 2 with DISPATCH_POLL_* ordering error (rc=$U4E_RC)"
    sed 's/^/      /' <<< "$U4E_ERR"
fi

# ── Case F: SPACE_RETRY_BACKOFF_INITIAL_SEC accepts decimals ─────────────────
printf 'SPACE_RETRY_BACKOFF_INITIAL_SEC=0.25\n' > "$U4_ROOT/.env"

U4F_RC=0
U4F_OUT=$(
    unset SPACE_RETRY_BACKOFF_INITIAL_SEC
    ROOT_DIR="$U4_ROOT"
    source "$U4_ROOT/lib/config.sh" 2>/dev/null
    echo "val=$SPACE_RETRY_BACKOFF_INITIAL_SEC"
) || U4F_RC=$?

if (( U4F_RC == 0 )) && grep -q '^val=0.25$' <<< "$U4F_OUT"; then
    pass "SPACE_RETRY_BACKOFF_INITIAL_SEC accepts decimal values"
else
    fail "decimal SPACE_RETRY_BACKOFF_INITIAL_SEC rejected (rc=$U4F_RC)"
fi

# ── Case G: SPACE_RETRY_BACKOFF_INITIAL_SEC with unit suffix must be rejected ─
printf 'SPACE_RETRY_BACKOFF_INITIAL_SEC=5s\n' > "$U4_ROOT/.env"

U4G_RC=0
(
    unset SPACE_RETRY_BACKOFF_INITIAL_SEC
    ROOT_DIR="$U4_ROOT"
    source "$U4_ROOT/lib/config.sh"
) >/dev/null 2>&1 || U4G_RC=$?

if (( U4G_RC == 2 )); then
    pass "unit-suffixed backoff value rejected (exit 2)"
else
    fail "expected exit 2 for '5s', got $U4G_RC"
fi

rm -rf "$U4_ROOT"
