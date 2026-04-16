#!/usr/bin/env bash
# test/suites/21_smart_wrapper.sh
#
# Unit tests for tools/loadout-pipeline_smart.sh — the gum-powered interactive
# wrapper. Every testable function is exercised in a subshell that sources the
# wrapper (the guard at the bottom prevents main() from running). Interactive
# prompts are not tested here; only the pure-logic functions are covered.
#
# Coverage
#   U21a  _resolve_root_dir — ROOT_DIR computation from BASH_SOURCE
#   U21b  _detect_pipeline_entry — dist/ preferred, bin/ fallback, neither → error
#   U21c  _load_dotenv — .env parsing, defaults, caller-wins, CRLF, comments
#   U21d  _detect_adapters — single, multi, unknown, comments-only, directory
#   U21e  _val_pos_int — positive integer validation
#   U21f  _val_nn_int — non-negative integer validation
#   U21g  _val_nn_decimal — non-negative decimal validation
#   U21h  _val_nonempty — non-empty string validation
#   U21i  _val_path_writable — writable path validation
#   U21j  _validate_all — full validation engine with cross-var constraints
#   U21k  _check_gum — gum presence detection
#   U21l  _pick_path — WSL uses gum filter, native Linux uses gum file
#   U21m  _action_status — status state machine for each action key
#   U21n  _build_menu — array population, dynamic adapter items, numbering
#   U21o  _mask_value, _input_header, _DOTENV/_DEFAULTS — context display helpers

SMART_WRAPPER="$ROOT_DIR/tools/loadout-pipeline_smart.sh"

_u_run_subshell() {
    while IFS= read -r line; do
        case "$line" in
            PASS*) pass "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
        esac
    done
}

# =============================================================================
# U21a — _resolve_root_dir
# =============================================================================

header "Test U21a: _resolve_root_dir"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    _resolve_root_dir

    if [[ -d "$ROOT_DIR/lib" && -d "$ROOT_DIR/bin" && -d "$ROOT_DIR/tools" ]]; then
        echo "PASS _resolve_root_dir found repo root with lib/, bin/, tools/"
    else
        echo "FAIL _resolve_root_dir set ROOT_DIR='$ROOT_DIR' which lacks expected subdirs"
    fi

    if [[ -f "$ROOT_DIR/tools/loadout-pipeline_smart.sh" ]]; then
        echo "PASS ROOT_DIR contains the smart wrapper itself"
    else
        echo "FAIL ROOT_DIR='$ROOT_DIR' does not contain tools/loadout-pipeline_smart.sh"
    fi
)

# =============================================================================
# U21b — _detect_pipeline_entry
# =============================================================================

header "Test U21b: _detect_pipeline_entry"

_u_run_subshell < <(
    source "$SMART_WRAPPER"
    _resolve_root_dir

    # Case 1: both dist/ and bin/ exist → dist/ preferred
    if [[ -f "$ROOT_DIR/dist/loadout-pipeline.sh" && -f "$ROOT_DIR/bin/loadout-pipeline.sh" ]]; then
        _detect_pipeline_entry
        if [[ "$PIPELINE_ENTRY" == "$ROOT_DIR/dist/loadout-pipeline.sh" ]]; then
            echo "PASS prefers dist/ when both exist"
        else
            echo "FAIL expected dist/ but got '$PIPELINE_ENTRY'"
        fi
    else
        # Only bin/ exists (no dist/ build) — that's the expected fallback
        _detect_pipeline_entry
        if [[ "$PIPELINE_ENTRY" == "$ROOT_DIR/bin/loadout-pipeline.sh" ]]; then
            echo "PASS falls back to bin/ when dist/ absent"
        else
            echo "FAIL expected bin/ fallback but got '$PIPELINE_ENTRY'"
        fi
    fi

    # Case 2: simulate neither existing
    _saved_root="$ROOT_DIR"
    ROOT_DIR="/tmp/nonexistent_pipeline_root_$$"
    mkdir -p "$ROOT_DIR"
    if _detect_pipeline_entry 2>/dev/null; then
        echo "FAIL should have failed with no entry point"
    else
        echo "PASS correctly fails when no entry point found"
    fi
    rmdir "$ROOT_DIR"
    ROOT_DIR="$_saved_root"
)

# =============================================================================
# U21c — _load_dotenv
# =============================================================================

