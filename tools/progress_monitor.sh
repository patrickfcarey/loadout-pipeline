#!/usr/bin/env bash
# =============================================================================
# PROGRESS MONITOR — real-time TUI dashboard for loadout-pipeline
# =============================================================================
# Polls pipeline state files and renders a live progress display. Launched by
# the smart wrapper after backgrounding the pipeline process.
#
# Arguments:
#   $1  QUEUE_DIR     — pipeline queue directory (contains .meta/, extract/, dispatch/)
#   $2  PIPELINE_PID  — PID of the backgrounded pipeline process
#   $3  LOG_FILE      — path to the pipeline's combined stdout/stderr log
#   $4  JOBS_FILE     — path to the .jobs file (for display only)
# =============================================================================

set -uo pipefail

QUEUE_DIR="$1"
PIPELINE_PID="$2"
LOG_FILE="$3"
JOBS_FILE="$4"

META_DIR="$QUEUE_DIR/.meta"
EXTRACT_QUEUE="$QUEUE_DIR/extract"
DISPATCH_QUEUE="$QUEUE_DIR/dispatch"
REG_FILE="$QUEUE_DIR/.worker_registry"
REG_LOCK="$QUEUE_DIR/.worker_registry.lock"

# ── ANSI ─────────────────────────────────────────────────────────────────────

ESC=$'\033'
BOLD="${ESC}[1m"
DIM="${ESC}[2m"
RESET="${ESC}[0m"
CYAN="${ESC}[36m"
GREEN="${ESC}[32m"
RED="${ESC}[31m"
YELLOW="${ESC}[33m"
MAGENTA="${ESC}[35m"
HIDE_CURSOR="${ESC}[?25l"
SHOW_CURSOR="${ESC}[?25h"
CLEAR_LINE="${ESC}[2K"
CURSOR_HOME="${ESC}[H"

# ── State ────────────────────────────────────────────────────────────────────

declare -A META=()
COMPLETED=0
ERRORS=0
EXTRACT_PENDING=0
DISPATCH_PENDING=0
EXTRACT_INFLIGHT=0
DISPATCH_INFLIGHT=0
declare -a WORKER_LINES=()
TERM_COLS=80
RENDERED_LINES=0

# ── Metadata readers ─────────────────────────────────────────────────────────

_read_meta() {
    META=()
    local info_file="$META_DIR/pipeline_info"
    [[ -f "$info_file" ]] || return 0
    local line key val
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        META["$key"]="$val"
    done < "$info_file"
}

_read_counter() {
    local file="$META_DIR/$1"
    if [[ -f "$file" ]]; then
        cat "$file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

_count_queue() {
    local qdir="$1"
    if [[ -d "$qdir" ]]; then
        find "$qdir" -maxdepth 1 -name '*.job' 2>/dev/null | wc -l
    else
        echo 0
    fi
}

_read_workers() {
    WORKER_LINES=()
    EXTRACT_INFLIGHT=0
    DISPATCH_INFLIGHT=0
    [[ -f "$REG_FILE" ]] || return 0
    local lines
    lines="$(flock -s "$REG_LOCK" cat "$REG_FILE" 2>/dev/null)" || return 0
    local line pid wtype job
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        pid="${line%% *}"
        local rest="${line#* }"
        wtype="${rest%% *}"
        job="${rest#* }"
        WORKER_LINES+=("$pid $wtype $job")
        case "$wtype" in
            extract)  (( EXTRACT_INFLIGHT++ )) || true ;;
            dispatch) (( DISPATCH_INFLIGHT++ )) || true ;;
        esac
    done <<< "$lines"
}

_pipeline_alive() {
    kill -0 "$PIPELINE_PID" 2>/dev/null
}

# ── Rendering helpers ────────────────────────────────────────────────────────

_format_duration() {
    local secs="$1"
    printf '%02d:%02d:%02d' "$(( secs / 3600 ))" "$(( (secs % 3600) / 60 ))" "$(( secs % 60 ))"
}

_progress_bar() {
    local current="$1" total="$2" width="${3:-30}"
    local pct=0 filled=0
    if (( total > 0 )); then
        pct=$(( current * 100 / total ))
        filled=$(( current * width / total ))
    fi
    local empty=$(( width - filled ))
    local bar=""
    local i
    for (( i = 0; i < filled; i++ )); do bar+="█"; done
    for (( i = 0; i < empty; i++ )); do bar+="░"; done
    printf '%s' "$bar"
}

