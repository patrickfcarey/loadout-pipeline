#!/usr/bin/env bash
# test/suites/17_unit_extract_internals.sh
#
# Unit tests for the two post-extraction helpers defined inside the top-level
# body of lib/extract.sh:
#
#   E1–E3  _strip_pass          (pre- and post-flatten strip list pass)
#   E4–E7  _maybe_flatten_wrapper (single-wrapper-dir flatten decision)
#
# Both functions live inside extract.sh's main `set -euo pipefail` body, so we
# cannot `source` the file — it would try to run as a worker. Instead we use
# the same awk-extraction pattern suite 15 uses for _precheck_member_is_safe:
# pull out just the function body with an awk script, eval it inside a
# subshell, and call it directly against hand-built scratch directories.
#
# set -e trap: process-substitution subshells inherit `set -e` from
# run_tests.sh, so every subshell body must avoid `(( x++ ))` post-increments
# (which return exit 1 when the pre-value is 0) and similar expressions that
# evaluate to 0. Use `x=$((x+1))` or `((++x))` consistently.

_u_run_subshell() {
    while IFS= read -r line; do
        case "$line" in
            PASS*) pass "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
        esac
    done
}

# Shared awk extractor: pulls the body of ONE function named in $1 from
# lib/extract.sh. Used by every test below so the function definition never
# drifts from the real extract.sh source.
_ex_extract_fn() {
    local fn_name="$1"
    awk -v fn="$fn_name" '
        $0 ~ "^" fn "\\(\\)"  { capture=1 }
        capture               { print }
        capture && /^\}/      { capture=0 }
    ' "$ROOT_DIR/lib/extract.sh"
}

# =============================================================================
# E1 — _strip_pass removes listed files, preserves others, silent on missing
# =============================================================================

header "Test E1: _strip_pass basic strip + missing list"

E1_DIR="/tmp/lp_unit_e1_$$"
E1_LIST="/tmp/lp_unit_e1_list_$$.txt"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(_ex_extract_fn _strip_pass)"

    rm -rf "$E1_DIR"
    mkdir -p "$E1_DIR"
    touch "$E1_DIR/game.iso" "$E1_DIR/readme.txt" "$E1_DIR/Vimm's Lair.txt"

    # Strip list names one file that exists and one that does not.
    cat > "$E1_LIST" <<EOF
Vimm's Lair.txt
nonexistent.txt
EOF
    export EXTRACT_STRIP_LIST="$E1_LIST"

    _strip_pass "$E1_DIR" 2>/dev/null

    if [[ ! -e "$E1_DIR/Vimm's Lair.txt" ]]; then
        echo "PASS listed file removed"
    else
        echo "FAIL listed file still present"
    fi
    if [[ -f "$E1_DIR/game.iso" ]]; then
        echo "PASS non-listed file preserved"
    else
        echo "FAIL non-listed file deleted"
    fi
    if [[ -f "$E1_DIR/readme.txt" ]]; then
        echo "PASS unrelated file preserved"
    else
        echo "FAIL unrelated file deleted"
    fi

    # Missing strip list: silent no-op, tree untouched.
    rm -f "$E1_LIST"
    export EXTRACT_STRIP_LIST="$E1_LIST"
    rc=0
    _strip_pass "$E1_DIR" 2>/dev/null || rc=$?
    if (( rc == 0 )); then
        echo "PASS missing strip list returns 0"
    else
        echo "FAIL missing strip list rc=$rc"
    fi
    if [[ -f "$E1_DIR/game.iso" && -f "$E1_DIR/readme.txt" ]]; then
        echo "PASS missing list leaves tree untouched"
    else
        echo "FAIL missing list mutated tree"
    fi
)

rm -rf "$E1_DIR"
rm -f "$E1_LIST"

# =============================================================================
# E2 — _strip_pass refuses entries containing '/'
# =============================================================================

header "Test E2: _strip_pass rejects entries with '/'"

E2_DIR="/tmp/lp_unit_e2_$$"
E2_LIST="/tmp/lp_unit_e2_list_$$.txt"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(_ex_extract_fn _strip_pass)"

    rm -rf "$E2_DIR"
    mkdir -p "$E2_DIR/subdir"
    touch "$E2_DIR/subdir/foo" "$E2_DIR/foo"

    cat > "$E2_LIST" <<EOF
