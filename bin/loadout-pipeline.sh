#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR

source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/init.sh"
source "$ROOT_DIR/lib/jobs.sh"
source "$ROOT_DIR/lib/queue.sh"
source "$ROOT_DIR/lib/workers.sh"

JOBS_FILE="${1:-$ROOT_DIR/examples/example.jobs}"

log_info "Initializing environment..."
init_environment

log_info "Loading jobs from $JOBS_FILE..."
load_jobs "$JOBS_FILE"

log_info "Starting pipeline..."
workers_start

log_info "All jobs completed!"
