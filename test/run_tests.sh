#!/usr/bin/env bash
# test/run_tests.sh — loadout-pipeline test suite orchestrator.
#
# Sources the shared framework then each suite file in order. All suite files
# execute in this shell's scope so the PASS/FAIL counters and timing state
# remain consistent across the entire run without any IPC.
#
# Usage: bash test/run_tests.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$ROOT_DIR/test/fixtures"
PIPELINE="$ROOT_DIR/bin/loadout-pipeline.sh"
TEST_JOBS="$ROOT_DIR/test/example.jobs"
EXTRACT_BASE="${EXTRACT_DIR:-/tmp/iso_pipeline}"

# Default SD destination used by tests that do not set their own SD_MOUNT_POINT.
# Exported so all pipeline subprocesses pick it up automatically; tests that
# need isolation pass SD_MOUNT_POINT=<custom> inline to override it.
TEST_SD_DIR="/tmp/iso_pipeline_test_sd_default_$$"
mkdir -p "$TEST_SD_DIR"
export SD_MOUNT_POINT="$TEST_SD_DIR"

# Stub adapters (ftp, hdl, rclone, rsync) refuse to run by default so real
# pipeline invocations don't silently "succeed" without actually transferring
# anything. The test suite intentionally exercises those stubs (example.jobs
# has ftp/hdl entries, and 07_adapters.sh covers rclone/rsync), so opt in
# once globally here. A test that wants to verify the stub refusal can
# override with ALLOW_STUB_ADAPTERS=0 inline.
export ALLOW_STUB_ADAPTERS=1

PASS=0
FAIL=0

# ── shared framework (colours, timing, pass/fail/header, assertions) ──────────
source "$ROOT_DIR/test/helpers/framework.sh"

# ── test suites (sourced in order; all run in this shell's scope) ─────────────
source "$ROOT_DIR/test/suites/01_prerequisites.sh"
source "$ROOT_DIR/test/suites/02_core_pipeline.sh"
source "$ROOT_DIR/test/suites/03_precheck.sh"
source "$ROOT_DIR/test/suites/04_failure_handling.sh"
source "$ROOT_DIR/test/suites/05_space_ledger.sh"
source "$ROOT_DIR/test/suites/06_worker_registry.sh"
source "$ROOT_DIR/test/suites/07_adapters.sh"
source "$ROOT_DIR/test/suites/08_security.sh"
source "$ROOT_DIR/test/suites/09_real_archive.sh"
source "$ROOT_DIR/test/suites/10_regression.sh"

# ── cleanup & summary ─────────────────────────────────────────────────────────
rm -rf "$TEST_SD_DIR"

_finish_test
_print_summary
[[ $FAIL -eq 0 ]]