header "Test U21c: _load_dotenv"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # Test with a synthetic .env in a temp ROOT_DIR
    _tmp_root="/tmp/lp_smart_dotenv_$$"
    mkdir -p "$_tmp_root"

    # Write a .env with various edge cases
    printf 'MAX_UNZIP=4\n'                   > "$_tmp_root/.env"
    printf 'MAX_DISPATCH=6\n'               >> "$_tmp_root/.env"
    printf '# this is a comment\n'          >> "$_tmp_root/.env"
    printf '\n'                             >> "$_tmp_root/.env"
    printf 'FTP_PASS=s3cr=t#val\n'          >> "$_tmp_root/.env"
    printf 'CRLF_VAR=crlf_value\r\n'       >> "$_tmp_root/.env"
    printf '  SPACE_KEY=spaced\n'           >> "$_tmp_root/.env"

    ROOT_DIR="$_tmp_root"
    # Unset vars that _load_dotenv would set via defaults
    unset MAX_UNZIP MAX_DISPATCH FTP_PASS CRLF_VAR SPACE_KEY 2>/dev/null || true

    _load_dotenv

    # .env values loaded
    if [[ "$MAX_UNZIP" == "4" ]]; then
        echo "PASS MAX_UNZIP=4 loaded from .env"
    else
        echo "FAIL MAX_UNZIP expected '4', got '$MAX_UNZIP'"
    fi

    if [[ "$MAX_DISPATCH" == "6" ]]; then
        echo "PASS MAX_DISPATCH=6 loaded from .env"
    else
        echo "FAIL MAX_DISPATCH expected '6', got '$MAX_DISPATCH'"
    fi

    # Password with '=' preserved (split on first '=' only)
    if [[ "$FTP_PASS" == "s3cr=t#val" ]]; then
        echo "PASS FTP_PASS with '=' and '#' preserved"
    else
        echo "FAIL FTP_PASS expected 's3cr=t#val', got '$FTP_PASS'"
    fi

    # CRLF trimming
    if [[ "$CRLF_VAR" == "crlf_value" ]]; then
        echo "PASS CRLF trailing CR trimmed"
    else
        echo "FAIL CRLF_VAR expected 'crlf_value', got '$(printf '%q' "$CRLF_VAR")'"
    fi

    # Caller-wins: set a var before loading, .env must not override
    unset MAX_UNZIP 2>/dev/null || true
    export MAX_UNZIP=99
    ROOT_DIR="$_tmp_root"
    _load_dotenv
    if [[ "$MAX_UNZIP" == "99" ]]; then
        echo "PASS caller-wins: MAX_UNZIP=99 not overridden by .env"
    else
        echo "FAIL caller-wins: MAX_UNZIP expected '99', got '$MAX_UNZIP'"
    fi

    rm -rf "$_tmp_root"

    # Test without .env: defaults applied
    _tmp_root2="/tmp/lp_smart_dotenv_noenv_$$"
    mkdir -p "$_tmp_root2"
    ROOT_DIR="$_tmp_root2"
    unset MAX_UNZIP MAX_DISPATCH QUEUE_DIR EXTRACT_DIR COPY_DIR 2>/dev/null || true
    _load_dotenv
    if [[ "$MAX_UNZIP" == "2" ]]; then
        echo "PASS default MAX_UNZIP=2 when no .env"
    else
        echo "FAIL default MAX_UNZIP expected '2', got '$MAX_UNZIP'"
    fi
    if [[ "$EXTRACT_DIR" == "/tmp/iso_pipeline" ]]; then
        echo "PASS default EXTRACT_DIR when no .env"
    else
        echo "FAIL default EXTRACT_DIR expected '/tmp/iso_pipeline', got '$EXTRACT_DIR'"
    fi

    rm -rf "$_tmp_root2"
)

# =============================================================================
# U21d — _detect_adapters
# =============================================================================

