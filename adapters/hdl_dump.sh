#!/usr/bin/env bash
# =============================================================================
# ADAPTER: HDL DUMP  (PS2 HDLoader HDD injector)
# =============================================================================
# Injects a single PS2 ISO from an extracted directory onto a HDLoader-format
# PS2 HDD via the ps2homebrew/hdl-dump tool. The host-side HDD device (e.g.
# sri:, hdd0:) and the hdl_dump install target (e.g. hdd0:) are operator-wide
# env vars. The job line carries only the per-job fields: format + title.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory. Contents depend on
#               the per-job format field (see $2):
#                 dvd — exactly one *.iso (no *.cue/*.bin). PS2 DVD dumps are
#                       single-track ISO 9660.
#                 cd  — either exactly one *.iso with no *.cue/*.bin, OR
#                       exactly one *.cue plus one or more *.bin files (PS2
#                       CD games with CDDA audio tracks). Archives carrying
#                       both an *.iso AND a *.cue are rejected as ambiguous.
#   $2  dest  — combined field: "<format>|<title>" parsed by
#               parse_hdl_destination. load_jobs already validated this shape
#               at load time; we re-validate here because adapters may be
#               invoked directly by tests.
#
# ENVIRONMENT VARIABLES
#   HDL_DUMP_BIN       — path to hdl_dump binary (default: hdl_dump, on PATH)
#   HDL_INSTALL_TARGET — per-job inject target passed to hdl_dump (e.g. hdd0:)
#   HDL_HOST_DEVICE    — host-side HDD device used for the startup
#                        writability probe (checked by bin/loadout-pipeline.sh,
#                        not this adapter directly).
#
# DEVICE-DESIGNATOR CONTRACT
#   hdl_dump addresses PS2 HDDs by logical id (hdd0:, sri:, …) and resolves
#   those ids via its config file at $HOME/.hdl_dump.conf. The adapter passes
#   HDL_INSTALL_TARGET to hdl_dump verbatim and relies on the operator's real
#   ~/.hdl_dump.conf for resolution — no scratch-HOME redirection. This
#   matches how the operator normally runs hdl_dump by hand.
#
# Project: https://github.com/ps2homebrew/hdl-dump
# =============================================================================

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/job_format.sh"

src="$1"
dest="$2"

# ── Validate ────────────────────────────────────────────────────────────────

if [[ ! -d "$src" ]]; then
    log_error "hdl: source directory does not exist: $src"
    exit 1
fi

hdl_parsed=$(parse_hdl_destination "$dest") || {
    log_error "hdl: malformed destination spec: $dest"
    log_error "hdl: expected <cd|dvd>|<title>"
    exit 1
}
{ read -r format; read -r title; } <<< "$hdl_parsed"

hdl_bin="${HDL_DUMP_BIN:-hdl_dump}"
install_target="${HDL_INSTALL_TARGET:-}"

# ── Stub-mode escape hatch ──────────────────────────────────────────────────
# Matches the convention in adapters/ftp.sh: operators without a real
# hdl_dump binary installed can set ALLOW_STUB_ADAPTERS=1 to no-op the
# adapter (useful for dev, unit tests, and CI machines without PS2 tooling).
# Stub mode bypasses the HDL_INSTALL_TARGET requirement too — the env var
# only matters once we are actually going to call hdl_dump.
if ! command -v "$hdl_bin" >/dev/null 2>&1; then
    if [[ "${ALLOW_STUB_ADAPTERS:-0}" == 1 ]]; then
        echo "[hdl] STUB — $hdl_bin not on PATH; running as no-op (ALLOW_STUB_ADAPTERS=1)"
        exit 0
    fi
    log_error "hdl: $hdl_bin not found on PATH"
    log_error "hdl: install ps2homebrew/hdl-dump or set HDL_DUMP_BIN to an absolute path"
    exit 1
fi

