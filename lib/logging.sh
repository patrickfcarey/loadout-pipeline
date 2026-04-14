#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly
# =============================================================================
# LOGGING FRAMEWORK
# =============================================================================
# Controlled by DEBUG_IND (set in .env or passed at call time):
#   DEBUG_IND=0  (default) — silent; all debug functions are no-ops
#   DEBUG_IND=1            — verbose; logs every function entry/exit + messages
#
# All output goes to stderr so it never interferes with pipeline stdout.
# =============================================================================

# ─── log_enter ────────────────────────────────────────────────────────────────
# Logs entry into the calling function. Reads FUNCNAME[1] automatically so the
# caller passes no argument. No-op when DEBUG_IND is not "1".
#
# Parameters  : none
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG] → <caller>()" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_enter() {
    [[ "${DEBUG_IND:-0}" == "1" ]] || return 0
    echo "[DEBUG] → ${FUNCNAME[1]}()" >&2
}

# ─── log_debug ────────────────────────────────────────────────────────────────
# Logs an arbitrary debug message attributed to the calling function via
# FUNCNAME[1]. No-op when DEBUG_IND is not "1".
#
# Parameters  : $@  message — free-form text to append after the function name
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG]   <caller>: <message>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_debug() {
    [[ "${DEBUG_IND:-0}" == "1" ]] || return 0
    echo "[DEBUG]   ${FUNCNAME[1]}: $*" >&2
}

# ─── log_trace ────────────────────────────────────────────────────────────────
# Logs a raw debug message with no function attribution. Intended for subprocess
# scripts (extract.sh, precheck.sh, dispatch.sh) where FUNCNAME is not
# meaningful because those scripts are not sourced. No-op when DEBUG_IND != "1".
#
# Parameters  : $@  message — free-form text to print
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG] <message>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_trace() {
    [[ "${DEBUG_IND:-0}" == "1" ]] || return 0
    echo "[DEBUG] $*" >&2
}

# ─── log_warn ─────────────────────────────────────────────────────────────────
# Prints a warning message to stderr. Always visible regardless of DEBUG_IND.
#
# Parameters  : $@  message — free-form warning text
# Returns     : 0 always
# Modifies    : nothing — outputs "[WARN]  <message>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
# ─── log_error ────────────────────────────────────────────────────────────────
# Prints an error message to stderr. Always visible regardless of DEBUG_IND.
#
# Parameters  : $@  message — free-form error text
# Returns     : 0 always (does not exit — callers decide whether to abort)
# Modifies    : nothing — outputs "[ERROR] <message>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# When debug is enabled, automatically log every function exit via RETURN trap.
# set -o functrace makes the trap inherited by all sourced functions.
# The case block filters out log_ helpers to avoid noise in the output.
if [[ "${DEBUG_IND:-0}" == "1" ]]; then
    set -o functrace
    trap '
        case "${FUNCNAME[0]}" in
            log_enter|log_debug|log_trace|log_warn|log_error) ;;
            *) echo "[DEBUG] ← ${FUNCNAME[0]}()" >&2 ;;
        esac
    ' RETURN
fi