header "Test U21d: _detect_adapters"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # Stub out gum log so it doesn't fail when gum is not present
    gum() { :; }
    export -f gum

    _tmp="/tmp/lp_smart_adapters_$$"
    mkdir -p "$_tmp"

    # Single adapter
    printf '~%s~\n' '/path/game.7z|lvol|games/g1' > "$_tmp/single.jobs"
    JOBS_PATH="$_tmp/single.jobs"
    _detect_adapters
    if [[ -v DETECTED[lvol] ]]; then
        echo "PASS single adapter 'lvol' detected"
    else
        echo "FAIL single adapter 'lvol' not detected"
    fi
    if (( ${#DETECTED[@]} == 1 )); then
        echo "PASS exactly one adapter detected"
    else
        echo "FAIL expected 1 adapter, got ${#DETECTED[@]}"
    fi

    # Multiple adapters
    cat > "$_tmp/multi.jobs" <<'JOBS'
~/path/game1.7z|lvol|games/g1~
~/path/game2.7z|ftp|/remote/g2~
~/path/game3.7z|rclone|bucket/g3~
~/path/game4.7z|lvol|games/g4~
JOBS
    JOBS_PATH="$_tmp/multi.jobs"
    _detect_adapters
    if [[ -v DETECTED[lvol] && -v DETECTED[ftp] && -v DETECTED[rclone] ]]; then
        echo "PASS multiple adapters (lvol, ftp, rclone) detected"
    else
        echo "FAIL multiple adapters not all detected: ${!DETECTED[*]}"
    fi
    if (( ${#DETECTED[@]} == 3 )); then
        echo "PASS deduplication: lvol appears twice but counted once"
    else
        echo "FAIL deduplication expected 3 unique, got ${#DETECTED[@]}"
    fi

    # Comments-only file
    cat > "$_tmp/comments.jobs" <<'JOBS'
# just a comment
# another comment

JOBS
    JOBS_PATH="$_tmp/comments.jobs"
    _detect_adapters
    if (( ${#DETECTED[@]} == 0 )); then
        echo "PASS comments-only file: no adapters detected"
    else
        echo "FAIL comments-only file: expected 0 adapters, got ${#DETECTED[@]}"
    fi

    # Directory mode: multiple .jobs files
    mkdir -p "$_tmp/jobsdir"
    printf '~%s~\n' '/path/a.7z|hdl|/dev/hdd0' > "$_tmp/jobsdir/a.jobs"
    printf '~%s~\n' '/path/b.7z|rsync|/dest/b'  > "$_tmp/jobsdir/b.jobs"
    JOBS_PATH="$_tmp/jobsdir"
    _detect_adapters
    if [[ -v DETECTED[hdl] && -v DETECTED[rsync] ]]; then
        echo "PASS directory mode: hdl + rsync detected from two files"
    else
        echo "FAIL directory mode: expected hdl+rsync, got '${!DETECTED[*]}'"
    fi

    # Unknown adapter
    printf '~%s~\n' '/path/x.7z|unknown_adapter|dest' > "$_tmp/unknown.jobs"
    JOBS_PATH="$_tmp/unknown.jobs"
    _detect_adapters
    if [[ -v DETECTED[unknown_adapter] ]]; then
        echo "PASS unknown adapter still tracked in DETECTED"
    else
        echo "FAIL unknown adapter not in DETECTED"
    fi

    rm -rf "$_tmp"
)

# =============================================================================
# U21e — _val_pos_int
# =============================================================================

header "Test U21e: _val_pos_int"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # Valid cases (should produce no output)
    for val in 1 2 42 100 999; do
        out="$(_val_pos_int TEST "$val")"
        if [[ -z "$out" ]]; then
            echo "PASS _val_pos_int accepts '$val'"
        else
            echo "FAIL _val_pos_int rejected valid '$val': $out"
        fi
    done

    # Invalid cases (should produce error message)
    for val in 0 -1 abc "" 1.5 "2 3"; do
        out="$(_val_pos_int TEST "$val")"
        if [[ -n "$out" ]]; then
            echo "PASS _val_pos_int rejects '$val'"
        else
            echo "FAIL _val_pos_int accepted invalid '$val'"
        fi
    done
)

# =============================================================================
# U21f — _val_nn_int
# =============================================================================

header "Test U21f: _val_nn_int"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # Valid
    for val in 0 1 20 100; do
        out="$(_val_nn_int TEST "$val")"
        if [[ -z "$out" ]]; then
            echo "PASS _val_nn_int accepts '$val'"
        else
            echo "FAIL _val_nn_int rejected valid '$val': $out"
        fi
    done

    # Invalid
    for val in -1 abc "" 1.5; do
        out="$(_val_nn_int TEST "$val")"
        if [[ -n "$out" ]]; then
            echo "PASS _val_nn_int rejects '$val'"
        else
            echo "FAIL _val_nn_int accepted invalid '$val'"
        fi
    done
)

# =============================================================================
# U21g — _val_nn_decimal
# =============================================================================

header "Test U21g: _val_nn_decimal"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # Valid
    for val in 0 1 5 0.25 1.5 60 100.0; do
        out="$(_val_nn_decimal TEST "$val")"
        if [[ -z "$out" ]]; then
            echo "PASS _val_nn_decimal accepts '$val'"
        else
            echo "FAIL _val_nn_decimal rejected valid '$val': $out"
        fi
    done

    # Invalid
    for val in -1 abc "" 5s .5; do
        out="$(_val_nn_decimal TEST "$val")"
        if [[ -n "$out" ]]; then
            echo "PASS _val_nn_decimal rejects '$val'"
        else
            echo "FAIL _val_nn_decimal accepted invalid '$val'"
        fi
    done
)

# =============================================================================
# U21h — _val_nonempty
# =============================================================================

header "Test U21h: _val_nonempty"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    out="$(_val_nonempty TEST "hello")"
    if [[ -z "$out" ]]; then
        echo "PASS _val_nonempty accepts non-empty string"
    else
        echo "FAIL _val_nonempty rejected non-empty string"
    fi

    out="$(_val_nonempty TEST "")"
    if [[ -n "$out" ]]; then
        echo "PASS _val_nonempty rejects empty string"
    else
        echo "FAIL _val_nonempty accepted empty string"
    fi
)

# =============================================================================
# U21i — _val_path_writable
# =============================================================================

header "Test U21i: _val_path_writable"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    _tmp="/tmp/lp_smart_path_$$"
    mkdir -p "$_tmp/writable"

    # Writable existing directory
    out="$(_val_path_writable TEST "$_tmp/writable")"
    if [[ -z "$out" ]]; then
        echo "PASS writable existing dir accepted"
    else
        echo "FAIL writable existing dir rejected: $out"
    fi

    # Non-existent path under writable ancestor
    out="$(_val_path_writable TEST "$_tmp/writable/newdir/subdir")"
    if [[ -z "$out" ]]; then
        echo "PASS non-existent path under writable ancestor accepted"
    else
        echo "FAIL non-existent path under writable ancestor rejected: $out"
    fi

    # /tmp should be writable
    out="$(_val_path_writable TEST "/tmp/some_new_pipeline_dir_$$")"
    if [[ -z "$out" ]]; then
        echo "PASS /tmp child accepted as writable"
    else
        echo "FAIL /tmp child rejected: $out"
    fi

    rm -rf "$_tmp"
)

# =============================================================================
# U21j — _validate_all
# =============================================================================

header "Test U21j: _validate_all (full validation engine)"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # Wrap in a function so local declarations work (needed by _validate_all's nameref)
    _run_validate_tests() {
        # Stub out gum so it doesn't fail
        gum() { :; }
        export -f gum

        # All-valid configuration
        declare -gA DETECTED=([lvol]=1)
        MAX_UNZIP=2; MAX_DISPATCH=2
        SCRATCH_DISK_DIR="/tmp"
        EXTRACT_DIR="/tmp/lp_smart_val_test_$$"; COPY_DIR="/tmp/lp_smart_val_copy_$$"
        LVOL_MOUNT_POINT="/tmp"; QUEUE_DIR="/tmp/lp_smart_val_queue_$$"
        SPACE_OVERHEAD_PCT=20; MAX_RECOVERY_ATTEMPTS=3
        DISPATCH_POLL_INITIAL_MS=50; DISPATCH_POLL_MAX_MS=500
        SPACE_RETRY_BACKOFF_INITIAL_SEC=5; SPACE_RETRY_BACKOFF_MAX_SEC=60

        local errors=()
        _validate_all errors
        if (( ${#errors[@]} == 0 )); then
            echo "PASS all-valid config produces no errors"
        else
            echo "FAIL all-valid config produced ${#errors[@]} errors: ${errors[*]}"
        fi

        # Invalid MAX_UNZIP
        MAX_UNZIP=0
        errors=()
        _validate_all errors
        local found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *MAX_UNZIP* ]] && found=1
        done
        if (( found )); then
            echo "PASS MAX_UNZIP=0 caught by validation"
        else
            echo "FAIL MAX_UNZIP=0 not caught"
        fi
        MAX_UNZIP=2

        # Invalid MAX_DISPATCH (non-numeric)
        MAX_DISPATCH=abc
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *MAX_DISPATCH* ]] && found=1
        done
        if (( found )); then
            echo "PASS MAX_DISPATCH=abc caught by validation"
        else
            echo "FAIL MAX_DISPATCH=abc not caught"
        fi
        MAX_DISPATCH=2

        # Cross-var: DISPATCH_POLL_INITIAL > MAX
        DISPATCH_POLL_INITIAL_MS=999; DISPATCH_POLL_MAX_MS=100
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *DISPATCH_POLL_INITIAL_MS* && "$e" == *must\ not\ exceed* ]] && found=1
        done
        if (( found )); then
            echo "PASS dispatch poll ordering constraint caught"
        else
            echo "FAIL dispatch poll ordering constraint not caught"
        fi
        DISPATCH_POLL_INITIAL_MS=50; DISPATCH_POLL_MAX_MS=500

        # Cross-var: SPACE_RETRY_BACKOFF_INITIAL > MAX
        SPACE_RETRY_BACKOFF_INITIAL_SEC=120; SPACE_RETRY_BACKOFF_MAX_SEC=60
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *SPACE_RETRY_BACKOFF_INITIAL_SEC* && "$e" == *must\ not\ exceed* ]] && found=1
        done
        if (( found )); then
            echo "PASS backoff ordering constraint caught"
        else
            echo "FAIL backoff ordering constraint not caught"
        fi
        SPACE_RETRY_BACKOFF_INITIAL_SEC=5; SPACE_RETRY_BACKOFF_MAX_SEC=60

        # LVOL_MOUNT_POINT must exist when lvol adapter detected
        LVOL_MOUNT_POINT="/tmp/nonexistent_sd_mount_$$"
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *LVOL_MOUNT_POINT* && "$e" == *does\ not\ exist* ]] && found=1
        done
        if (( found )); then
            echo "PASS non-existent LVOL_MOUNT_POINT caught"
        else
            echo "FAIL non-existent LVOL_MOUNT_POINT not caught"
        fi
        LVOL_MOUNT_POINT="/tmp"

        # FTP adapter: empty host caught
        declare -gA DETECTED=([ftp]=1)
        FTP_HOST=""; FTP_PORT=21
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *FTP_HOST* ]] && found=1
        done
        if (( found )); then
            echo "PASS empty FTP_HOST caught"
        else
            echo "FAIL empty FTP_HOST not caught"
        fi

        # FTP port: invalid
        FTP_HOST="example.com"; FTP_PORT=abc
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *FTP_PORT* ]] && found=1
        done
        if (( found )); then
            echo "PASS invalid FTP_PORT caught"
        else
            echo "FAIL invalid FTP_PORT not caught"
        fi

        # SPACE_OVERHEAD_PCT: invalid
        declare -gA DETECTED=()
        FTP_HOST=""; FTP_PORT=21
        SPACE_OVERHEAD_PCT=abc
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *SPACE_OVERHEAD_PCT* ]] && found=1
        done
        if (( found )); then
            echo "PASS invalid SPACE_OVERHEAD_PCT caught"
        else
            echo "FAIL invalid SPACE_OVERHEAD_PCT not caught"
        fi
        SPACE_OVERHEAD_PCT=20

        # SPACE_RETRY decimal validation
        SPACE_RETRY_BACKOFF_INITIAL_SEC="5s"
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *SPACE_RETRY_BACKOFF_INITIAL_SEC* ]] && found=1
        done
        if (( found )); then
            echo "PASS non-numeric SPACE_RETRY_BACKOFF_INITIAL_SEC caught"
        else
            echo "FAIL non-numeric SPACE_RETRY_BACKOFF_INITIAL_SEC not caught"
        fi
        SPACE_RETRY_BACKOFF_INITIAL_SEC=5

        # rclone adapter: empty remote caught
        declare -gA DETECTED=([rclone]=1)
        RCLONE_REMOTE=""
        errors=()
        _validate_all errors
        found=0
        for e in "${errors[@]}"; do
            [[ "$e" == *RCLONE_REMOTE* ]] && found=1
        done
        if (( found )); then
            echo "PASS empty RCLONE_REMOTE caught"
        else
            echo "FAIL empty RCLONE_REMOTE not caught"
        fi

        # rsync adapter: empty dest base + invalid port
        declare -gA DETECTED=([rsync]=1)
        RSYNC_DEST_BASE=""; RSYNC_SSH_PORT=abc
        errors=()
        _validate_all errors
        local found_dest=0 found_port=0
        for e in "${errors[@]}"; do
            [[ "$e" == *RSYNC_DEST_BASE* ]] && found_dest=1
            [[ "$e" == *RSYNC_SSH_PORT* ]]  && found_port=1
        done
        if (( found_dest && found_port )); then
            echo "PASS rsync: empty RSYNC_DEST_BASE + invalid RSYNC_SSH_PORT both caught"
        else
            echo "FAIL rsync validation: dest=$found_dest port=$found_port"
        fi

        # Multiple errors collected at once
        declare -gA DETECTED=([lvol]=1)
        MAX_UNZIP=0; MAX_DISPATCH=0; LVOL_MOUNT_POINT="/tmp/nonexistent_$$"
        DISPATCH_POLL_INITIAL_MS=999; DISPATCH_POLL_MAX_MS=100
        errors=()
        _validate_all errors
        if (( ${#errors[@]} >= 4 )); then
            echo "PASS multiple errors collected simultaneously (${#errors[@]})"
        else
            echo "FAIL expected ≥4 errors, got ${#errors[@]}"
        fi
    }
    _run_validate_tests
)

# =============================================================================
# U21k — _check_gum
# =============================================================================

header "Test U21k: _check_gum"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # Case 1: gum not on PATH → should exit non-zero
    _saved_path="$PATH"
    PATH="/usr/bin:/bin"
    if command -v gum &>/dev/null; then
        echo "PASS (skip) gum found even on restricted PATH — cannot test absence"
    else
        if out=$(_check_gum 2>&1); then
            echo "FAIL _check_gum succeeded when gum is not on PATH"
        else
            if [[ "$out" == *"gum"* && "$out" == *"Install"* ]]; then
                echo "PASS _check_gum fails with install instructions when gum absent"
            else
                echo "FAIL _check_gum failed but output lacks install instructions"
            fi
        fi
    fi
    PATH="$_saved_path"

    # Case 2: gum available → should succeed
    if command -v gum &>/dev/null; then
        if _check_gum 2>/dev/null; then
            echo "PASS _check_gum succeeds when gum is on PATH"
        else
            echo "FAIL _check_gum failed even though gum is on PATH"
        fi
    else
        # Create a fake gum on PATH to test the success case
        _shim_dir="/tmp/lp_smart_gum_shim_$$"
        mkdir -p "$_shim_dir"
        printf '#!/usr/bin/env bash\n:' > "$_shim_dir/gum"
        chmod +x "$_shim_dir/gum"
        PATH="$_shim_dir:$PATH"
        if _check_gum 2>/dev/null; then
            echo "PASS _check_gum succeeds with gum shim on PATH"
        else
            echo "FAIL _check_gum failed with gum shim on PATH"
        fi
        rm -rf "$_shim_dir"
    fi
)

