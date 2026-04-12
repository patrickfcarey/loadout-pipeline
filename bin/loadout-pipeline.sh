#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR

# Load .env if present. Each variable is only set if not already in the
# environment, so caller-supplied values (MAX_UNZIP=4 bash ...) always win.
if [[ -f "$ROOT_DIR/.env" ]]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*(#|$) ]] && continue
        key="${key// /}"
        [[ -v "$key" ]] || export "$key=$value"
    done < "$ROOT_DIR/.env"
fi

# Fallback defaults if neither .env nor the caller provided a value.
export MAX_UNZIP="${MAX_UNZIP:-2}"
export QUEUE_DIR="${QUEUE_DIR:-/tmp/iso_pipeline_queue}"

# Load libraries
source "$ROOT_DIR/lib/jobs.sh"
source "$ROOT_DIR/lib/queue.sh"
source "$ROOT_DIR/lib/workers.sh"

CONFIG_FILE="${1:-$ROOT_DIR/config/example.jobs}"

echo "[loadout-pipeline] Initializing environment..."
init_environment

echo "[loadout-pipeline] Loading jobs..."
load_jobs "$CONFIG_FILE"

echo "[loadout-pipeline] Starting pipeline..."
start_pipeline

echo "[loadout-pipeline] All jobs completed!"