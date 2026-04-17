#!/usr/bin/env bash
# test/suites/16_unit_lib_helpers.sh
#
# Unit tests for library helpers that had only end-to-end coverage before:
#   H1  logging gate (DEBUG_IND=0 silences log_enter/debug/trace; level-always
#        helpers log_info/warn/error remain visible; level 1 emits level-1
#        helpers but gates level-2 helpers; level 2 emits log_cmd/log_var/
#        log_fs/log_xtrace and shows rc= in the RETURN trap)
#   H2  dispatch.sh _build_strip_args — per-adapter `env -u VAR` strip list
#   H3  space.sh _space_apply_overhead — integer math including 0% and rounding
#   H4  space.sh _space_avail_bytes — SPACE_AVAIL_OVERRIDE_BYTES honoured,
#        real df path returns a positive integer for /tmp
#   H5  space.sh _space_dev — walks up to the nearest existing ancestor for
#        a path that does not exist yet; no infinite loop on a relative name
#   H6  space.sh _space_reserved_on_dev — sums per device id and per mode
#        (copy / extract / both) against a synthetic ledger
#   H7  space.sh _space_ledger_gc_phantoms — drops rows whose owner pid is
#        dead, keeps rows whose owner is alive
#
# Pattern: helpers that can be sourced (logging.sh, space.sh) are loaded in a
# subshell and called directly. Functions buried inside script files (e.g.
# `_build_strip_args` inside dispatch.sh's top-level `set -euo pipefail` body)
# are extracted with the same `awk '/^fn\(\)/,/^}/'` eval trick suite 15 uses.

_u_run_subshell() {
    while IFS= read -r line; do
        case "$line" in
            PASS*) pass "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
        esac
    done
}

# =============================================================================
# H1 — logging gate
# =============================================================================