# =============================================================================
# U21l — _pick_path: WSL → gum filter, native Linux → gum file
# =============================================================================

header "Test U21l: _pick_path platform dispatch"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # Create a gum shim that logs the subcommand to a file and returns a path
    _shim_dir="/tmp/lp_smart_pick_shim_$$"
    _shim_log="$_shim_dir/gum_calls.log"
    mkdir -p "$_shim_dir"
    cat > "$_shim_dir/gum" <<'SHIM'
#!/usr/bin/env bash
echo "$1" >> "$GUM_SHIM_LOG"
case "$1" in
    filter)
        # Simulate picking ">> USE THIS DIRECTORY <<"
        echo ">> USE THIS DIRECTORY <<"
        ;;
    file)
        echo "/tmp"
        ;;
    *)
        :
        ;;
esac
SHIM
    chmod +x "$_shim_dir/gum"

    _saved_path="$PATH"
    PATH="$_shim_dir:$PATH"
    export GUM_SHIM_LOG="$_shim_log"

    # ── Test WSL branch: force WSL_DISTRO_NAME, expect "filter" ──
    export WSL_DISTRO_NAME="Ubuntu"
    unset WT_SESSION 2>/dev/null || true
    > "$_shim_log"

    result="$(_pick_path "Test" "/tmp" --dir-only)"
    gum_cmd="$(head -1 "$_shim_log" 2>/dev/null || echo "")"

    if [[ "$gum_cmd" == "filter" ]]; then
        echo "PASS WSL branch dispatches to gum filter"
    else
        echo "FAIL WSL branch: expected 'filter', got '$gum_cmd'"
    fi

    if [[ "$result" == "/tmp" ]]; then
        echo "PASS WSL branch returns selected directory"
    else
        echo "FAIL WSL branch: expected '/tmp', got '$result'"
    fi

    # ── Test native Linux branch: unset WSL vars, expect "file" ──
    unset WSL_DISTRO_NAME WT_SESSION 2>/dev/null || true
    > "$_shim_log"

    result="$(_pick_path "Test" "/tmp" --dir-only)"
    gum_cmd="$(head -1 "$_shim_log" 2>/dev/null || echo "")"

    if [[ "$gum_cmd" == "file" ]]; then
        echo "PASS native Linux branch dispatches to gum file"
    else
        echo "FAIL native Linux branch: expected 'file', got '$gum_cmd'"
    fi

    # ── Test WT_SESSION also triggers WSL branch ──
    unset WSL_DISTRO_NAME 2>/dev/null || true
    export WT_SESSION="some-guid"
    > "$_shim_log"

    result="$(_pick_path "Test" "/tmp" --dir-only)"
    gum_cmd="$(head -1 "$_shim_log" 2>/dev/null || echo "")"

    if [[ "$gum_cmd" == "filter" ]]; then
        echo "PASS WT_SESSION triggers WSL/filter branch"
    else
        echo "FAIL WT_SESSION: expected 'filter', got '$gum_cmd'"
    fi

    # ── Test file selection (non-dir-only) on WSL ──
    export WSL_DISTRO_NAME="Ubuntu"
    unset WT_SESSION 2>/dev/null || true
    > "$_shim_log"

    # Shim returns ">> USE THIS DIRECTORY <<" which selects a dir.
    # For file selection test, create a modified shim that returns a filename.
    cat > "$_shim_dir/gum" <<'SHIM2'