_truncate() {
    local str="$1" max="$2"
    if (( ${#str} > max )); then
        printf '%s…' "${str:0:$(( max - 1 ))}"
    else
        printf '%s' "$str"
    fi
}

_print_line() {
    printf '%s%s%s\n' "$CLEAR_LINE" "$1" "$RESET"
    (( RENDERED_LINES++ )) || true
}

# ── Main render ──────────────────────────────────────────────────────────────

_render() {
    local now effective elapsed speed_str eta_str
    now="$(date +%s)"
    effective="${META[effective_jobs]:-0}"
    local start="${META[start_time]:-$now}"
    elapsed=$(( now - start ))
    local bar_width=30

    # Speed and ETA
    speed_str="--"
    eta_str="--:--:--"
    if (( COMPLETED > 0 && elapsed > 0 )); then
        local speed_x10=$(( COMPLETED * 600 / elapsed ))
        speed_str="$(( speed_x10 / 10 )).$(( speed_x10 % 10 ))/min"
        local remaining=$(( effective - COMPLETED ))
        local eta_secs=$(( remaining * elapsed / COMPLETED ))
        eta_str="$(_format_duration "$eta_secs")"
    fi

    # Extract progress: effective - pending - inflight
    local extract_done=0
    if (( effective > 0 )); then
        extract_done=$(( effective - EXTRACT_PENDING - EXTRACT_INFLIGHT ))
        (( extract_done < 0 )) && extract_done=0
    fi

    RENDERED_LINES=0
    printf '%s' "$CURSOR_HOME"

    # Header
    local elapsed_str
    elapsed_str="$(_format_duration "$elapsed")"
    _print_line "${BOLD}${MAGENTA} LOADOUT PIPELINE${RESET}${DIM}$(printf '%*s' "$(( TERM_COLS - 38 ))" "")elapsed ${elapsed_str}${RESET}"
    _print_line "${DIM}$(printf '─%.0s' $(seq 1 "$TERM_COLS"))${RESET}"

    # Jobs info
    local jobs_name
    jobs_name="$(basename "${META[jobs_file]:-$JOBS_FILE}")"
    local total="${META[total_jobs]:-0}"
    local skipped="${META[skipped_jobs]:-0}"
    _print_line " Jobs: ${BOLD}$jobs_name${RESET}  (${total} total, ${skipped} skipped, ${effective} to process)"
    _print_line ""

    # Overall progress
    local overall_bar
    overall_bar="$(_progress_bar "$COMPLETED" "$effective" "$bar_width")"
    _print_line " ${BOLD}Overall${RESET}   [${GREEN}${overall_bar}${RESET}] $(printf '%3d/%-3d  %3d%%' "$COMPLETED" "$effective" "$(( effective > 0 ? COMPLETED * 100 / effective : 0 ))")  ${CYAN}${speed_str}${RESET}"

    # Extract progress
    local extract_bar
    extract_bar="$(_progress_bar "$extract_done" "$effective" "$bar_width")"
    _print_line " ${BOLD}Extract${RESET}   [${CYAN}${extract_bar}${RESET}] $(printf '%3d/%-3d  %3d%%' "$extract_done" "$effective" "$(( effective > 0 ? extract_done * 100 / effective : 0 ))")"

    # Dispatch progress
    local dispatch_bar
    dispatch_bar="$(_progress_bar "$COMPLETED" "$effective" "$bar_width")"
    _print_line " ${BOLD}Dispatch${RESET}  [${CYAN}${dispatch_bar}${RESET}] $(printf '%3d/%-3d  %3d%%' "$COMPLETED" "$effective" "$(( effective > 0 ? COMPLETED * 100 / effective : 0 ))")"

    _print_line ""

    # Workers
    _print_line " ${BOLD}Workers${RESET}  (${META[max_extract]:-?}E + ${META[max_dispatch]:-?}D)"

    local e_idx=0 d_idx=0
    local max_job_len=$(( TERM_COLS - 22 ))
    local line pid wtype job job_display
    for line in "${WORKER_LINES[@]}"; do
        pid="${line%% *}"
        local rest="${line#* }"
        wtype="${rest%% *}"
        job="${rest#* }"
        # Extract the archive basename from the job string: ~path/to/game.7z|adapter|dest~
        local stripped="${job#\~}"
        stripped="${stripped%\~}"
        local archive="${stripped%%|*}"
        local adapter="${stripped#*|}"
        adapter="${adapter%%|*}"
        archive="$(basename "$archive")"
        job_display="$(_truncate "$archive → $adapter" "$max_job_len")"
        case "$wtype" in
            extract)
                (( e_idx++ )) || true
                _print_line "   ${CYAN}E${e_idx}${RESET}  ${DIM}PID ${pid}${RESET}  ${job_display}"
                ;;
            dispatch)
                (( d_idx++ )) || true
                _print_line "   ${GREEN}D${d_idx}${RESET}  ${DIM}PID ${pid}${RESET}  ${job_display}"
                ;;
        esac
    done

    # Show idle worker slots
    local max_e="${META[max_extract]:-0}" max_d="${META[max_dispatch]:-0}"
    while (( e_idx < max_e )); do
        (( e_idx++ )) || true
        _print_line "   ${DIM}E${e_idx}  idle${RESET}"
    done
    while (( d_idx < max_d )); do
        (( d_idx++ )) || true
        _print_line "   ${DIM}D${d_idx}  idle${RESET}"
    done

    _print_line ""

    # Footer
    local err_color="$GREEN"
    (( ERRORS > 0 )) && err_color="$RED"
    local log_name
    log_name="$(basename "$LOG_FILE")"
    _print_line " ${err_color}Errors: ${ERRORS}${RESET}    ETA: ~${eta_str}$(printf '%*s' "$(( TERM_COLS - 30 - ${#eta_str} - ${#log_name} ))" "")Log: ${DIM}${log_name}${RESET}"

    # Clear any leftover lines from a previous render with more workers
    local i
    for (( i = RENDERED_LINES; i < 30; i++ )); do
        printf '%s\n' "$CLEAR_LINE"
    done
}

_render_final() {
    local now elapsed elapsed_str
    now="$(date +%s)"
    elapsed=$(( now - ${META[start_time]:-$now} ))
    elapsed_str="$(_format_duration "$elapsed")"

    # Re-read counters one last time
    COMPLETED=$(_read_counter completed)
    ERRORS=$(_read_counter errors)
    local effective="${META[effective_jobs]:-0}"

    printf '\n'
    if (( ERRORS == 0 && COMPLETED >= effective )); then
        printf '%s%s PIPELINE COMPLETED %s\n' "$BOLD" "$GREEN" "$RESET"
    else
        printf '%s%s PIPELINE FINISHED WITH ERRORS %s\n' "$BOLD" "$RED" "$RESET"
    fi
    printf '\n'
    printf ' Completed: %d/%d    Errors: %d    Time: %s\n' \
        "$COMPLETED" "$effective" "$ERRORS" "$elapsed_str"
    printf ' Log: %s\n\n' "$LOG_FILE"
}

# ── Main ─────────────────────────────────────────────────────────────────────

_monitor_main() {
    printf '%s' "$HIDE_CURSOR"
    trap 'printf "%s" "$SHOW_CURSOR"' EXIT
    clear

    # Wait for metadata to appear (pipeline may still be initializing)
    local wait_count=0
    while [[ ! -f "$META_DIR/pipeline_info" ]]; do
        if ! _pipeline_alive; then
            printf '%s' "$SHOW_CURSOR"
            echo "Pipeline exited before writing metadata."
            return 1
        fi
        (( wait_count++ )) || true
        if (( wait_count > 30 )); then
            printf '%s' "$SHOW_CURSOR"
            echo "Timed out waiting for pipeline metadata."
            return 1
        fi
        sleep 1
    done

    _read_meta
    TERM_COLS="$(tput cols 2>/dev/null || echo 80)"

    while true; do
        TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
        COMPLETED=$(_read_counter completed)
        ERRORS=$(_read_counter errors)
        EXTRACT_PENDING=$(_count_queue "$EXTRACT_QUEUE")
        DISPATCH_PENDING=$(_count_queue "$DISPATCH_QUEUE")
        _read_workers
        _render

        if ! _pipeline_alive; then
            sleep 1
            _render_final
            break
        fi
        sleep 1
    done

    printf '%s' "$SHOW_CURSOR"
}

_monitor_main