header "Test H1: logging gate (DEBUG_IND)"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"

    # With DEBUG_IND unset/0, every debug helper must emit nothing on stderr
    # (level-1 and level-2 helpers alike). Capture stderr only — log_info
    # goes to stdout so it does not pollute the capture even when it fires.
    out=$(DEBUG_IND=0 bash -c '
        source "'"$ROOT_DIR"'/lib/logging.sh"
        log_enter
        log_debug "x"
        log_trace "y"
        log_cmd   rsync -a src/ dst/
        _v=42 && log_var _v
        log_fs    "mv a b"
        log_xtrace "z"
    ' 2>&1)
    if [[ -z "$out" ]]; then
        echo "PASS DEBUG_IND=0 silences every debug helper"
    else
        echo "FAIL DEBUG_IND=0 leaked output: $out"
    fi

    # With DEBUG_IND=1 the level-1 helpers emit; the level-2 helpers stay
    # silent. Use a wrapper function so log_enter has something more
    # interesting than 'main' as FUNCNAME[1].
    out=$(DEBUG_IND=1 bash -c '
        source "'"$ROOT_DIR"'/lib/logging.sh"
        f() { log_enter; log_debug "hello"; }
        f
        log_trace "raw-line"
    ' 2>&1)
    if grep -q '^\[DEBUG\] → f()' <<< "$out" \
       && grep -q '^\[DEBUG\]   f: hello' <<< "$out" \
       && grep -q '^\[DEBUG\] raw-line' <<< "$out"; then
        echo "PASS DEBUG_IND=1 emits log_enter/debug/trace"
    else
        echo "FAIL DEBUG_IND=1 did not emit all three: $out"
    fi

    # Level 1 must gate out level-2 helpers. log_cmd/log_var/log_fs/
    # log_xtrace only fire at level 2. Without this gate, level 1 would
    # become as chatty as level 2 and the two levels would collapse.
    out=$(DEBUG_IND=1 bash -c '
        source "'"$ROOT_DIR"'/lib/logging.sh"
        log_cmd rsync -a src/ dst/
        _v=42 && log_var _v
        log_fs    "mv a b"
        log_xtrace "z"
    ' 2>&1)
    if ! grep -q 'DEBUG2' <<< "$out"; then
        echo "PASS DEBUG_IND=1 gates level-2 helpers"
    else
        echo "FAIL DEBUG_IND=1 leaked level-2 output: $out"
    fi

    # At level 2, every level-2 helper fires AND every level-1 helper
    # still fires. Also the RETURN trap includes rc= so a non-zero exit
    # is visible without grepping for it.
    #
    # Note: bash captures $? inside a RETURN trap from the last command
    # executed in the function body, not from an explicit `return N`. So
    # g() uses `false` as its final command to propagate rc=1 naturally.
    # Using `return 7` instead would show rc=0 because the RETURN trap
    # fires before the explicit return value becomes $?.
    out=$(DEBUG_IND=2 bash -c '
        _wrap() {
            f() { log_enter "arg1 arg2"; log_cmd rsync -a src/ dst/; return 0; }
            g() { log_enter; false; }
            _v=hello; log_var _v
            log_fs    "mv a b"
            log_xtrace "raw2"
            f
            g || true
        }
        source "'"$ROOT_DIR"'/lib/logging.sh"
        _wrap
    ' 2>&1)
    if grep -q '^\[DEBUG2\] cmd: rsync -a src/ dst/' <<< "$out" \
       && grep -q '^\[DEBUG2\]   _wrap: _v=hello' <<< "$out" \
       && grep -q '^\[DEBUG2\] fs: mv a b' <<< "$out" \
       && grep -q '^\[DEBUG2\] raw2' <<< "$out" \
       && grep -q '^\[DEBUG\] → f(arg1 arg2)' <<< "$out" \
       && grep -q '^\[DEBUG\] ← f() rc=0' <<< "$out" \
       && grep -q '^\[DEBUG\] ← g() rc=1' <<< "$out"; then
        echo "PASS DEBUG_IND=2 emits level-2 helpers + rc-bearing RETURN trap"
    else
        echo "FAIL DEBUG_IND=2 missing expected output: $out"
    fi

    # log_info always prints to stdout, even with DEBUG_IND=0. log_warn and
    # log_error always print to stderr, regardless of DEBUG_IND.
    out=$(DEBUG_IND=0 bash -c '
        source "'"$ROOT_DIR"'/lib/logging.sh"
        log_info  "info-msg"
        log_warn  "warn-msg" 2>&1 1>/dev/null
        log_error "err-msg"  2>&1 1>/dev/null
    ')
    if grep -q 'info-msg' <<< "$out" \
       && grep -q 'warn-msg' <<< "$out" \
       && grep -q 'err-msg' <<< "$out"; then
        echo "PASS log_info/warn/error always visible regardless of DEBUG_IND"
    else
        echo "FAIL level-always helpers missing output: $out"
    fi
)

# =============================================================================
# H2 — dispatch.sh _build_strip_args
# =============================================================================

header "Test H2: _build_strip_args"

_u_run_subshell < <(
    # Pull in the readonly env-var arrays AND the _build_strip_args function
    # body from dispatch.sh. `source` will not work because dispatch.sh runs
    # under set -euo pipefail and expects $1 $2 $3 positional args. We extract
    # just the pieces we need: the arrays (readonly lines) and the function.
    eval "$(awk '
        /^readonly _FTP_ENV_VARS=/    { print }
        /^readonly _HDL_ENV_VARS=/    { print }
        /^readonly _LVOL_ENV_VARS=/     { print }
        /^readonly _RCLONE_ENV_VARS=/ { print }
        /^readonly _RSYNC_ENV_VARS=/  { print }
        /^_build_strip_args\(\)/      { capture=1 }
        capture                       { print }
        capture && /^\}/              { capture=0 }
    ' "$ROOT_DIR/lib/dispatch.sh")"

    declare -a _strip_args=()

    # Helper: membership test inside _strip_args.
    _has_strip() {
        local needle="$1" arg
        for arg in "${_strip_args[@]}"; do
            [[ "$arg" == "$needle" ]] && return 0
        done
        return 1
    }

    # keep=_FTP_ENV_VARS → no FTP vars in strip list, every other adapter's
    # vars are present.
    _build_strip_args _FTP_ENV_VARS
    if ! _has_strip FTP_HOST && ! _has_strip FTP_USER \
       && _has_strip HDL_DUMP_BIN \
       && _has_strip LVOL_MOUNT_POINT \
       && _has_strip RCLONE_REMOTE \
       && _has_strip RSYNC_HOST; then
        echo "PASS keep=_FTP_ENV_VARS retains FTP vars and strips others"
    else
        echo "FAIL _FTP_ENV_VARS strip list wrong: ${_strip_args[*]}"
    fi

    # Each slot in the strip list should be paired with -u (the `env` flag).
    # Count -u occurrences; it must equal the number of actual var names.
    # Pre-increment (not post-increment): `(( x++ ))` returns exit 1 when the
    # pre-value is 0, and the subshell inherits set -e from run_tests.sh so a
    # single post-increment would abort the block silently.
    dashu_count=0
    for arg in "${_strip_args[@]}"; do
        [[ "$arg" == "-u" ]] && dashu_count=$((dashu_count + 1))
    done
    var_count=$(( ${#_strip_args[@]} - dashu_count ))
    if (( dashu_count == var_count )); then
        echo "PASS strip list pairs every -u with a var name"
    else
        echo "FAIL mismatched pairing: -u=$dashu_count vars=$var_count"
    fi

    # Round-trip every adapter: the kept array must not appear; every other
    # group must appear. Sample one var per group so the check is cheap.
    for keep in _HDL_ENV_VARS _LVOL_ENV_VARS _RCLONE_ENV_VARS _RSYNC_ENV_VARS; do
        _build_strip_args "$keep"
        case "$keep" in
            _HDL_ENV_VARS)
                if ! _has_strip HDL_DUMP_BIN && _has_strip FTP_HOST; then
                    echo "PASS keep=$keep keeps HDL vars, strips FTP"
                else
                    echo "FAIL keep=$keep got: ${_strip_args[*]}"
                fi
                ;;
            _LVOL_ENV_VARS)
                if ! _has_strip LVOL_MOUNT_POINT && _has_strip RCLONE_REMOTE; then
                    echo "PASS keep=$keep keeps LVOL vars, strips RCLONE"
                else
                    echo "FAIL keep=$keep got: ${_strip_args[*]}"
                fi
                ;;
            _RCLONE_ENV_VARS)
                if ! _has_strip RCLONE_REMOTE && _has_strip RSYNC_HOST; then
                    echo "PASS keep=$keep keeps RCLONE vars, strips RSYNC"
                else
                    echo "FAIL keep=$keep got: ${_strip_args[*]}"
                fi
                ;;
            _RSYNC_ENV_VARS)
                if ! _has_strip RSYNC_HOST && _has_strip LVOL_MOUNT_POINT; then
                    echo "PASS keep=$keep keeps RSYNC vars, strips SD"
                else
                    echo "FAIL keep=$keep got: ${_strip_args[*]}"
                fi
                ;;
        esac
    done
)

# =============================================================================
# H3 — _space_apply_overhead
# =============================================================================

header "Test H3: _space_apply_overhead"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    # Stub QUEUE_DIR so space.sh's path helpers do not error when sourced.
    export QUEUE_DIR="/tmp/lp_unit_h3_qdir_$$"
    mkdir -p "$QUEUE_DIR"
    source "$ROOT_DIR/lib/space.sh"

    # Default overhead is 20%.
    unset SPACE_OVERHEAD_PCT
    if [[ "$(_space_apply_overhead 1000)" == "1200" ]]; then
        echo "PASS default 20% overhead: 1000 → 1200"
    else
        echo "FAIL default overhead wrong: $(_space_apply_overhead 1000)"
    fi

    # 0% overhead: passthrough.
    SPACE_OVERHEAD_PCT=0
    if [[ "$(_space_apply_overhead 1000)" == "1000" ]]; then
        echo "PASS 0% overhead is identity"
    else
        echo "FAIL 0% overhead wrong: $(_space_apply_overhead 1000)"
    fi

    # Custom 50% overhead.
    SPACE_OVERHEAD_PCT=50
    if [[ "$(_space_apply_overhead 200)" == "300" ]]; then
        echo "PASS 50% overhead: 200 → 300"
    else
        echo "FAIL 50% overhead wrong: $(_space_apply_overhead 200)"
    fi

    # Zero input returns zero regardless of percentage.
    SPACE_OVERHEAD_PCT=20
    if [[ "$(_space_apply_overhead 0)" == "0" ]]; then
        echo "PASS zero bytes → zero"
    else
        echo "FAIL zero input wrong: $(_space_apply_overhead 0)"
    fi

    # Integer floor: 7 × 120 / 100 = 840 / 100 = 8 (floor).
    SPACE_OVERHEAD_PCT=20
    if [[ "$(_space_apply_overhead 7)" == "8" ]]; then
        echo "PASS integer floor: 7 × 1.20 = 8"
    else
        echo "FAIL integer floor wrong: $(_space_apply_overhead 7)"
    fi

    rm -rf "$QUEUE_DIR"
)

# =============================================================================
# H4 — _space_avail_bytes
# =============================================================================

header "Test H4: _space_avail_bytes"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    export QUEUE_DIR="/tmp/lp_unit_h4_qdir_$$"
    mkdir -p "$QUEUE_DIR"
    source "$ROOT_DIR/lib/space.sh"

    # Override hook: should print the exact override string, regardless of
    # what df would say.
    export SPACE_AVAIL_OVERRIDE_BYTES=4242
    out=$(_space_avail_bytes /tmp)
    if [[ "$out" == "4242" ]]; then
        echo "PASS SPACE_AVAIL_OVERRIDE_BYTES honoured"
    else
        echo "FAIL override ignored: got '$out'"
    fi

    # Real path: df on /tmp must yield a positive integer.
    unset SPACE_AVAIL_OVERRIDE_BYTES
    out=$(_space_avail_bytes /tmp)
    if [[ "$out" =~ ^[0-9]+$ ]] && (( out > 0 )); then
        echo "PASS real df returned positive integer ($out bytes)"
    else
        echo "FAIL real df returned non-integer or zero: '$out'"
    fi

    # Non-existent path: should walk up to an existing ancestor and still
    # return a positive integer.
    out=$(_space_avail_bytes "/tmp/lp_unit_h4_does_not_exist_$$/also_missing")
    if [[ "$out" =~ ^[0-9]+$ ]] && (( out > 0 )); then
        echo "PASS non-existent path walks up to existing ancestor"
    else
        echo "FAIL non-existent path lookup: '$out'"
    fi

    rm -rf "$QUEUE_DIR"
)