#!/usr/bin/env bash
echo "$1" >> "$GUM_SHIM_LOG"
case "$1" in
    filter) echo "somefile.jobs" ;;
    file)   echo "/tmp/somefile.jobs" ;;
    *)      : ;;
esac
SHIM2
    chmod +x "$_shim_dir/gum"

    # Create the fake file so the -d check fails and it's treated as a file pick
    touch "/tmp/somefile.jobs"
    result="$(_pick_path "Test" "/tmp")"
    if [[ "$result" == "/tmp/somefile.jobs" ]]; then
        echo "PASS WSL branch returns file path for non-dir pick"
    else
        echo "FAIL WSL file pick: expected '/tmp/somefile.jobs', got '$result'"
    fi
    rm -f "/tmp/somefile.jobs"

    # ── Test native Linux --dir-only passes --directory flag ──
    unset WSL_DISTRO_NAME WT_SESSION 2>/dev/null || true
    cat > "$_shim_dir/gum" <<'SHIM3'
#!/usr/bin/env bash
echo "$1" >> "$GUM_SHIM_LOG"
# Log all args so we can check for --directory
echo "$@" >> "$GUM_SHIM_LOG"
echo "/tmp"
SHIM3
    chmod +x "$_shim_dir/gum"
    > "$_shim_log"

    _pick_path "Test" "/tmp" --dir-only >/dev/null
    if grep -q "\-\-directory" "$_shim_log"; then
        echo "PASS native --dir-only passes --directory to gum file"
    else
        echo "FAIL native --dir-only: --directory not found in gum args"
    fi

    # Check that without --dir-only, --file and --directory are both passed
    > "$_shim_log"
    _pick_path "Test" "/tmp" >/dev/null
    if grep -q "\-\-file" "$_shim_log" && grep -q "\-\-directory" "$_shim_log"; then
        echo "PASS native default passes --file and --directory to gum file"
    else
        echo "FAIL native default: missing --file/--directory in gum args"
    fi

    PATH="$_saved_path"
    rm -rf "$_shim_dir"
)

