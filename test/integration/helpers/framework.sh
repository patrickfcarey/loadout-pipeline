#!/usr/bin/env bash
# test/integration/helpers/framework.sh
#
# Thin wrapper around the unit-suite test framework. Re-sourcing
# test/helpers/framework.sh here keeps a single source of truth for
# pass/fail/header/_print_summary/timing colour codes and the summary
# table across both suites. Integration-only assertions live in
# helpers/verify.sh alongside this file.
#
# The caller (run_integration.sh) must already have defined:
#   ROOT_DIR       — repo root (set by the orchestrator)
#   PASS / FAIL    — global counters, initialised to 0
#
# This wrapper deliberately does NOT re-export EXTRACT_BASE / TEST_JOBS /
# TEST_SD_DIR — those are unit-suite concepts. Integration tests always
# use the substrate paths exported by bootstrap.sh ($INT_EXTRACT,
# $INT_SD_VFAT, etc.).

# shellcheck source=/dev/null
source "$ROOT_DIR/test/helpers/framework.sh"