# =============================================================================
# H5 — _space_dev ancestor walk
# =============================================================================

header "Test H5: _space_dev"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    export QUEUE_DIR="/tmp/lp_unit_h5_qdir_$$"
    mkdir -p "$QUEUE_DIR"
    source "$ROOT_DIR/lib/space.sh"

    # Same filesystem, existing path → numeric device id.
    dev1=$(_space_dev /tmp)
    if [[ "$dev1" =~ ^[0-9]+$ ]] && (( dev1 > 0 )); then
        echo "PASS /tmp returns positive numeric device id"
    else
        echo "FAIL /tmp device id: '$dev1'"
    fi

    # Missing subdir under /tmp should walk up and match /tmp's device id.
    dev2=$(_space_dev "/tmp/lp_unit_h5_never/nested/missing")
    if [[ "$dev2" == "$dev1" ]]; then
        echo "PASS missing path walks up to parent device id"
    else
        echo "FAIL missing path dev=$dev2 (expected $dev1)"
    fi

    # Pathological relative path with no slash: must not spin forever.
    # Run under a 5s timeout — if the loop is broken the test hangs here.
    if out=$(timeout 5 bash -c '
        source "'"$ROOT_DIR"'/lib/logging.sh"
        export QUEUE_DIR="'"$QUEUE_DIR"'"
        source "'"$ROOT_DIR"'/lib/space.sh"
        _space_dev "nonexistent_relative_xyz_$$"
    '); then
        if [[ "$out" =~ ^[0-9]+$ ]]; then
            echo "PASS relative path with no slash terminated and returned '$out'"
        else
            echo "FAIL relative path returned non-numeric: '$out'"
        fi
    else
        echo "FAIL relative path timed out — infinite loop regression"
    fi

    rm -rf "$QUEUE_DIR"
)