# =============================================================================
# U21m — _action_status
# =============================================================================

header "Test U21m: _action_status state machine"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # _action_status reads _STATUS_* vars via dynamic scoping, so wrap
    # everything in a function that declares them as locals — just like main().
    _run_status_tests() {
        declare -gA DETECTED=()
        local _STATUS_CFG_LVOL="pending"
        local _STATUS_CFG_FTP="pending"
        local _STATUS_CFG_HDL="pending"
        local _STATUS_CFG_RCLONE="pending"
        local _STATUS_CFG_RSYNC="pending"
        local _STATUS_WORKERS="pending"
        local _STATUS_SCRATCH="pending"
        local _STATUS_DEBUG="skip"
        local _STATUS_DIRS="skip"
        local _STATUS_TUNING="skip"
        local _STATUS_STRIP="skip"
        local _VALIDATE_STATUS="pending"

        # ── jobs: no JOBS_PATH → pending ──
        unset JOBS_PATH 2>/dev/null || true
        if [[ "$(_action_status jobs)" == "pending" ]]; then
            echo "PASS jobs: pending when JOBS_PATH unset"
        else
            echo "FAIL jobs: expected pending, got $(_action_status jobs)"
        fi

        # ── jobs: valid file → ok ──
        local _tmp="/tmp/lp_smart_status_$$"
        mkdir -p "$_tmp"
        printf '~%s~\n' '/path/g.7z|lvol|g' > "$_tmp/test.jobs"
        JOBS_PATH="$_tmp/test.jobs"
        if [[ "$(_action_status jobs)" == "ok" ]]; then
            echo "PASS jobs: ok when JOBS_PATH is a valid file"
        else
            echo "FAIL jobs: expected ok, got $(_action_status jobs)"
        fi

        # ── detect: no adapters, but JOBS_PATH set → pending ──
        DETECTED=()
        if [[ "$(_action_status detect)" == "pending" ]]; then
            echo "PASS detect: pending when JOBS_PATH set but no adapters"
        else
            echo "FAIL detect: expected pending, got $(_action_status detect)"
        fi

        # ── detect: no adapters, no JOBS_PATH → locked ──
        unset JOBS_PATH 2>/dev/null || true
        if [[ "$(_action_status detect)" == "locked" ]]; then
            echo "PASS detect: locked when no JOBS_PATH"
        else
            echo "FAIL detect: expected locked, got $(_action_status detect)"
        fi

        # ── detect: adapters present → ok ──
        JOBS_PATH="$_tmp/test.jobs"
        DETECTED=([lvol]=1)
        if [[ "$(_action_status detect)" == "ok" ]]; then
            echo "PASS detect: ok when adapters detected"
        else
            echo "FAIL detect: expected ok, got $(_action_status detect)"
        fi

        # ── config statuses: read from _STATUS_ vars ──
        _STATUS_CFG_LVOL="ok"
        if [[ "$(_action_status cfg_lvol)" == "ok" ]]; then
            echo "PASS cfg_lvol: reads from _STATUS_CFG_LVOL"
        else
            echo "FAIL cfg_lvol: expected ok"
        fi

        # ── validate: locked when workers not configured ──
        _STATUS_WORKERS="pending"
        _STATUS_SCRATCH="ok"
        if [[ "$(_action_status validate)" == "locked" ]]; then
            echo "PASS validate: locked when workers pending"
        else
            echo "FAIL validate: expected locked, got $(_action_status validate)"
        fi

        # ── validate: locked when adapter config missing ──
        _STATUS_WORKERS="ok"
        _STATUS_CFG_LVOL="pending"
        if [[ "$(_action_status validate)" == "locked" ]]; then
            echo "PASS validate: locked when adapter config pending"
        else
            echo "FAIL validate: expected locked, got $(_action_status validate)"
        fi

        # ── validate: unlocked → returns _VALIDATE_STATUS ──
        _STATUS_CFG_LVOL="ok"
        _VALIDATE_STATUS="pending"
        if [[ "$(_action_status validate)" == "pending" ]]; then
            echo "PASS validate: returns pending when all prereqs met"
        else
            echo "FAIL validate: expected pending, got $(_action_status validate)"
        fi

        _VALIDATE_STATUS="ok"
        if [[ "$(_action_status validate)" == "ok" ]]; then
            echo "PASS validate: returns ok after validation"
        else
            echo "FAIL validate: expected ok"
        fi

        # ── launch: locked until validate ok ──
        _VALIDATE_STATUS="pending"
        if [[ "$(_action_status launch)" == "locked" ]]; then
            echo "PASS launch: locked when not validated"
        else
            echo "FAIL launch: expected locked"
        fi

        _VALIDATE_STATUS="ok"
        if [[ "$(_action_status launch)" == "ready" ]]; then
            echo "PASS launch: ready when validated"
        else
            echo "FAIL launch: expected ready"
        fi

        rm -rf "$_tmp"
    }
    _run_status_tests
)

