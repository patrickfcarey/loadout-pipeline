#!/usr/bin/env bash
set -uo pipefail

# Interactive TUI wrapper for loadout-pipeline using gum (Charm CLI).
# Usage: bash tools/loadout-pipeline_smart.sh

# ─── Infrastructure ───────────────────────────────────────────────────────────

_resolve_root_dir() {
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}

_detect_pipeline_entry() {
    if [[ -f "$ROOT_DIR/dist/loadout-pipeline.sh" ]]; then
        PIPELINE_ENTRY="$ROOT_DIR/dist/loadout-pipeline.sh"
    elif [[ -f "$ROOT_DIR/bin/loadout-pipeline.sh" ]]; then
        PIPELINE_ENTRY="$ROOT_DIR/bin/loadout-pipeline.sh"
    else
        _err "Cannot find pipeline entry point in dist/ or bin/"
        exit 1
    fi
}

_check_gum() {
    if ! command -v gum &>/dev/null; then
        echo "ERROR: 'gum' is required but not found on PATH."
        echo ""
        echo "Install gum (Charm CLI):"
        echo "  brew install gum          # macOS / Linuxbrew"
        echo "  sudo apt install gum      # Debian/Ubuntu (charm repo)"
        echo "  go install github.com/charmbracelet/gum@latest"
        echo ""
        echo "See: https://github.com/charmbracelet/gum"
        exit 1
    fi
}

declare -gA _DOTENV=()
declare -gA _DEFAULTS=()

