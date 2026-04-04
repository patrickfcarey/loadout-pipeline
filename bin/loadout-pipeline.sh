#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load libraries
source "$ROOT_DIR/lib/config.sh"
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