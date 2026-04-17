#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly
# =============================================================================
# LOGGING FRAMEWORK
# =============================================================================
# Controlled by DEBUG_IND (set in .env or passed at call time). Levels are
# strictly hierarchical — level N emits everything levels 1..N-1 emit, plus
# the extra helpers introduced at level N.
#
#   DEBUG_IND=0  (default) — silent: only log_info / log_warn / log_error
#                             reach the operator. Every debug helper is a
#                             no-op. This is the production default.
#
#   DEBUG_IND=1            — verbose: enables log_enter / log_debug /
#                             log_trace + an automatic RETURN trap that
#                             logs every function exit in sourced libs.
#
#   DEBUG_IND=2            — extended: everything from level 1 plus
#                             log_cmd / log_var / log_xtrace / log_fs —
#                             meant for narrow, painful debugging sessions
#                             where you need to see which external command
#                             actually ran, which value a variable resolved
#                             to, or which path a worker touched. Level 2
#                             is chatty; use it when you have a reproducer
#                             and are trying to localise the fault, not as
#                             an everyday default.
#
# All debug output goes to stderr so it never interferes with pipeline
# stdout. log_info is the sole stdout writer and is reserved for the
# top-level orchestrator in bin/loadout-pipeline.sh.
#
# DEBUG_IND is validated in lib/config.sh to {0,1,2}; anything else fails
# preflight with exit 2 so a typo ("DEBUG_IND=true") cannot silently
# degrade to level 0.
# =============================================================================

# ─── log_enter ────────────────────────────────────────────────────────────────
# Logs entry into the calling function. Reads FUNCNAME[1] automatically so
# the caller passes no argument. At level 2, any positional arguments
# forwarded to log_enter are echoed as the function's apparent args so
# traces are self-documenting — call sites that want this behaviour do
# `log_enter "$@"` at function top.
#
# Parameters  : $@  optional — function args to echo at level 2
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG] → <caller>()" (or with args at
#                         level 2) to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_enter() {
    case "${DEBUG_IND:-0}" in
        1) echo "[DEBUG] → ${FUNCNAME[1]}()" >&2 ;;
        2) echo "[DEBUG] → ${FUNCNAME[1]}($*)" >&2 ;;
    esac
}

# ─── log_debug ────────────────────────────────────────────────────────────────
# Logs an arbitrary debug message attributed to the calling function via
# FUNCNAME[1]. No-op when DEBUG_IND < 1.
#
# Parameters  : $@  message — free-form text to append after the function name
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG]   <caller>: <message>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_debug() {
    case "${DEBUG_IND:-0}" in
        1|2) echo "[DEBUG]   ${FUNCNAME[1]}: $*" >&2 ;;
    esac
}

# ─── log_trace ────────────────────────────────────────────────────────────────
# Logs a raw debug message with no function attribution. Intended for
# subprocess scripts (extract.sh, precheck.sh, dispatch.sh, adapters/*.sh)
# where FUNCNAME is not meaningful because those scripts are not sourced.
# No-op when DEBUG_IND < 1.
#
# Parameters  : $@  message — free-form text to print
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG] <message>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_trace() {
    case "${DEBUG_IND:-0}" in
        1|2) echo "[DEBUG] $*" >&2 ;;
    esac
}

# ─── log_cmd (level 2) ────────────────────────────────────────────────────────
# Logs the exact external command about to be invoked, before it runs. Used
# by adapters and any site that forks a child process whose invocation an
# operator might need to audit ("did rsync actually get called with
# --append-verify?"). The call site logs THEN runs; this helper does NOT
# execute the command itself — that would couple logging to execution and
# make error handling murky. Keep them separate:
#
#     log_cmd rsync -a "$src/" "$target/"
#     rsync -a "$src/" "$target/"
#
# No-op at DEBUG_IND < 2.
#
# Parameters  : $@  the command and its arguments
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG2] cmd: <cmd> <args>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_cmd() {
    [[ "${DEBUG_IND:-0}" == "2" ]] || return 0
    echo "[DEBUG2] cmd: $*" >&2
}