subdir/foo
EOF
    export EXTRACT_STRIP_LIST="$E2_LIST"

    out=$(_strip_pass "$E2_DIR" 2>&1)

    if [[ -f "$E2_DIR/subdir/foo" ]]; then
        echo "PASS entry with '/' did not descend into subdir"
    else
        echo "FAIL subdir/foo was deleted despite containing '/'"
    fi
    if [[ -f "$E2_DIR/foo" ]]; then
        echo "PASS bare-name file NOT matched by entry with '/'"
    else
        echo "FAIL bare-name foo was deleted by a slash-entry match"
    fi
    if grep -q "only bare filenames are supported" <<< "$out"; then
        echo "PASS warning logged for entry with '/'"
    else
        echo "FAIL expected warning about slash, got: $out"
    fi
)

rm -rf "$E2_DIR"
rm -f "$E2_LIST"

# =============================================================================
# E3 — _strip_pass ignores blank and comment lines
# =============================================================================

header "Test E3: _strip_pass comment + blank handling"

E3_DIR="/tmp/lp_unit_e3_$$"
E3_LIST="/tmp/lp_unit_e3_list_$$.txt"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(_ex_extract_fn _strip_pass)"

    rm -rf "$E3_DIR"
    mkdir -p "$E3_DIR"
    touch "$E3_DIR/keep.txt" "$E3_DIR/cruft.txt" "$E3_DIR/comment.txt"

    # Blank line, comment, entry with leading/trailing whitespace, and a
    # real entry. Only cruft.txt should be deleted.
    printf '\n# comment.txt\n   \ncruft.txt   \nkeep.txt.notme\n' > "$E3_LIST"
    export EXTRACT_STRIP_LIST="$E3_LIST"

    rc=0
    _strip_pass "$E3_DIR" 2>/dev/null || rc=$?
    if (( rc == 0 )); then
        echo "PASS comment/blank handling returns 0"
    else
        echo "FAIL rc=$rc"
    fi
    if [[ ! -e "$E3_DIR/cruft.txt" ]]; then
        echo "PASS real entry (with trailing spaces stripped) removed"
    else
        echo "FAIL cruft.txt still present"
    fi
    if [[ -f "$E3_DIR/comment.txt" ]]; then
        echo "PASS comment line did NOT trigger deletion"
    else
        echo "FAIL comment.txt deleted by comment line match"
    fi
    if [[ -f "$E3_DIR/keep.txt" ]]; then
        echo "PASS file not in list preserved"
    else
        echo "FAIL keep.txt unexpectedly deleted"
    fi
)

rm -rf "$E3_DIR"
rm -f "$E3_LIST"

# =============================================================================
# E4 — _maybe_flatten_wrapper lifts a single wrapper dir
# =============================================================================

header "Test E4: _maybe_flatten_wrapper single wrapper"

E4_DIR="/tmp/lp_unit_e4_$$"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(_ex_extract_fn _maybe_flatten_wrapper)"

    rm -rf "$E4_DIR"
    mkdir -p "$E4_DIR/MyGame"
    touch "$E4_DIR/MyGame/game.iso" "$E4_DIR/MyGame/game.cue"

    rc=0
    _maybe_flatten_wrapper "$E4_DIR" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
        echo "PASS flatten returned 0"
    else
        echo "FAIL flatten rc=$rc"
    fi
    if [[ ! -e "$E4_DIR/MyGame" ]]; then
        echo "PASS wrapper directory removed"
    else
        echo "FAIL wrapper 'MyGame' still present"
    fi
    if [[ -f "$E4_DIR/game.iso" && -f "$E4_DIR/game.cue" ]]; then
        echo "PASS wrapper contents lifted to top level"
    else
        echo "FAIL contents did not reach top level"
    fi
)

rm -rf "$E4_DIR"

# =============================================================================
# E5 — _maybe_flatten_wrapper refuses ambiguous layouts
# =============================================================================

header "Test E5: _maybe_flatten_wrapper ambiguous refusals"