# =============================================================================
# H6 — _space_reserved_on_dev per mode
# =============================================================================

header "Test H6: _space_reserved_on_dev"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    export QUEUE_DIR="/tmp/lp_unit_h6_qdir_$$"
    mkdir -p "$QUEUE_DIR"
    source "$ROOT_DIR/lib/space.sh"

    # Write a synthetic ledger with known rows:
    #   id  copy_dev  copy_bytes  extract_dev  extract_bytes  owner_pid
    #
    # Three scenarios on two devices (42 and 99):
    #   row A: copy=42/100, extract=42/200 (same fs)     → both=300 on dev 42
    #   row B: copy=42/50,  extract=99/500 (split)       → copy=50 on 42, extract=500 on 99
    #   row C: copy=99/7,   extract=99/13  (same fs)     → both=20 on dev 99
    cat > "$(_space_ledger_path)" <<EOF
idA 42 100 42 200 $$
idB 42 50 99 500 $$
idC 99 7 99 13 $$
EOF

    # dev=42 copy → 100 (A) + 50 (B) = 150
    if [[ "$(_space_reserved_on_dev 42 copy)" == "150" ]]; then
        echo "PASS dev=42 copy sum = 150"
    else
        echo "FAIL dev=42 copy sum = $(_space_reserved_on_dev 42 copy)"
    fi

    # dev=42 extract → 200 (A, B is on dev 99 for extract)
    if [[ "$(_space_reserved_on_dev 42 extract)" == "200" ]]; then
        echo "PASS dev=42 extract sum = 200"
    else
        echo "FAIL dev=42 extract sum = $(_space_reserved_on_dev 42 extract)"
    fi

    # dev=42 both → copy(150) + extract(200) = 350
    if [[ "$(_space_reserved_on_dev 42 both)" == "350" ]]; then
        echo "PASS dev=42 both sum = 350"
    else
        echo "FAIL dev=42 both sum = $(_space_reserved_on_dev 42 both)"
    fi

    # dev=99 copy → 7 (C); B is on dev 42 for copy
    if [[ "$(_space_reserved_on_dev 99 copy)" == "7" ]]; then
        echo "PASS dev=99 copy sum = 7"
    else
        echo "FAIL dev=99 copy sum = $(_space_reserved_on_dev 99 copy)"
    fi

    # dev=99 extract → 500 (B) + 13 (C) = 513
    if [[ "$(_space_reserved_on_dev 99 extract)" == "513" ]]; then
        echo "PASS dev=99 extract sum = 513"
    else
        echo "FAIL dev=99 extract sum = $(_space_reserved_on_dev 99 extract)"
    fi

    # dev=99 both → 7 + 513 = 520
    if [[ "$(_space_reserved_on_dev 99 both)" == "520" ]]; then
        echo "PASS dev=99 both sum = 520"
    else
        echo "FAIL dev=99 both sum = $(_space_reserved_on_dev 99 both)"
    fi

    # Unknown device → 0
    if [[ "$(_space_reserved_on_dev 7777 both)" == "0" ]]; then
        echo "PASS unknown dev returns 0"
    else
        echo "FAIL unknown dev = $(_space_reserved_on_dev 7777 both)"
    fi

    # Missing ledger → 0
    rm -f "$(_space_ledger_path)"
    if [[ "$(_space_reserved_on_dev 42 both)" == "0" ]]; then
        echo "PASS missing ledger returns 0"
    else
        echo "FAIL missing ledger = $(_space_reserved_on_dev 42 both)"
    fi

    rm -rf "$QUEUE_DIR"
)

