#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly
# =============================================================================
# PREREQUISITE CHECK
# =============================================================================
# Verifies that every required runtime binary is available on $PATH before the
# pipeline touches the filesystem or forks any workers. Fires first in the
# startup sequence so a misconfigured host fails with a clear, actionable error
# message instead of a cryptic failure deep inside an extract or dispatch
# worker.
#
# The check covers only the *unconditional* core dependencies that every run
# needs regardless of which adapters are used. Adapter-specific tools
# (rsync, rclone, ssh, hdl_dump, lftp/curl) are validated lazily by the
# adapters themselves when they are actually invoked — this keeps the preflight
# check non-intrusive for hosts that, for example, only use the SD card adapter
# and therefore have no reason to install rclone.
# =============================================================================

# ─── check_prerequisites ──────────────────────────────────────────────────────
# Verifies that the Bash interpreter and every core binary the pipeline shells
# out to are present on the host. Prints an actionable summary of anything
# missing and exits with code 1 on the first failed run — no partial startup,
# no half-initialized queues, no orphaned scratch directories.
#
# The required command list matches the "Core (always required)" section of
# README.md's "Required packages" table. Adapter-specific tools are not
# checked here; see the header comment above.
#
# Parameters  : none
# Returns     : 0 — all prerequisites satisfied (exits 1 on any missing item)
# Modifies    : nothing — writes diagnostics to stderr via log_error
#
# Locals
#   required_commands — array of core binaries that must resolve on $PATH
#   missing           — names of binaries that failed the command -v probe
#   cmd               — loop variable for each required binary
# ──────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
    log_enter

    if (( BASH_VERSINFO[0] < 4 )); then
        log_error "loadout-pipeline requires bash >= 4.0 (found ${BASH_VERSION})"
        log_error "see README.md section 'Required packages' for install recipes"
        exit 1
    fi

    local required_commands=(
        stat        # coreutils — file metadata probes
        realpath    # coreutils — path canonicalization
        df          # coreutils — free-space queries for the space ledger
        du          # coreutils — archive and extract size accounting
        install     # coreutils — atomic file placement
        find        # findutils — queue scanning, orphan sweep
        xargs       # findutils — batch argument passing
        ps          # procps    — worker-registry liveness checks
        flock       # util-linux — atomic space ledger + worker registry
        7z          # p7zip     — extraction and archive listing
        mkdir mv cp rm ln chmod   # coreutils — filesystem primitives
        awk sed grep sort head tail tr cut wc      # text plumbing used throughout lib/
    )

    local missing=()
    local cmd
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "loadout-pipeline prerequisite check FAILED"
        log_error "the following required commands were not found on \$PATH:"
        for cmd in "${missing[@]}"; do
            log_error "  - $cmd"
        done
        log_error ""
        log_error "install the missing packages and re-run. quick reference:"
        log_error "  Debian/Ubuntu : apt-get install bash coreutils findutils procps util-linux p7zip-full"
        log_error "  Fedora/RHEL   : dnf install bash coreutils findutils procps-ng util-linux p7zip p7zip-plugins"
        log_error "  Arch          : pacman -S bash coreutils findutils procps-ng util-linux p7zip"
        log_error "  Alpine        : apk add bash coreutils findutils procps util-linux p7zip"
        log_error "  macOS (brew)  : brew install bash coreutils findutils p7zip"
        log_error ""
        log_error "see README.md section 'Required packages' for the full list"
        log_error "adapter-specific tools (rsync, rclone, ssh, hdl_dump, lftp) are"
        log_error "checked lazily by each adapter when it is invoked"
        exit 1
    fi
}
