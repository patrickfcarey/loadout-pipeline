#!/usr/bin/env bash
# test/integration/run_integration.sh
#
# Orchestrator for the loadout-pipeline integration suite. Mirrors
# test/run_tests.sh exactly: sources framework + bootstrap, sources each
# suite file in order, prints the final summary, exits non-zero on any
# FAIL. A single EXIT/INT/TERM trap at the top tears down every substrate
# bootstrap provisioned, in reverse order, on every exit path.
#
# Invoked as the container ENTRYPOINT. Running it on the host directly
# will refuse with a bootstrap error because /etc/loadout-integration-container
# is absent outside the container.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT_DIR

INT_ROOT="$ROOT_DIR/test/integration"
PIPELINE="$ROOT_DIR/bin/loadout-pipeline.sh"
export PIPELINE

PASS=0
FAIL=0

# ── shared framework (pass/fail/header/summary) ──────────────────────────────
# shellcheck source=/dev/null
source "$INT_ROOT/helpers/framework.sh"

# ── integration-only helpers ─────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$INT_ROOT/helpers/verify.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/helpers/inject.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/helpers/bootstrap.sh"

# ── substrate provisioning + single teardown trap ────────────────────────────
trap bootstrap_teardown EXIT INT TERM
bootstrap_all

# ── fixtures: generate synthetic archives (cached by presence) ───────────────
bash "$INT_ROOT/fixtures/generate_int_archives.sh"

# Expose the fixtures dir to every suite.
INT_FIXTURES="$INT_ROOT/fixtures/isos"
export INT_FIXTURES

# ── default pipeline env for integration scenarios ──────────────────────────
#
# Each suite is free to override these inline per scenario, but these are
# the sane defaults used by the happy-path tests so every suite does not
# have to restate them.
export EXTRACT_DIR="$INT_EXTRACT"
export COPY_DIR="$INT_EXTRACT/.copies"
export QUEUE_DIR="$INT_QUEUE"
export SD_MOUNT_POINT="$INT_SD_VFAT"
# Stub adapters would refuse to run without this. The integration suite
# does not actually call any stub adapter (stub scenarios hard-fail on
# purpose), but a couple of default example.jobs lines may still route
# through them if a suite accidentally reuses example.jobs. Belt and
# braces: keep them allowed.
export ALLOW_STUB_ADAPTERS=1

# ── suites (sourced in order, all share this shell's PASS/FAIL counters) ─────

# shellcheck source=/dev/null
source "$INT_ROOT/suites/01_prerequisites.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/02_core_pipeline.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/03_precheck.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/04_failure_handling.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/05_space_ledger.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/06_worker_registry.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/07_adapters.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/08_security.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/09_real_archive.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/10_regression.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/11_negative.sh"
# shellcheck source=/dev/null
source "$INT_ROOT/suites/12_docker_pipeline.sh"

# ── summary ──────────────────────────────────────────────────────────────────
_print_summary

# Note for the operator:
#
#   Suite 07: four stub-adapter scenarios (ftp, hdl_dump, rclone, rsync) are
#   expected to FAIL until real implementations land. They are intentionally
#   hard-failing — see test/integration/suites/07_adapters.sh.
#
#   Suite 11: 15 negative scenarios — each deliberately uses a wrong expected
#   value and passes iff the assertion helper detected the injected error.
#   All 15 should PASS. A FAIL in suite 11 means an assertion helper has a
#   blind spot.
#
#   Suite 12: DinD scenarios — invoke the production Docker image as a black
#   box. Requires /var/run/docker.sock and the INT_HOST_SCRATCH shared volume
#   provided by launch.sh. If the socket is absent the suite emits a single
#   [SKIP] PASS and contributes 0 FAILs. When the socket is present, all
#   D1/D2/D3 scenarios should PASS.
if (( FAIL > 0 )); then
    echo ""
    echo "Reminder: stub-adapter scenarios (ftp, hdl_dump, rclone, rsync)"
    echo "are intentional FAILs until those adapters are implemented."
    echo "Suite 11 (negative) and suite 12 (DinD) should contribute 0 FAILs."
fi

[[ $FAIL -eq 0 ]]