_load_dotenv() {
    _DOTENV=()
    if [[ -f "$ROOT_DIR/.env" ]]; then
        while IFS= read -r _dotenv_line || [[ -n "$_dotenv_line" ]]; do
            [[ "$_dotenv_line" =~ ^[[:space:]]*(#|$) ]] && continue
            _dotenv_line="${_dotenv_line%$'\r'}"
            _dotenv_key="${_dotenv_line%%=*}"
            _dotenv_val="${_dotenv_line#*=}"
            _dotenv_key="${_dotenv_key// /}"
            [[ "$_dotenv_key" == "$_dotenv_line" || -z "$_dotenv_key" ]] && continue
            [[ "$_dotenv_key" =~ [^a-zA-Z0-9_] ]] && continue
            _dotenv_val="${_dotenv_val%"${_dotenv_val##*[![:space:]]}"}"
            _DOTENV["$_dotenv_key"]="$_dotenv_val"
            [[ -v "$_dotenv_key" ]] || export "$_dotenv_key=$_dotenv_val"
        done < "$ROOT_DIR/.env"
        unset _dotenv_line _dotenv_key _dotenv_val
    fi

    # Apply fallback defaults (same as lib/config.sh)
    DEBUG_IND="${DEBUG_IND:-0}"
    RESUME_PLANNER_IND="${RESUME_PLANNER_IND:-1}"
    MAX_UNZIP="${MAX_UNZIP:-2}"
    MAX_DISPATCH="${MAX_DISPATCH:-2}"
    SCRATCH_DISK_DIR="${SCRATCH_DISK_DIR:-/tmp}"
    QUEUE_DIR="${QUEUE_DIR:-$SCRATCH_DISK_DIR/iso_pipeline_queue}"
    EXTRACT_DIR="${EXTRACT_DIR:-$SCRATCH_DISK_DIR/iso_pipeline}"
    COPY_DIR="${COPY_DIR:-$SCRATCH_DISK_DIR/iso_pipeline_copies}"
    SPACE_OVERHEAD_PCT="${SPACE_OVERHEAD_PCT:-20}"
    FTP_HOST="${FTP_HOST:-}"
    FTP_USER="${FTP_USER:-}"
    FTP_PASS="${FTP_PASS:-}"
    FTP_PORT="${FTP_PORT:-21}"
    HDL_DUMP_BIN="${HDL_DUMP_BIN:-hdl_dump}"
    LVOL_MOUNT_POINT="${LVOL_MOUNT_POINT:-/mnt/lvol}"
    RCLONE_REMOTE="${RCLONE_REMOTE:-}"
    RCLONE_DEST_BASE="${RCLONE_DEST_BASE:-}"
    RCLONE_FLAGS="${RCLONE_FLAGS:-}"
    RSYNC_DEST_BASE="${RSYNC_DEST_BASE:-}"
    RSYNC_HOST="${RSYNC_HOST:-}"
    RSYNC_USER="${RSYNC_USER:-}"
    RSYNC_SSH_PORT="${RSYNC_SSH_PORT:-22}"
    RSYNC_FLAGS="${RSYNC_FLAGS:-}"
    MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"
    DISPATCH_POLL_INITIAL_MS="${DISPATCH_POLL_INITIAL_MS:-50}"
    DISPATCH_POLL_MAX_MS="${DISPATCH_POLL_MAX_MS:-500}"
    EXTRACT_STRIP_LIST="${EXTRACT_STRIP_LIST:-$ROOT_DIR/strip.list}"
    SPACE_RETRY_BACKOFF_INITIAL_SEC="${SPACE_RETRY_BACKOFF_INITIAL_SEC:-5}"
    SPACE_RETRY_BACKOFF_MAX_SEC="${SPACE_RETRY_BACKOFF_MAX_SEC:-60}"

    _DEFAULTS=(
        [DEBUG_IND]="0"
        [RESUME_PLANNER_IND]="1"
        [MAX_UNZIP]="2"
        [MAX_DISPATCH]="2"
        [SCRATCH_DISK_DIR]="/tmp"
        [QUEUE_DIR]="/tmp/iso_pipeline_queue"
        [EXTRACT_DIR]="/tmp/iso_pipeline"
        [COPY_DIR]="/tmp/iso_pipeline_copies"
        [SPACE_OVERHEAD_PCT]="20"
        [FTP_HOST]=""
        [FTP_USER]=""
        [FTP_PASS]=""
        [FTP_PORT]="21"
        [HDL_DUMP_BIN]="hdl_dump"
        [LVOL_MOUNT_POINT]="/mnt/lvol"
        [RCLONE_REMOTE]=""
        [RCLONE_DEST_BASE]=""
        [RCLONE_FLAGS]=""
        [RSYNC_DEST_BASE]=""
        [RSYNC_HOST]=""
        [RSYNC_USER]=""
        [RSYNC_SSH_PORT]="22"
        [RSYNC_FLAGS]=""
        [MAX_RECOVERY_ATTEMPTS]="3"
        [DISPATCH_POLL_INITIAL_MS]="50"
        [DISPATCH_POLL_MAX_MS]="500"
        [EXTRACT_STRIP_LIST]="$ROOT_DIR/strip.list"
        [SPACE_RETRY_BACKOFF_INITIAL_SEC]="5"
        [SPACE_RETRY_BACKOFF_MAX_SEC]="60"
    )
}

# Restores terminal cursor visibility — gum hides it during interaction.
_cleanup() {
    tput cnorm 2>/dev/null || true
}

# ─── Presentation ─────────────────────────────────────────────────────────────

_banner() {
    gum style --foreground 99 --bold "
 ██╗      ██████╗  █████╗ ██████╗  ██████╗ ██╗   ██╗████████╗
 ██║     ██╔═══██╗██╔══██╗██╔══██╗██╔═══██╗██║   ██║╚══██╔══╝
 ██║     ██║   ██║███████║██║  ██║██║   ██║██║   ██║   ██║
 ██║     ██║   ██║██╔══██║██║  ██║██║   ██║██║   ██║   ██║
 ███████╗╚██████╔╝██║  ██║██████╔╝╚██████╔╝╚██████╔╝   ██║
 ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═════╝  ╚═════╝  ╚═════╝    ╚═╝
                  PIPELINE — Smart Launcher"
}

_title() {
    gum style --foreground 99 --bold "LOADOUT PIPELINE -- Smart Launcher"
}

_err()  { gum log --level error "$@"; }
_warn() { gum log --level warn "$@"; }
_info() { gum log --level info "$@"; }

_mask_value() {
    local _var="$1" _val="$2"
    if [[ -z "$_val" ]]; then
        echo "(empty)"
        return
    fi
    case "$_var" in
        FTP_PASS) echo "*******" ;;
        *) echo "$_val" ;;
    esac
}

# Builds a header string for gum input / gum choose that shows the .env
# and default values for context.
# Usage: _input_header VAR_NAME [extra_description]
_input_header() {
    local _var="$1" _extra="${2:-}"
    local _label="$_var"
    [[ -n "$_extra" ]] && _label="$_var $_extra"
    local _ctx=""
    if [[ -v "_DOTENV[$_var]" ]]; then
        _ctx=".env: $(_mask_value "$_var" "${_DOTENV[$_var]}")"
    fi
    if [[ -v "_DEFAULTS[$_var]" ]]; then
        [[ -n "$_ctx" ]] && _ctx+="  |  "
        _ctx+="default: $(_mask_value "$_var" "${_DEFAULTS[$_var]}")"
    fi
    if [[ -n "$_ctx" ]]; then
        printf '%s\n  %s' "$_label" "$_ctx"
    else
        printf '%s' "$_label"
    fi
}

# Renders a markdown table of all configured variables for pre-launch review.
_show_summary() {
    local lines=""
    lines+="| Variable | Value |"$'\n'
    lines+="| --- | --- |"$'\n'
    lines+="| Jobs path | \`$JOBS_PATH\` |"$'\n'
    lines+="| Pipeline entry | \`$PIPELINE_ENTRY\` |"$'\n'
    lines+="| MAX_UNZIP | $MAX_UNZIP |"$'\n'
    lines+="| MAX_DISPATCH | $MAX_DISPATCH |"$'\n'
    lines+="| SCRATCH_DISK_DIR | $SCRATCH_DISK_DIR |"$'\n'
    lines+="| EXTRACT_DIR | $EXTRACT_DIR |"$'\n'
    lines+="| COPY_DIR | $COPY_DIR |"$'\n'

    for adapter in "${!DETECTED[@]}"; do
        case "$adapter" in
            lvol)   lines+="| LVOL_MOUNT_POINT | $LVOL_MOUNT_POINT |"$'\n' ;;
            ftp)
                lines+="| FTP_HOST | $FTP_HOST |"$'\n'
                lines+="| FTP_USER | $FTP_USER |"$'\n'
                lines+="| FTP_PASS | ******* |"$'\n'
                lines+="| FTP_PORT | $FTP_PORT |"$'\n'
                ;;
            hdl)    lines+="| HDL_DUMP_BIN | $HDL_DUMP_BIN |"$'\n' ;;
            rclone)
                lines+="| RCLONE_REMOTE | $RCLONE_REMOTE |"$'\n'
                lines+="| RCLONE_DEST_BASE | $RCLONE_DEST_BASE |"$'\n'
                [[ -n "$RCLONE_FLAGS" ]] && lines+="| RCLONE_FLAGS | $RCLONE_FLAGS |"$'\n'
                ;;
            rsync)
                lines+="| RSYNC_DEST_BASE | $RSYNC_DEST_BASE |"$'\n'
                [[ -n "$RSYNC_HOST" ]] && lines+="| RSYNC_HOST | $RSYNC_HOST |"$'\n'
                [[ -n "$RSYNC_USER" ]] && lines+="| RSYNC_USER | $RSYNC_USER |"$'\n'
                lines+="| RSYNC_SSH_PORT | $RSYNC_SSH_PORT |"$'\n'
                [[ -n "$RSYNC_FLAGS" ]] && lines+="| RSYNC_FLAGS | $RSYNC_FLAGS |"$'\n'
                ;;
        esac
    done

    lines+="| DEBUG_IND | $DEBUG_IND |"$'\n'
    lines+="| RESUME_PLANNER_IND | $RESUME_PLANNER_IND |"$'\n'
    lines+="| QUEUE_DIR | $QUEUE_DIR |"$'\n'
    lines+="| SPACE_OVERHEAD_PCT | $SPACE_OVERHEAD_PCT |"$'\n'
    lines+="| MAX_RECOVERY_ATTEMPTS | $MAX_RECOVERY_ATTEMPTS |"$'\n'
    lines+="| DISPATCH_POLL_INITIAL_MS | $DISPATCH_POLL_INITIAL_MS |"$'\n'
    lines+="| DISPATCH_POLL_MAX_MS | $DISPATCH_POLL_MAX_MS |"$'\n'
    lines+="| SPACE_RETRY_BACKOFF_INITIAL_SEC | $SPACE_RETRY_BACKOFF_INITIAL_SEC |"$'\n'
    lines+="| SPACE_RETRY_BACKOFF_MAX_SEC | $SPACE_RETRY_BACKOFF_MAX_SEC |"$'\n'
    [[ -n "$EXTRACT_STRIP_LIST" ]] && lines+="| EXTRACT_STRIP_LIST | $EXTRACT_STRIP_LIST |"$'\n'

    gum style --border rounded --border-foreground 212 --padding "1 2" --bold "Configuration Summary"
    echo "$lines" | gum format
}

