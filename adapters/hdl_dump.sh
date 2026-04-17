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
#   $1  src   — absolute path to the extracted directory; must contain exactly
#               one *.iso
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

# ── Locate the ISO ──────────────────────────────────────────────────────────
# Exactly one *.iso must exist under $src. 0 is a corrupt/empty extract, >1
# means the archive held multiple ISOs and the operator must split them into
# separate jobs — we refuse to guess which one to inject.
mapfile -t _isos < <(find "$src" -type f -iname '*.iso' -print)
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
iso="${_isos[0]}"

# ── Inject ──────────────────────────────────────────────────────────────────
case "$format" in
    cd)  inject_cmd=inject_cd  ;;
    dvd) inject_cmd=inject_dvd ;;
esac

log_trace "hdl: $inject_cmd $install_target \"$title\" $iso"
echo "[hdl] Injecting $iso → $install_target as \"$title\" ($format)"

"$hdl_bin" "$inject_cmd" "$install_target" "$title" "$iso"

log_trace "hdl: done → $install_target"
