#!/usr/bin/env bash
# test/suites/02_core_pipeline.sh
#
# Core pipeline behaviour: default runs, worker-count variants, and directory
# overrides. These tests verify the happy path end-to-end and that fundamental
# configuration knobs (MAX_UNZIP, QUEUE_DIR, EXTRACT_DIR) are honoured.

# ── test 1: default run ───────────────────────────────────────────────────────
#
# Runs with all defaults: MAX_UNZIP=2, default QUEUE_DIR.

header "Test 1: default run"
echo "  cmd: bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
assert_clean_slate
bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted

# ── test 2: serial extraction (MAX_UNZIP=1) ───────────────────────────────────
#
# Forces serial extraction (MAX_UNZIP=1). Validates that the queue drains
# correctly and no jobs are skipped when only one worker is running.

header "Test 2: serial extraction (MAX_UNZIP=1)"
echo "  cmd: MAX_UNZIP=1 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
assert_clean_slate
MAX_UNZIP=1 bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted

# ── test 3: more workers than jobs ────────────────────────────────────────────
#
# Runs with more workers than there are jobs (5 workers, 3 jobs).
# Verifies that idle workers exit cleanly without deadlocking or double-processing.

header "Test 3: more workers than jobs (MAX_UNZIP=5, 3 jobs)"
echo "  cmd: MAX_UNZIP=5 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
assert_clean_slate
MAX_UNZIP=5 bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted

# ── test 4: custom QUEUE_DIR ──────────────────────────────────────────────────
#
# Overrides QUEUE_DIR so this run's queue is isolated from the default location.
# After the run the custom queue dir should exist but both sub-queues should be empty.

header "Test 4: custom QUEUE_DIR override"
CUSTOM_QUEUE="/tmp/iso_pipeline_test_queue_$$"
echo "  cmd: QUEUE_DIR=$CUSTOM_QUEUE MAX_UNZIP=2 bash bin/loadout-pipeline.sh test/example.jobs"
clean_extracts
assert_clean_slate
QUEUE_DIR="$CUSTOM_QUEUE" MAX_UNZIP=2 bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted
assert_queue_empty "$CUSTOM_QUEUE/extract"
assert_queue_empty "$CUSTOM_QUEUE/dispatch"
rm -rf "$CUSTOM_QUEUE"

# ── test 5: idempotent re-run (no clean between runs) ─────────────────────────
#
# Runs the pipeline twice back-to-back without clearing the extract dir.
# Verifies that init_environment and queue_init do not fail or corrupt state
# when output directories already exist from a previous run.

header "Test 5: idempotent re-run (extracted dirs already exist)"
echo "  cmd (run 1): bash bin/loadout-pipeline.sh test/example.jobs"
bash "$PIPELINE" "$TEST_JOBS"
echo "  cmd (run 2): bash bin/loadout-pipeline.sh test/example.jobs"
bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted

# ── test 6: custom EXTRACT_DIR ───────────────────────────────────────────────
#
# Overrides EXTRACT_DIR so extraction happens in an isolated location.
# Confirms files land in the custom directory, not the default /tmp/iso_pipeline.
# Uses an explicit base dir override on assertions to avoid mutating EXTRACT_BASE.

header "Test 6: custom EXTRACT_DIR override"
CUSTOM_EXTRACT="/tmp/iso_pipeline_test_extract_$$"
CUSTOM_SD6="/tmp/iso_pipeline_test_sd6_$$"
mkdir -p "$CUSTOM_SD6"
echo "  cmd: EXTRACT_DIR=$CUSTOM_EXTRACT SD_MOUNT_POINT=$CUSTOM_SD6 bash bin/loadout-pipeline.sh test/example.jobs"
EXTRACT_DIR="$CUSTOM_EXTRACT" SD_MOUNT_POINT="$CUSTOM_SD6" bash "$PIPELINE" "$TEST_JOBS"
assert_all_extracted "$CUSTOM_EXTRACT"
rm -rf "$CUSTOM_EXTRACT" "$CUSTOM_SD6"