if [[ -z "$install_target" ]]; then
    log_error "hdl: HDL_INSTALL_TARGET is not set"
    log_error "hdl: set it to the hdl_dump target (e.g. hdd0:) via .env or the wrapper"
    exit 1
fi

# ── Locate the injection image ──────────────────────────────────────────────
# The per-job <cd|dvd> format picks the inject subcommand AND constrains
# which image files are legal under $src:
#
#   dvd → inject_dvd, exactly one *.iso, no *.cue/*.bin. PS2 DVDs are always
#         a single data track; a cue/bin pair at dvd-format is operator error.
#   cd  → inject_cd, prefer a single *.cue (hdl_dump reads the cue and
#         resolves its bin references itself), else fall back to a single
#         *.iso. Reject archives that mix iso + cue — refusing to guess is
#         safer than injecting the wrong image.
#
# 0 matches is always a failure. >1 of the chosen type is a failure too;
# the archive held multiple images and the operator must split the job.

mapfile -t _isos < <(find "$src" -type f -iname '*.iso' -print)
mapfile -t _cues < <(find "$src" -type f -iname '*.cue' -print)
mapfile -t _bins < <(find "$src" -type f -iname '*.bin' -print)

case "$format" in
    dvd)
        if (( ${#_cues[@]} > 0 || ${#_bins[@]} > 0 )); then
            log_error "hdl: dvd-format job must not contain *.cue/*.bin under $src"
            log_error "hdl: inject_dvd accepts a single *.iso only; relabel as 'cd' if the game shipped on CD"
            exit 1
        fi
        if (( ${#_isos[@]} == 0 )); then
            log_error "hdl: no *.iso found under $src"
            exit 1
        fi
        if (( ${#_isos[@]} > 1 )); then
            log_error "hdl: multiple *.iso files under $src; expected exactly one"
            for _iso in "${_isos[@]}"; do
                log_error "hdl:   $_iso"
            done
            exit 1
        fi
        inject_cmd=inject_dvd
        image="${_isos[0]}"
        ;;
    cd)
        if (( ${#_cues[@]} > 0 && ${#_isos[@]} > 0 )); then
            log_error "hdl: cd-format job contains both *.cue and *.iso under $src (ambiguous)"
            log_error "hdl: split into separate jobs or remove the extra image"
            exit 1
        fi
        if (( ${#_cues[@]} > 0 )); then
            if (( ${#_cues[@]} > 1 )); then
                log_error "hdl: multiple *.cue files under $src; expected exactly one"
                for _cue in "${_cues[@]}"; do
                    log_error "hdl:   $_cue"
                done
                exit 1
            fi
            if (( ${#_bins[@]} == 0 )); then
                log_error "hdl: *.cue present but no *.bin found under $src"
                log_error "hdl: inject_cd with a cue requires the cue's referenced *.bin track(s)"
                exit 1
            fi
            inject_cmd=inject_cd
            image="${_cues[0]}"
        else
            if (( ${#_bins[@]} > 0 )); then
                log_error "hdl: *.bin present without *.cue under $src"
                log_error "hdl: *.bin tracks require a *.cue manifest; supply the cue or remove the bin"
                exit 1
            fi
            if (( ${#_isos[@]} == 0 )); then
                log_error "hdl: no *.iso or *.cue/*.bin found under $src"
                exit 1
            fi
            if (( ${#_isos[@]} > 1 )); then
                log_error "hdl: multiple *.iso files under $src; expected exactly one"
                for _iso in "${_isos[@]}"; do
                    log_error "hdl:   $_iso"
                done
                exit 1
            fi
            inject_cmd=inject_cd
            image="${_isos[0]}"
        fi
        ;;
esac

# ── Inject ──────────────────────────────────────────────────────────────────
log_trace "hdl: $inject_cmd $install_target \"$title\" $image"
echo "[hdl] Injecting $image → $install_target as \"$title\" ($format)"

"$hdl_bin" "$inject_cmd" "$install_target" "$title" "$image"

log_trace "hdl: done → $install_target"