# ─── Path picker ──────────────────────────────────────────────────────────────
# _pick_path <header> <start_dir> [--dir-only] [--var VAR_NAME]
# Prints the selected path to stdout. On WSL uses gum filter browser;
# on native Linux uses gum file. Pass --dir-only to only allow directories.
# Pass --var to inject .env and default context rows into the WSL browser.
_pick_path() {
    local _header="$1" _start="${2:-/}" _dir_only=0 _var=""
    shift 2 || true
    while (( $# )); do
        case "$1" in
            --dir-only) _dir_only=1 ;;
            --var) shift; _var="${1:-}" ;;
        esac
        shift
    done

    # Build context rows for .env and default values
    local _context_rows=""
    if [[ -n "$_var" ]]; then
        if [[ -v "_DOTENV[$_var]" ]] && [[ -n "${_DOTENV[$_var]}" ]]; then
            _context_rows+=".env : ${_DOTENV[$_var]}"$'\n'
        fi
        if [[ -v "_DEFAULTS[$_var]" ]] && [[ -n "${_DEFAULTS[$_var]}" ]]; then
            _context_rows+="default : ${_DEFAULTS[$_var]}"$'\n'
        fi
    fi

    if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WT_SESSION:-}" ]]; then
        local _browse_dir="$_start"
        while true; do
            local _entries _pick
            _entries="$(printf '>> USE THIS DIRECTORY <<\n..\n%s' "$_context_rows"; ls -1A "$_browse_dir" 2>/dev/null)" || _entries=".."
            _pick="$(echo "$_entries" | gum filter --height 14 --header "$_header: $_browse_dir")" \
                || return 1
            if [[ "$_pick" == ">> USE THIS DIRECTORY <<" ]]; then
                printf '%s' "$_browse_dir"
                return 0
            elif [[ "$_pick" == ".." ]]; then
                _browse_dir="$(dirname "$_browse_dir")"
            elif [[ "$_pick" == ".env : "* ]]; then
                printf '%s' "${_pick#.env : }"
                return 0
            elif [[ "$_pick" == "default : "* ]]; then
                printf '%s' "${_pick#default : }"
                return 0
            elif [[ -d "$_browse_dir/$_pick" ]]; then
                _browse_dir="$_browse_dir/$_pick"
            elif (( _dir_only )); then
                continue
            else
                printf '%s' "$_browse_dir/$_pick"
                return 0
            fi
        done
    else
        local _gum_args=(--all --show-help)
        if (( _dir_only )); then
            _gum_args+=(--directory)
        else
            _gum_args+=(--file --directory)
        fi
        gum file "${_gum_args[@]}" "$_start" || return 1
    fi
}

# ─── Jobs handling ────────────────────────────────────────────────────────────

_prompt_jobs_path() {
    while true; do
        _info "Select the jobs file or directory"
        local _input
        _input="$(_pick_path "Jobs path" "$ROOT_DIR")" || return 1
        JOBS_PATH="$_input"

        if [[ -d "$JOBS_PATH" ]]; then
            local count
            count="$(find "$JOBS_PATH" -maxdepth 1 -name '*.jobs' -type f 2>/dev/null | wc -l)"
            if (( count == 0 )); then
                _err "No .jobs files found in $JOBS_PATH"
                if ! gum confirm "Try again?" --default=true; then return 1; fi
                continue
            fi
            _info "Found $count .jobs file(s) in directory"
        elif [[ -f "$JOBS_PATH" ]]; then
            local job_lines
            job_lines="$(grep -cE '^~' "$JOBS_PATH" 2>/dev/null || echo 0)"
            if (( job_lines == 0 )); then
                _err "No valid job lines found in $JOBS_PATH"
                if ! gum confirm "Try again?" --default=true; then return 1; fi
                continue
            fi
            _info "Found $job_lines job line(s)"
        else
            _err "Path does not exist: $JOBS_PATH"
            if ! gum confirm "Try again?" --default=true; then return 1; fi
            continue
        fi
        break
    done
}