E5A_DIR="/tmp/lp_unit_e5a_$$"
E5B_DIR="/tmp/lp_unit_e5b_$$"
E5C_DIR="/tmp/lp_unit_e5c_$$"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(_ex_extract_fn _maybe_flatten_wrapper)"

    # Case A: wrapper dir + loose file → ambiguous.
    rm -rf "$E5A_DIR"
    mkdir -p "$E5A_DIR/Game"
    touch "$E5A_DIR/Game/payload.iso" "$E5A_DIR/sibling.txt"
    rc=0
    out=$(_maybe_flatten_wrapper "$E5A_DIR" 2>&1) || rc=$?
    if (( rc == 1 )); then
        echo "PASS wrapper+file ambiguous returns 1"
    else
        echo "FAIL wrapper+file rc=$rc"
    fi
    if [[ -d "$E5A_DIR/Game" && -f "$E5A_DIR/sibling.txt" ]]; then
        echo "PASS wrapper+file tree untouched on refuse"
    else
        echo "FAIL wrapper+file tree mutated"
    fi
    if grep -q "cannot flatten wrapper" <<< "$out"; then
        echo "PASS wrapper+file logged flatten error"
    else
        echo "FAIL expected flatten error log, got: $out"
    fi

    # Case B: two wrapper dirs at top → ambiguous.
    rm -rf "$E5B_DIR"
    mkdir -p "$E5B_DIR/A" "$E5B_DIR/B"
    touch "$E5B_DIR/A/a.iso" "$E5B_DIR/B/b.iso"
    rc=0
    _maybe_flatten_wrapper "$E5B_DIR" >/dev/null 2>&1 || rc=$?
    if (( rc == 1 )); then
        echo "PASS two-wrapper ambiguous returns 1"
    else
        echo "FAIL two-wrapper rc=$rc"
    fi
    if [[ -d "$E5B_DIR/A" && -d "$E5B_DIR/B" ]]; then
        echo "PASS two-wrapper tree untouched on refuse"
    else
        echo "FAIL two-wrapper tree mutated"
    fi

    # Case C: loose files only, no wrapper → dir_count==0, early return 0.
    rm -rf "$E5C_DIR"
    mkdir -p "$E5C_DIR"
    touch "$E5C_DIR/a.iso" "$E5C_DIR/b.cue"
    rc=0
    _maybe_flatten_wrapper "$E5C_DIR" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
        echo "PASS files-only returns 0 (no flatten needed)"
    else
        echo "FAIL files-only rc=$rc"
    fi
    if [[ -f "$E5C_DIR/a.iso" && -f "$E5C_DIR/b.cue" ]]; then
        echo "PASS files-only tree untouched"
    else
        echo "FAIL files-only tree mutated"
    fi
)

rm -rf "$E5A_DIR" "$E5B_DIR" "$E5C_DIR"

# =============================================================================
# E6 — _maybe_flatten_wrapper carries hidden files via dotglob
# =============================================================================

header "Test E6: _maybe_flatten_wrapper dotglob"

E6_DIR="/tmp/lp_unit_e6_$$"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(_ex_extract_fn _maybe_flatten_wrapper)"

    rm -rf "$E6_DIR"
    mkdir -p "$E6_DIR/Game"
    touch "$E6_DIR/Game/visible.iso" "$E6_DIR/Game/.hidden_meta"

    rc=0
    _maybe_flatten_wrapper "$E6_DIR" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
        echo "PASS dotglob flatten returns 0"
    else
        echo "FAIL dotglob rc=$rc"
    fi
    if [[ -f "$E6_DIR/visible.iso" ]]; then
        echo "PASS visible file lifted"
    else
        echo "FAIL visible file missing"
    fi
    if [[ -f "$E6_DIR/.hidden_meta" ]]; then
        echo "PASS hidden file lifted via dotglob"
    else
        echo "FAIL hidden file not lifted (dotglob regression)"
    fi
    if [[ ! -e "$E6_DIR/Game" ]]; then
        echo "PASS wrapper removed after lifting hidden file"
    else
        echo "FAIL wrapper still present"
    fi
)

rm -rf "$E6_DIR"

# =============================================================================
# E7 — _maybe_flatten_wrapper refuses wrapper + top-level symlink
# =============================================================================

header "Test E7: _maybe_flatten_wrapper refuses top-level symlink"

E7_DIR="/tmp/lp_unit_e7_$$"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(_ex_extract_fn _maybe_flatten_wrapper)"

    rm -rf "$E7_DIR"
    mkdir -p "$E7_DIR/Payload"
    touch "$E7_DIR/Payload/real.iso"
    # Dangling symlink — points at nothing, but the test treats it as a
    # file-count bump under the -L check. The policy is that any top-level
    # non-directory entry alongside a wrapper is ambiguous.
    ln -sf /nonexistent/target "$E7_DIR/link"

    rc=0
    out=$(_maybe_flatten_wrapper "$E7_DIR" 2>&1) || rc=$?
    if (( rc == 1 )); then
        echo "PASS wrapper+symlink ambiguous returns 1"
    else
        echo "FAIL wrapper+symlink rc=$rc (expected 1)"
    fi
    if [[ -d "$E7_DIR/Payload" && -L "$E7_DIR/link" ]]; then
        echo "PASS wrapper+symlink tree untouched on refuse"
    else
        echo "FAIL wrapper+symlink tree mutated"
    fi
    if grep -q "cannot flatten wrapper" <<< "$out"; then
        echo "PASS wrapper+symlink logged flatten error"
    else
        echo "FAIL wrapper+symlink expected flatten error log, got: $out"
    fi
)

rm -rf "$E7_DIR"