# =============================================================================
# U21n — _build_menu
# =============================================================================

header "Test U21n: _build_menu array population"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    _run_menu_tests() {
        declare -gA DETECTED=()
        local _STATUS_CFG_LVOL="pending"
        local _STATUS_CFG_FTP="pending"
        local _STATUS_CFG_HDL="pending"
        local _STATUS_CFG_RCLONE="pending"
        local _STATUS_CFG_RSYNC="pending"
        local _STATUS_WORKERS="pending"
        local _STATUS_SCRATCH="pending"
        local _STATUS_DEBUG="skip"
        local _STATUS_DIRS="skip"
        local _STATUS_TUNING="skip"
        local _STATUS_STRIP="skip"
        local _VALIDATE_STATUS="pending"

        # Stub variables needed by _action_status
        unset JOBS_PATH 2>/dev/null || true
        EXTRACT_STRIP_LIST=""

        # ── No adapters detected: base menu ──
        local -a items actions
        _build_menu items actions

        # Should have: jobs, detect, workers, scratch, debug, dirs, tuning,
        #              strip, validate, launch = 10 items + Quit = 11 total
        if (( ${#items[@]} == 11 )); then
            echo "PASS base menu has 11 items (10 actions + Quit)"
        else
            echo "FAIL base menu expected 11 items, got ${#items[@]}"
        fi

        # First item should be numbered 1 (not 0)
        if [[ "${items[0]}" == *"1."* ]]; then
            echo "PASS first item is numbered 1"
        else
            echo "FAIL first item numbering: ${items[0]}"
        fi

        # Last item should be Quit
        if [[ "${items[-1]}" == *"Q. Quit"* ]]; then
            echo "PASS last item is Quit"
        else
            echo "FAIL last item: ${items[-1]}"
        fi

        # Actions array should map 1→jobs, 2→detect
        if [[ "${actions[1]}" == "jobs" ]]; then
            echo "PASS actions[1] = jobs"
        else
            echo "FAIL actions[1] = ${actions[1]:-empty}"
        fi
        if [[ "${actions[2]}" == "detect" ]]; then
            echo "PASS actions[2] = detect"
        else
            echo "FAIL actions[2] = ${actions[2]:-empty}"
        fi

        # ── With adapters: dynamic items appear ──
        DETECTED=([lvol]=1 [rsync]=1)
        items=() actions=()
        _build_menu items actions

        # Should now have 2 more items (cfg_lvol, cfg_rsync)
        if (( ${#items[@]} == 13 )); then
            echo "PASS menu with 2 adapters has 13 items"
        else
            echo "FAIL menu with 2 adapters expected 13 items, got ${#items[@]}"
        fi

        # Verify adapter actions exist in the actions array
        local found_lvol=0 found_rsync=0
        local _key
        for _key in "${!actions[@]}"; do
            [[ "${actions[$_key]}" == "cfg_lvol" ]]  && found_lvol=1
            [[ "${actions[$_key]}" == "cfg_rsync" ]] && found_rsync=1
        done
        if (( found_lvol && found_rsync )); then
            echo "PASS adapter actions (cfg_lvol, cfg_rsync) present"
        else
            echo "FAIL adapter actions: lvol=$found_lvol rsync=$found_rsync"
        fi

        # ── Numbering is contiguous ──
        local prev=0 contiguous=1
        for _key in $(printf '%s\n' "${!actions[@]}" | sort -n); do
            if (( _key != prev + 1 )); then
                contiguous=0
                break
            fi
            prev=$_key
        done
        if (( contiguous )); then
            echo "PASS menu numbering is contiguous"
        else
            echo "FAIL menu numbering has gaps"
        fi

        # ── Status icons appear in items ──
        local has_icon=1
        local _item
        for _item in "${items[@]}"; do
            [[ "$_item" == *"Q. Quit"* ]] && continue
            if [[ ! "$_item" =~ ^\[ ]]; then
                has_icon=0
                break
            fi
        done
        if (( has_icon )); then
            echo "PASS all action items have status icons"
        else
            echo "FAIL some items missing status icons"
        fi
    }
    _run_menu_tests
)

# =============================================================================
# U21o — _mask_value, _input_header, _DOTENV/_DEFAULTS
# =============================================================================

header "Test U21o: context display helpers"

_u_run_subshell < <(
    source "$SMART_WRAPPER"

    # ── _mask_value: normal values pass through ──
    out="$(_mask_value MAX_UNZIP "4")"
    if [[ "$out" == "4" ]]; then
        echo "PASS _mask_value passes through normal value"
    else
        echo "FAIL _mask_value: expected '4', got '$out'"
    fi

    # ── _mask_value: empty → (empty) ──
    out="$(_mask_value MAX_UNZIP "")"
    if [[ "$out" == "(empty)" ]]; then
        echo "PASS _mask_value shows (empty) for blank value"
    else
        echo "FAIL _mask_value: expected '(empty)', got '$out'"
    fi

    # ── _mask_value: FTP_PASS is masked ──
    out="$(_mask_value FTP_PASS "s3cret")"
    if [[ "$out" == "*******" ]]; then
        echo "PASS _mask_value masks FTP_PASS"
    else
        echo "FAIL _mask_value: expected '*******', got '$out'"
    fi

    # ── _mask_value: empty FTP_PASS shows (empty) not stars ──
    out="$(_mask_value FTP_PASS "")"
    if [[ "$out" == "(empty)" ]]; then
        echo "PASS _mask_value shows (empty) for blank FTP_PASS"
    else
        echo "FAIL _mask_value: expected '(empty)', got '$out'"
    fi

    # ── _load_dotenv populates _DOTENV from .env ──
    _tmp="/tmp/lp_smart_ctx_$$"
    mkdir -p "$_tmp"
    printf 'MAX_UNZIP=8\nFTP_PASS=hunter2\n' > "$_tmp/.env"
    ROOT_DIR="$_tmp"
    unset MAX_UNZIP FTP_PASS 2>/dev/null || true
    _load_dotenv
    if [[ "${_DOTENV[MAX_UNZIP]:-}" == "8" ]]; then
        echo "PASS _DOTENV captures raw .env value"
    else
        echo "FAIL _DOTENV[MAX_UNZIP] expected '8', got '${_DOTENV[MAX_UNZIP]:-}'"
    fi

    # ── _DEFAULTS populated ──
    if [[ "${_DEFAULTS[MAX_UNZIP]:-}" == "2" ]]; then
        echo "PASS _DEFAULTS has hardcoded fallback"
    else
        echo "FAIL _DEFAULTS[MAX_UNZIP] expected '2', got '${_DEFAULTS[MAX_UNZIP]:-}'"
    fi

    # ── _input_header with .env and default ──
    out="$(_input_header MAX_UNZIP)"
    if [[ "$out" == *".env: 8"* && "$out" == *"default: 2"* ]]; then
        echo "PASS _input_header shows .env and default"
    else
        echo "FAIL _input_header output: $out"
    fi

    # ── _input_header with extra description ──
    out="$(_input_header MAX_UNZIP "(parallel workers)")"
    if [[ "$out" == "MAX_UNZIP (parallel workers)"* ]]; then
        echo "PASS _input_header includes extra description"
    else
        echo "FAIL _input_header label: $out"
    fi

    # ── _input_header masks FTP_PASS ──
    out="$(_input_header FTP_PASS)"
    if [[ "$out" == *"*******"* ]] && [[ "$out" != *"hunter2"* ]]; then
        echo "PASS _input_header masks FTP_PASS from .env"
    else
        echo "FAIL _input_header leaked FTP_PASS: $out"
    fi

    # ── _input_header with no .env entry ──
    out="$(_input_header RSYNC_HOST)"
    if [[ "$out" != *".env:"* && "$out" == *"default: (empty)"* ]]; then
        echo "PASS _input_header omits .env line when not in .env"
    else
        echo "FAIL _input_header for absent var: $out"
    fi

    rm -rf "$_tmp"
)