# ─── log_var (level 2) ────────────────────────────────────────────────────────
# Dumps a variable's current value, attributed to the calling function.
# Intended for tracking down "which value did this actually resolve to?"
# after env-var fallbacks, .env overrides, and caller-supplied overrides
# have all run. Uses bash indirect expansion (${!name}) so the call site
# passes the NAME of the variable, not its value:
#
#     log_var MAX_UNZIP
#     log_var HDL_INSTALL_TARGET
#
# An unset variable prints as empty; log_var does not distinguish unset
# from empty-string because the pipeline's config layer normalises both
# to empty at load time.
#
# No-op at DEBUG_IND < 2.
#
# Parameters  : $1  name — the NAME of the variable to dump (not its value)
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG2]   <caller>: <name>=<value>" to stderr
# Locals      : _name
# ──────────────────────────────────────────────────────────────────────────────
log_var() {
    [[ "${DEBUG_IND:-0}" == "2" ]] || return 0
    local _name="$1"
    echo "[DEBUG2]   ${FUNCNAME[1]}: ${_name}=${!_name:-}" >&2
}

# ─── log_fs (level 2) ─────────────────────────────────────────────────────────
# Logs a filesystem operation (mv, rm, mkdir, flock acquire/release, etc.)
# with a short op tag and the path(s) touched. Used sparingly in the hot
# paths that mutate shared state: queue claims, spool sweeps, ledger
# reservations. Level 2 only — level 1 already gets a RETURN-trap line
# for every function exit, and adding per-op logs at level 1 would flood
# the output.
#
# Parameters  : $@  a short op tag + path(s) — e.g. "mv $src $dst"
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG2] fs: <message>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_fs() {
    [[ "${DEBUG_IND:-0}" == "2" ]] || return 0
    echo "[DEBUG2] fs: $*" >&2
}

# ─── log_xtrace (level 2) ─────────────────────────────────────────────────────
# Raw extended-trace message for subprocess scripts — the level-2 analogue
# of log_trace. Use when you have detail that is useful during a deep-dive
# session but too noisy to emit at level 1. Examples: intermediate values
# in a parser, per-iteration state inside a tight loop, computed offsets.
#
# No-op at DEBUG_IND < 2.
#
# Parameters  : $@  message — free-form text to print
# Returns     : 0 always
# Modifies    : nothing — outputs "[DEBUG2] <message>" to stderr
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
log_xtrace() {
    [[ "${DEBUG_IND:-0}" == "2" ]] || return 0
    echo "[DEBUG2] $*" >&2
}

# ─── log_info ─────────────────────────────────────────────────────────────────
# Prints an operator-facing status message to stdout. Always visible
# regardless of DEBUG_IND. Used by bin/loadout-pipeline.sh for the
# top-level "starting", "loading jobs", "all done" milestones so an
# operator running interactively sees progress without enabling debug
# tracing.
#
# Parameters  : $@  message — free-form status text (shown after a [pipeline] tag)
# Returns     : 0 always
# Modifies    : nothing — outputs "[pipeline] <message>" to stdout
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
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
log_info()  { printf '[pipeline] %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# When debug is enabled (level >= 1), automatically log every function
# exit via RETURN trap. set -o functrace makes the trap inherited by all
# sourced functions. The case block filters out log_ helpers to avoid
# noise in the output. At level 2, the exit line also shows the exit
# status of the function so a non-zero return is visible without grepping
# for it.
case "${DEBUG_IND:-0}" in
    1)
        set -o functrace
        trap '
            case "${FUNCNAME[0]}" in
                log_enter|log_debug|log_trace|log_cmd|log_var|log_fs|log_xtrace|log_warn|log_error) ;;
                *) echo "[DEBUG] ← ${FUNCNAME[0]}()" >&2 ;;
            esac
        ' RETURN
        ;;
    2)
        set -o functrace
        trap '
            _rc=$?
            case "${FUNCNAME[0]}" in
                log_enter|log_debug|log_trace|log_cmd|log_var|log_fs|log_xtrace|log_warn|log_error) ;;
                *) echo "[DEBUG] ← ${FUNCNAME[0]}() rc=${_rc}" >&2 ;;
            esac
        ' RETURN
        ;;
esac