# Parses JOBS_PATH to find which adapters are referenced in job lines.
# Sets the global associative array DETECTED (keys = adapter names).
_detect_adapters() {
    declare -gA DETECTED=()
    local _jobs_files=()

    if [[ -d "$JOBS_PATH" ]]; then
        while IFS= read -r _file; do
            _jobs_files+=("$_file")
        done < <(find "$JOBS_PATH" -maxdepth 1 -name '*.jobs' -type f 2>/dev/null)
    else
        _jobs_files+=("$JOBS_PATH")
    fi

    local _known_adapters="ftp|hdl|lvol|rclone|rsync"
    local _line _adapter _stripped

    for _file in "${_jobs_files[@]}"; do
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            _line="${_line%$'\r'}"
            [[ "${_line:0:1}" == "~" && "${_line: -1}" == "~" ]] || continue
            _stripped="${_line#\~}"
            _stripped="${_stripped%\~}"
            IFS='|' read -r _ _adapter _ <<< "$_stripped"
            [[ -n "$_adapter" ]] || continue
            _adapter="${_adapter// /}"
            if [[ ! "$_adapter" =~ ^($_known_adapters)$ ]]; then
                _warn "Unknown adapter '$_adapter' in job line"
            fi
            DETECTED["$_adapter"]=1
        done < "$_file"
    done

    if (( ${#DETECTED[@]} == 0 )); then
        _warn "No adapters detected in jobs"
    else
        local _adapter_list=""
        for _adapter in "${!DETECTED[@]}"; do
            [[ -n "$_adapter_list" ]] && _adapter_list+=", "
            _adapter_list+="$_adapter"
        done
        _info "Detected adapters: $_adapter_list"
    fi
}

# ─── Adapter prompts ──────────────────────────────────────────────────────────

_prompt_lvol() {
    gum style --foreground 212 --bold "Local Volume Adapter"
    _info "Select local volume mount point directory"
    local _input
    _input="$(_pick_path "LVOL_MOUNT_POINT" "${LVOL_MOUNT_POINT:-/mnt}" --dir-only --var LVOL_MOUNT_POINT)" || return 1
    LVOL_MOUNT_POINT="$_input"
}

_prompt_ftp() {
    gum style --foreground 212 --bold "FTP Adapter"
    local _input
    _input="$(gum input --header "$(_input_header FTP_HOST)" --value "$FTP_HOST")" || return 1
    FTP_HOST="$_input"
    _input="$(gum input --header "$(_input_header FTP_USER)" --value "$FTP_USER")" || return 1
    FTP_USER="$_input"
    _input="$(gum input --header "$(_input_header FTP_PASS)" --password --value "$FTP_PASS")" || return 1
    FTP_PASS="$_input"
    _input="$(gum input --header "$(_input_header FTP_PORT)" --value "$FTP_PORT")" || return 1
    FTP_PORT="$_input"
}

_prompt_hdl() {
    gum style --foreground 212 --bold "HDL Dump Adapter"
    local _input
    _input="$(gum input --header "$(_input_header HDL_DUMP_BIN "(path or command name)")" --value "$HDL_DUMP_BIN")" || return 1
    HDL_DUMP_BIN="$_input"
}

_prompt_rclone() {
    gum style --foreground 212 --bold "Rclone Adapter"
    local _input
    _input="$(gum input --header "$(_input_header RCLONE_REMOTE "(include trailing colon)")" --value "$RCLONE_REMOTE")" || return 1
    RCLONE_REMOTE="$_input"
    _input="$(gum input --header "$(_input_header RCLONE_DEST_BASE)" --value "$RCLONE_DEST_BASE")" || return 1
    RCLONE_DEST_BASE="$_input"
    _input="$(gum input --header "$(_input_header RCLONE_FLAGS "(optional extra flags)")" --value "$RCLONE_FLAGS")" || return 1
    RCLONE_FLAGS="$_input"
}

_prompt_rsync() {
    gum style --foreground 212 --bold "Rsync Adapter"
    local _input
    _input="$(gum input --header "$(_input_header RSYNC_DEST_BASE)" --value "$RSYNC_DEST_BASE")" || return 1
    RSYNC_DEST_BASE="$_input"
    _input="$(gum input --header "$(_input_header RSYNC_HOST "(leave empty for local)")" --value "$RSYNC_HOST")" || return 1
    RSYNC_HOST="$_input"
    _input="$(gum input --header "$(_input_header RSYNC_USER)" --value "$RSYNC_USER")" || return 1
    RSYNC_USER="$_input"
    _input="$(gum input --header "$(_input_header RSYNC_SSH_PORT)" --value "$RSYNC_SSH_PORT")" || return 1
    RSYNC_SSH_PORT="$_input"
    _input="$(gum input --header "$(_input_header RSYNC_FLAGS "(optional extra flags)")" --value "$RSYNC_FLAGS")" || return 1
    RSYNC_FLAGS="$_input"
}

# ─── Settings prompts ─────────────────────────────────────────────────────────

_prompt_workers() {
    gum style --foreground 99 --bold "Worker Concurrency"
    local _input
    _input="$(gum input --header "$(_input_header MAX_UNZIP "(parallel extract workers, ≥ 1)")" --value "$MAX_UNZIP")" || return 1
    MAX_UNZIP="$_input"
    _input="$(gum input --header "$(_input_header MAX_DISPATCH "(parallel dispatch workers, ≥ 1)")" --value "$MAX_DISPATCH")" || return 1
    MAX_DISPATCH="$_input"
}

_prompt_scratch() {
    gum style --foreground 99 --bold "Scratch Disk"
    _info "EXTRACT_DIR, COPY_DIR, QUEUE_DIR derive from this"
    local _input
    _input="$(_pick_path "SCRATCH_DISK_DIR" "$SCRATCH_DISK_DIR" --dir-only --var SCRATCH_DISK_DIR)" || return 1
    SCRATCH_DISK_DIR="$_input"
    EXTRACT_DIR="$SCRATCH_DISK_DIR/iso_pipeline"
    COPY_DIR="$SCRATCH_DISK_DIR/iso_pipeline_copies"
    QUEUE_DIR="$SCRATCH_DISK_DIR/iso_pipeline_queue"
}

_prompt_debug_flags() {
    gum style --foreground 99 --bold "Debug & Resume Flags"
    local _input
    _input="$(gum choose --header "$(_input_header DEBUG_IND "(verbose logging)")" "0" "1" --selected="$DEBUG_IND")" || return 1
    DEBUG_IND="$_input"
    _input="$(gum choose --header "$(_input_header RESUME_PLANNER_IND "(cold-restart fast-path)")" "0" "1" --selected="$RESUME_PLANNER_IND")" || return 1
    RESUME_PLANNER_IND="$_input"
}

_prompt_dir_overrides() {
    gum style --foreground 99 --bold "Directory Overrides"
    _info "Override SCRATCH_DISK_DIR derivations"
    local _input
    _info "Select extraction directory"
    _input="$(_pick_path "EXTRACT_DIR" "$EXTRACT_DIR" --dir-only --var EXTRACT_DIR)" || return 1
    EXTRACT_DIR="$_input"
    _info "Select archive copy directory"
    _input="$(_pick_path "COPY_DIR" "$COPY_DIR" --dir-only --var COPY_DIR)" || return 1
    COPY_DIR="$_input"
    _info "Select queue directory"
    _input="$(_pick_path "QUEUE_DIR" "$QUEUE_DIR" --dir-only --var QUEUE_DIR)" || return 1
    QUEUE_DIR="$_input"
}

_prompt_tuning() {
    gum style --foreground 99 --bold "Tuning Parameters"
    local _input
    _input="$(gum input --header "$(_input_header SPACE_OVERHEAD_PCT "(integer ≥ 0)")" --value "$SPACE_OVERHEAD_PCT")" || return 1
    SPACE_OVERHEAD_PCT="$_input"
    _input="$(gum input --header "$(_input_header MAX_RECOVERY_ATTEMPTS "(integer ≥ 1)")" --value "$MAX_RECOVERY_ATTEMPTS")" || return 1
    MAX_RECOVERY_ATTEMPTS="$_input"
    _input="$(gum input --header "$(_input_header DISPATCH_POLL_INITIAL_MS "(integer ≥ 1, ≤ MAX)")" --value "$DISPATCH_POLL_INITIAL_MS")" || return 1
    DISPATCH_POLL_INITIAL_MS="$_input"
    _input="$(gum input --header "$(_input_header DISPATCH_POLL_MAX_MS "(integer ≥ INITIAL)")" --value "$DISPATCH_POLL_MAX_MS")" || return 1
    DISPATCH_POLL_MAX_MS="$_input"
    _input="$(gum input --header "$(_input_header SPACE_RETRY_BACKOFF_INITIAL_SEC "(decimal ≥ 0, ≤ MAX)")" --value "$SPACE_RETRY_BACKOFF_INITIAL_SEC")" || return 1
    SPACE_RETRY_BACKOFF_INITIAL_SEC="$_input"
    _input="$(gum input --header "$(_input_header SPACE_RETRY_BACKOFF_MAX_SEC "(decimal ≥ INITIAL)")" --value "$SPACE_RETRY_BACKOFF_MAX_SEC")" || return 1
    SPACE_RETRY_BACKOFF_MAX_SEC="$_input"
}

_prompt_strip_list() {
    gum style --foreground 99 --bold "Strip List"
    if [[ -n "$EXTRACT_STRIP_LIST" ]]; then
        _info "Current: $EXTRACT_STRIP_LIST"
    fi
    if gum confirm "Select a strip list file?" --default=false; then
        local _input
        _input="$(_pick_path "EXTRACT_STRIP_LIST" "$ROOT_DIR" --var EXTRACT_STRIP_LIST)" || return 1
        EXTRACT_STRIP_LIST="$_input"
    elif gum confirm "Clear strip list?" --default=false; then
        EXTRACT_STRIP_LIST=""
    fi
}

# ─── Validation ───────────────────────────────────────────────────────────────

_val_pos_int() {
    local name="$1" val="$2"
    if [[ ! "$val" =~ ^[0-9]+$ ]] || (( val < 1 )); then
        echo "$name must be a positive integer (≥ 1), got '$val'"
    fi
}

_val_nn_int() {
    local name="$1" val="$2"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        echo "$name must be a non-negative integer, got '$val'"
    fi
}

_val_nn_decimal() {
    local name="$1" val="$2"
    if [[ ! "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$name must be a non-negative number, got '$val'"
    fi
}

_val_nonempty() {
    local name="$1" val="$2"
    if [[ -z "$val" ]]; then
        echo "$name must not be empty"
    fi
}

_val_path_writable() {
    local name="$1" val="$2"
    if [[ -d "$val" ]]; then
        if [[ ! -w "$val" ]]; then
            echo "$name: directory '$val' exists but is not writable"
        fi
    else
        local parent="$val"
        while [[ "$parent" != "/" && ! -d "$parent" ]]; do
            parent="$(dirname "$parent")"
        done
        if [[ ! -w "$parent" ]]; then
            echo "$name: nearest ancestor '$parent' is not writable"
        fi
    fi
}

# Collects all validation errors into the nameref array passed as $1.
# Caller inspects the array length to determine pass/fail.
_validate_all() {
    local -n _errs=$1
    _errs=()

    local _err_msg

    # Essential
    _err_msg="$(_val_pos_int MAX_UNZIP "$MAX_UNZIP")";                     [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_pos_int MAX_DISPATCH "$MAX_DISPATCH")";               [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_path_writable SCRATCH_DISK_DIR "$SCRATCH_DISK_DIR")"; [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_path_writable EXTRACT_DIR "$EXTRACT_DIR")";           [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_path_writable COPY_DIR "$COPY_DIR")";                 [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")

    # Adapter-specific
    if [[ -v DETECTED[lvol] ]]; then
        _err_msg="$(_val_nonempty LVOL_MOUNT_POINT "$LVOL_MOUNT_POINT")";      [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
        if [[ -n "$LVOL_MOUNT_POINT" && ! -d "$LVOL_MOUNT_POINT" ]]; then
            _errs+=("LVOL_MOUNT_POINT: '$LVOL_MOUNT_POINT' does not exist or is not a directory")
        elif [[ -n "$LVOL_MOUNT_POINT" && ! -w "$LVOL_MOUNT_POINT" ]]; then
            _errs+=("LVOL_MOUNT_POINT: '$LVOL_MOUNT_POINT' is not writable")
        fi
    fi
    if [[ -v DETECTED[ftp] ]]; then
        _err_msg="$(_val_nonempty FTP_HOST "$FTP_HOST")";                  [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
        _err_msg="$(_val_pos_int FTP_PORT "$FTP_PORT")";                   [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    fi
    if [[ -v DETECTED[rclone] ]]; then
        _err_msg="$(_val_nonempty RCLONE_REMOTE "$RCLONE_REMOTE")";        [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    fi
    if [[ -v DETECTED[rsync] ]]; then
        _err_msg="$(_val_nonempty RSYNC_DEST_BASE "$RSYNC_DEST_BASE")";    [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
        _err_msg="$(_val_pos_int RSYNC_SSH_PORT "$RSYNC_SSH_PORT")";       [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    fi

    # Advanced (always validated — they have defaults even if not prompted)
    _err_msg="$(_val_nn_int SPACE_OVERHEAD_PCT "$SPACE_OVERHEAD_PCT")";    [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_pos_int MAX_RECOVERY_ATTEMPTS "$MAX_RECOVERY_ATTEMPTS")"; [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_pos_int DISPATCH_POLL_INITIAL_MS "$DISPATCH_POLL_INITIAL_MS")"; [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_pos_int DISPATCH_POLL_MAX_MS "$DISPATCH_POLL_MAX_MS")"; [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_nn_decimal SPACE_RETRY_BACKOFF_INITIAL_SEC "$SPACE_RETRY_BACKOFF_INITIAL_SEC")"; [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_nn_decimal SPACE_RETRY_BACKOFF_MAX_SEC "$SPACE_RETRY_BACKOFF_MAX_SEC")"; [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")
    _err_msg="$(_val_path_writable QUEUE_DIR "$QUEUE_DIR")";               [[ -n "$_err_msg" ]] && _errs+=("$_err_msg")

    # Cross-var constraints
    if [[ "$DISPATCH_POLL_INITIAL_MS" =~ ^[0-9]+$ && "$DISPATCH_POLL_MAX_MS" =~ ^[0-9]+$ ]]; then
        if (( DISPATCH_POLL_INITIAL_MS > DISPATCH_POLL_MAX_MS )); then
            _errs+=("DISPATCH_POLL_INITIAL_MS ($DISPATCH_POLL_INITIAL_MS) must not exceed DISPATCH_POLL_MAX_MS ($DISPATCH_POLL_MAX_MS)")
        fi
    fi
    if [[ "$SPACE_RETRY_BACKOFF_INITIAL_SEC" =~ ^[0-9]+(\.[0-9]+)?$ && \
          "$SPACE_RETRY_BACKOFF_MAX_SEC" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if awk -v a="$SPACE_RETRY_BACKOFF_INITIAL_SEC" -v b="$SPACE_RETRY_BACKOFF_MAX_SEC" \
            'BEGIN { exit (a > b) ? 0 : 1 }'; then
            _errs+=("SPACE_RETRY_BACKOFF_INITIAL_SEC ($SPACE_RETRY_BACKOFF_INITIAL_SEC) must not exceed SPACE_RETRY_BACKOFF_MAX_SEC ($SPACE_RETRY_BACKOFF_MAX_SEC)")
        fi
    fi

    # Warning (non-blocking)
    if [[ "$EXTRACT_DIR" == "$COPY_DIR" ]]; then
        _warn "EXTRACT_DIR and COPY_DIR are the same path — this works but is not recommended"
    fi
}

# ─── Launch ───────────────────────────────────────────────────────────────────

# Assembles the environment and exec's into the pipeline entry point.
_build_and_launch() {
    local env_args=()

    env_args+=("DEBUG_IND=$DEBUG_IND")
    env_args+=("RESUME_PLANNER_IND=$RESUME_PLANNER_IND")
    env_args+=("MAX_UNZIP=$MAX_UNZIP")
    env_args+=("MAX_DISPATCH=$MAX_DISPATCH")
    env_args+=("SCRATCH_DISK_DIR=$SCRATCH_DISK_DIR")
    env_args+=("QUEUE_DIR=$QUEUE_DIR")
    env_args+=("EXTRACT_DIR=$EXTRACT_DIR")
    env_args+=("COPY_DIR=$COPY_DIR")
    env_args+=("SPACE_OVERHEAD_PCT=$SPACE_OVERHEAD_PCT")
    env_args+=("MAX_RECOVERY_ATTEMPTS=$MAX_RECOVERY_ATTEMPTS")
    env_args+=("DISPATCH_POLL_INITIAL_MS=$DISPATCH_POLL_INITIAL_MS")
    env_args+=("DISPATCH_POLL_MAX_MS=$DISPATCH_POLL_MAX_MS")
    env_args+=("SPACE_RETRY_BACKOFF_INITIAL_SEC=$SPACE_RETRY_BACKOFF_INITIAL_SEC")
    env_args+=("SPACE_RETRY_BACKOFF_MAX_SEC=$SPACE_RETRY_BACKOFF_MAX_SEC")
    [[ -n "$EXTRACT_STRIP_LIST" ]] && env_args+=("EXTRACT_STRIP_LIST=$EXTRACT_STRIP_LIST")

    if [[ -v DETECTED[lvol] ]]; then
        env_args+=("LVOL_MOUNT_POINT=$LVOL_MOUNT_POINT")
    fi
    if [[ -v DETECTED[ftp] ]]; then
        env_args+=("FTP_HOST=$FTP_HOST")
        env_args+=("FTP_USER=$FTP_USER")
        env_args+=("FTP_PASS=$FTP_PASS")
        env_args+=("FTP_PORT=$FTP_PORT")
    fi
    if [[ -v DETECTED[hdl] ]]; then
        env_args+=("HDL_DUMP_BIN=$HDL_DUMP_BIN")
    fi
    if [[ -v DETECTED[rclone] ]]; then
        env_args+=("RCLONE_REMOTE=$RCLONE_REMOTE")
        env_args+=("RCLONE_DEST_BASE=$RCLONE_DEST_BASE")
        [[ -n "$RCLONE_FLAGS" ]] && env_args+=("RCLONE_FLAGS=$RCLONE_FLAGS")
    fi
    if [[ -v DETECTED[rsync] ]]; then
        env_args+=("RSYNC_DEST_BASE=$RSYNC_DEST_BASE")
        [[ -n "$RSYNC_HOST" ]]  && env_args+=("RSYNC_HOST=$RSYNC_HOST")
        [[ -n "$RSYNC_USER" ]]  && env_args+=("RSYNC_USER=$RSYNC_USER")
        env_args+=("RSYNC_SSH_PORT=$RSYNC_SSH_PORT")
        [[ -n "$RSYNC_FLAGS" ]] && env_args+=("RSYNC_FLAGS=$RSYNC_FLAGS")
    fi

    exec env "${env_args[@]}" bash "$PIPELINE_ENTRY" "$JOBS_PATH"
}

# ─── Menu helpers ─────────────────────────────────────────────────────────────

# Returns the current status for a given action key. Statuses form a state
# machine: ok, pending, locked (prerequisite missing), skip (optional,
# unconfigured), error (validation failed), ready (launch-eligible).
_action_status() {
    local _action="$1"
    case "$_action" in
        jobs)
            if [[ -n "${JOBS_PATH:-}" && ( -f "$JOBS_PATH" || -d "$JOBS_PATH" ) ]]; then
                echo "ok"
            else
                echo "pending"
            fi
            ;;
        detect)
            if (( ${#DETECTED[@]} > 0 )); then
                echo "ok"
            elif [[ -n "${JOBS_PATH:-}" ]]; then
                echo "pending"
            else
                echo "locked"
            fi
            ;;
        cfg_lvol)   echo "${_STATUS_CFG_LVOL:-pending}" ;;
        cfg_ftp)    echo "${_STATUS_CFG_FTP:-pending}" ;;
        cfg_hdl)    echo "${_STATUS_CFG_HDL:-pending}" ;;
        cfg_rclone) echo "${_STATUS_CFG_RCLONE:-pending}" ;;
        cfg_rsync)  echo "${_STATUS_CFG_RSYNC:-pending}" ;;
        workers)    echo "${_STATUS_WORKERS:-pending}" ;;
        scratch)    echo "${_STATUS_SCRATCH:-pending}" ;;
        debug)      echo "${_STATUS_DEBUG:-skip}" ;;
        dirs)       echo "${_STATUS_DIRS:-skip}" ;;
        tuning)     echo "${_STATUS_TUNING:-skip}" ;;
        strip)      echo "${_STATUS_STRIP:-skip}" ;;
        validate)
            if [[ "$(_action_status jobs)" != "ok" || "$(_action_status detect)" != "ok" ]]; then
                echo "locked"; return
            fi
            local _adapter
            for _adapter in "${!DETECTED[@]}"; do
                if [[ "$(_action_status "cfg_$_adapter")" != "ok" ]]; then
                    echo "locked"; return
                fi
            done
            if [[ "$(_action_status workers)" != "ok" || "$(_action_status scratch)" != "ok" ]]; then
                echo "locked"; return
            fi
            echo "${_VALIDATE_STATUS:-pending}"
            ;;
        launch)
            if [[ "${_VALIDATE_STATUS:-}" == "ok" ]]; then
                echo "ready"
            else
                echo "locked"
            fi
            ;;
    esac
}

# Maps a status string to a plain-text icon for menu display.
_status_icon() {
    case "$1" in
        ok|ready) printf '[✓]' ;;
        error)    printf '[✗]' ;;
        skip)     printf '[-]' ;;
        locked)   printf '[ ]' ;;
        pending)  printf '[ ]' ;;
    esac
}

