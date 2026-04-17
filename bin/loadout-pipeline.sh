#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR

source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/prereq.sh"
source "$ROOT_DIR/lib/init.sh"
source "$ROOT_DIR/lib/jobs.sh"
source "$ROOT_DIR/lib/queue.sh"
source "$ROOT_DIR/lib/workers.sh"

JOBS_FILE="${1:-$ROOT_DIR/examples/example.jobs}"
export JOBS_FILE

log_info "Checking prerequisites..."
check_prerequisites

log_info "Initializing environment..."
init_environment

if [[ -d "$JOBS_FILE" ]]; then
    log_info "Loading jobs from directory $JOBS_FILE (all *.jobs files)..."
else
    log_info "Loading jobs from $JOBS_FILE..."
fi
load_jobs "$JOBS_FILE"

# ── hdl startup probe ──────────────────────────────────────────────────────
# When any hdl job is queued, verify hdl_dump can reach HDL_HOST_DEVICE
# before we start spending cycles on extract/dispatch. A misconfigured device
# (wrong id, missing ~/.hdl_dump.conf entry, PS2 HDD unplugged) would
# otherwise fail one by one per-job at dispatch time. The probe is
# best-effort: if HDL_HOST_DEVICE is unset or hdl_dump is missing we skip it.
_hdl_job_present=0
for _j in "${JOBS[@]}"; do
    if [[ "$_j" == *"|hdl|"* ]]; then _hdl_job_present=1; break; fi
done
if (( _hdl_job_present )) && [[ -n "${HDL_HOST_DEVICE:-}" ]] \
        && command -v "${HDL_DUMP_BIN:-hdl_dump}" >/dev/null 2>&1; then
    log_info "Probing hdl host device $HDL_HOST_DEVICE ..."
    if ! "${HDL_DUMP_BIN:-hdl_dump}" toc "$HDL_HOST_DEVICE" >/dev/null 2>&1; then
        log_error "hdl_dump toc $HDL_HOST_DEVICE failed — check ~/.hdl_dump.conf or device availability"
        exit 1
    fi
fi
unset _hdl_job_present _j

log_info "Starting pipeline..."
workers_start

log_info "All jobs completed!"