# =============================================================================
# H7 — _space_ledger_gc_phantoms drops dead-pid rows
# =============================================================================

header "Test H7: _space_ledger_gc_phantoms"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    export QUEUE_DIR="/tmp/lp_unit_h7_qdir_$$"
    mkdir -p "$QUEUE_DIR"
    source "$ROOT_DIR/lib/space.sh"

    # Find a pid that is guaranteed dead: spawn a child, capture its pid, wait
    # until it exits. Reuse for the ledger row.
    (true) &
    dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true
    if kill -0 "$dead_pid" 2>/dev/null; then
        echo "FAIL could not synthesize a dead pid — host recycled it faster than expected"
        exit 0
    fi

    # Live pid: our own. $$ is the test shell's pid, always alive while this
    # test is running.
    live_pid=$$

    # Make the ledger writable by writing a row for each.
    cat > "$(_space_ledger_path)" <<EOF
live 42 100 42 200 $live_pid
dead 42 50 42 150 $dead_pid
EOF

    # Call GC via subshell flock — the function expects to run already under
    # the lock. We can invoke it directly since we are the only writer.
    _space_ledger_gc_phantoms

    # The live row must remain, the dead row must be gone.
    if grep -q "^live " "$(_space_ledger_path)"; then
        echo "PASS live row preserved after GC"
    else
        echo "FAIL live row disappeared after GC"
        cat "$(_space_ledger_path)" | sed 's/^/      /'
    fi
    if ! grep -q "^dead " "$(_space_ledger_path)"; then
        echo "PASS dead-pid row evicted by GC"
    else
        echo "FAIL dead-pid row still present after GC"
        cat "$(_space_ledger_path)" | sed 's/^/      /'
    fi

    # Empty-ledger path: GC must be a no-op (return 0, file still empty).
    : > "$(_space_ledger_path)"
    if _space_ledger_gc_phantoms; then
        echo "PASS empty ledger GC is a no-op"
    else
        echo "FAIL empty ledger GC returned non-zero"
    fi

    # Missing ledger path: GC must also be a no-op.
    rm -f "$(_space_ledger_path)"
    if _space_ledger_gc_phantoms; then
        echo "PASS missing ledger GC is a no-op"
    else
        echo "FAIL missing ledger GC returned non-zero"
    fi

    rm -rf "$QUEUE_DIR"
)