# Resets all per-adapter configuration statuses to pending.
# Called when jobs or adapters change and prior config is invalidated.
_reset_adapter_statuses() {
    _STATUS_CFG_LVOL="pending"
    _STATUS_CFG_FTP="pending"
    _STATUS_CFG_HDL="pending"
    _STATUS_CFG_RCLONE="pending"
    _STATUS_CFG_RSYNC="pending"
}

_run_validation() {
    local _validation_errors=()
    _validate_all _validation_errors

    if (( ${#_validation_errors[@]} > 0 )); then
        _VALIDATE_STATUS="error"
        _err "Validation failed:"
        local _err_line
        for _err_line in "${_validation_errors[@]}"; do
            gum log --level error "  $_err_line"
        done
        read -rp "Press Enter to continue..."
    else
        _VALIDATE_STATUS="ok"
        _info "All settings valid"
    fi
}

# Populates two parallel arrays via nameref: display strings for gum choose,
# and corresponding action keys for dispatch. Adapter items are dynamic —
# only included when DETECTED[adapter] is set.
_build_menu() {
    local -n _items=$1 _actions=$2
    _items=() _actions=()
    local _menu_idx=0 _status

    # Jobs
    _status="$(_action_status jobs)"
    local _jobs_label="Select jobs file"
    [[ "$_status" == "ok" ]] && _jobs_label="Jobs: $(basename "$JOBS_PATH")"
    ((++_menu_idx)); _actions[$_menu_idx]="jobs"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_jobs_label")

    # Detect
    _status="$(_action_status detect)"
    local _detect_label="Detect adapters"
    [[ "$_status" == "ok" ]] && _detect_label="Adapters: ${!DETECTED[*]}"
    ((++_menu_idx)); _actions[$_menu_idx]="detect"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_detect_label")

    # Per-adapter config (dynamic — only shown when detected in jobs file)
    if [[ -v DETECTED[lvol] ]]; then
        _status="$(_action_status cfg_lvol)"
        local _lvol_label="Configure lvol"
        [[ "$_status" == "ok" ]] && _lvol_label="lvol: $LVOL_MOUNT_POINT"
        ((++_menu_idx)); _actions[$_menu_idx]="cfg_lvol"
        _items+=("$(_status_icon "$_status") $_menu_idx. $_lvol_label")
    fi
    if [[ -v DETECTED[ftp] ]]; then
        _status="$(_action_status cfg_ftp)"
        local _ftp_label="Configure FTP"
        [[ "$_status" == "ok" ]] && _ftp_label="FTP: $FTP_USER@$FTP_HOST:$FTP_PORT"
        ((++_menu_idx)); _actions[$_menu_idx]="cfg_ftp"
        _items+=("$(_status_icon "$_status") $_menu_idx. $_ftp_label")
    fi
    if [[ -v DETECTED[hdl] ]]; then
        _status="$(_action_status cfg_hdl)"
        local _hdl_label="Configure HDL"
        [[ "$_status" == "ok" ]] && _hdl_label="HDL: $HDL_DUMP_BIN"
        ((++_menu_idx)); _actions[$_menu_idx]="cfg_hdl"
        _items+=("$(_status_icon "$_status") $_menu_idx. $_hdl_label")
    fi
    if [[ -v DETECTED[rclone] ]]; then
        _status="$(_action_status cfg_rclone)"
        local _rclone_label="Configure rclone"
        [[ "$_status" == "ok" ]] && _rclone_label="rclone: $RCLONE_REMOTE$RCLONE_DEST_BASE"
        ((++_menu_idx)); _actions[$_menu_idx]="cfg_rclone"
        _items+=("$(_status_icon "$_status") $_menu_idx. $_rclone_label")
    fi
    if [[ -v DETECTED[rsync] ]]; then
        _status="$(_action_status cfg_rsync)"
        local _rsync_label="Configure rsync"
        [[ "$_status" == "ok" ]] && _rsync_label="rsync: ${RSYNC_HOST:+$RSYNC_HOST:}$RSYNC_DEST_BASE"
        ((++_menu_idx)); _actions[$_menu_idx]="cfg_rsync"
        _items+=("$(_status_icon "$_status") $_menu_idx. $_rsync_label")
    fi

    # Workers
    _status="$(_action_status workers)"
    local _workers_label="Worker concurrency"
    [[ "$_status" == "ok" ]] && _workers_label="Workers: extract=$MAX_UNZIP dispatch=$MAX_DISPATCH"
    ((++_menu_idx)); _actions[$_menu_idx]="workers"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_workers_label")

    # Scratch disk
    _status="$(_action_status scratch)"
    local _scratch_label="Scratch disk"
    [[ "$_status" == "ok" ]] && _scratch_label="Scratch: $SCRATCH_DISK_DIR"
    ((++_menu_idx)); _actions[$_menu_idx]="scratch"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_scratch_label")

    # Debug & resume flags
    _status="$(_action_status debug)"
    local _debug_label="Debug & resume flags"
    [[ "$_status" == "ok" ]] && _debug_label="Debug=$DEBUG_IND  Resume=$RESUME_PLANNER_IND"
    ((++_menu_idx)); _actions[$_menu_idx]="debug"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_debug_label")

    # Directory overrides
    _status="$(_action_status dirs)"
    local _dirs_label="Directory overrides"
    [[ "$_status" == "ok" ]] && _dirs_label="Dir overrides configured"
    ((++_menu_idx)); _actions[$_menu_idx]="dirs"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_dirs_label")

    # Tuning parameters
    _status="$(_action_status tuning)"
    local _tuning_label="Tuning parameters"
    [[ "$_status" == "ok" ]] && _tuning_label="Tuning configured"
    ((++_menu_idx)); _actions[$_menu_idx]="tuning"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_tuning_label")

    # Strip list
    _status="$(_action_status strip)"
    local _strip_label="Strip list"
    [[ "$_status" == "ok" ]] && _strip_label="Strip: ${EXTRACT_STRIP_LIST:-none}"
    ((++_menu_idx)); _actions[$_menu_idx]="strip"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_strip_label")

    # Validate
    _status="$(_action_status validate)"
    local _validate_label="Validate"
    [[ "$_status" == "ok" ]] && _validate_label="Validated"
    [[ "$_status" == "error" ]] && _validate_label="Validation failed — re-run after fixing"
    ((++_menu_idx)); _actions[$_menu_idx]="validate"
    _items+=("$(_status_icon "$_status") $_menu_idx. $_validate_label")

    # Launch
    _status="$(_action_status launch)"
    ((++_menu_idx)); _actions[$_menu_idx]="launch"
    _items+=("$(_status_icon "$_status") $_menu_idx. Launch pipeline")

    # Quit
    _items+=("    Q. Quit")
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    _resolve_root_dir
    _check_gum
    _detect_pipeline_entry
    _load_dotenv
    trap _cleanup EXIT INT TERM
    declare -gA DETECTED=()

    _banner

    # Per-action status tracking — read by _action_status() via dynamic scoping.
    # "pending" = not yet configured, "ok" = done, "skip" = optional/unconfigured.
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

    local _flash=""
    local -a menu_items menu_actions
    local choice selected_step_num selected_action

    while true; do
        clear
        _title
        if [[ -n "$_flash" ]]; then
            _warn "$_flash"
            _flash=""
        fi
        menu_items=() menu_actions=()
        _build_menu menu_items menu_actions

        choice="$(printf '%s\n' "${menu_items[@]}" | gum choose \
            --header "Select a step to configure (Esc to go back):" \
            --cursor "> "
        )" || { gum confirm "Quit?" && exit 0; continue; }

        if [[ "$choice" == *"Q. Quit"* ]]; then
            gum confirm "Quit?" && exit 0
            continue
        fi

        selected_action=""
        if [[ "$choice" =~ [[:space:]]([0-9]+)\. ]]; then
            selected_step_num="${BASH_REMATCH[1]}"
            selected_action="${menu_actions[$selected_step_num]:-}"
        fi

        case "$selected_action" in
            jobs)
                _prompt_jobs_path || continue
                _detect_adapters
                _reset_adapter_statuses
                _VALIDATE_STATUS="pending"
                ;;
            detect)
                if [[ "$(_action_status jobs)" != "ok" ]]; then
                    _flash="Select a jobs file first"
                    continue
                fi
                _detect_adapters
                _reset_adapter_statuses
                _VALIDATE_STATUS="pending"
                ;;
            cfg_lvol)
                _prompt_lvol || continue
                _STATUS_CFG_LVOL="ok"; _VALIDATE_STATUS="pending"
                ;;
            cfg_ftp)
                _prompt_ftp || continue
                _STATUS_CFG_FTP="ok"; _VALIDATE_STATUS="pending"
                ;;
            cfg_hdl)
                _prompt_hdl || continue
                _STATUS_CFG_HDL="ok"; _VALIDATE_STATUS="pending"
                ;;
            cfg_rclone)
                _prompt_rclone || continue
                _STATUS_CFG_RCLONE="ok"; _VALIDATE_STATUS="pending"
                ;;
            cfg_rsync)
                _prompt_rsync || continue
                _STATUS_CFG_RSYNC="ok"; _VALIDATE_STATUS="pending"
                ;;
            workers)
                _prompt_workers || continue
                _STATUS_WORKERS="ok"; _VALIDATE_STATUS="pending"
                ;;
            scratch)
                _prompt_scratch || continue
                _STATUS_SCRATCH="ok"; _VALIDATE_STATUS="pending"
                ;;
            debug)
                _prompt_debug_flags || continue
                _STATUS_DEBUG="ok"; _VALIDATE_STATUS="pending"
                ;;
            dirs)
                _prompt_dir_overrides || continue
                _STATUS_DIRS="ok"; _VALIDATE_STATUS="pending"
                ;;
            tuning)
                _prompt_tuning || continue
                _STATUS_TUNING="ok"; _VALIDATE_STATUS="pending"
                ;;
            strip)
                _prompt_strip_list || continue
                _STATUS_STRIP="ok"; _VALIDATE_STATUS="pending"
                ;;
            validate)
                if [[ "$(_action_status validate)" == "locked" ]]; then
                    _flash="Complete required steps first"
                    continue
                fi
                _run_validation
                ;;
            launch)
                if [[ "${_VALIDATE_STATUS:-}" != "ok" ]]; then
                    _flash="Validate first"
                    continue
                fi
                _show_summary
                if gum confirm "Launch pipeline?" --default=true; then
                    _build_and_launch
                fi
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
