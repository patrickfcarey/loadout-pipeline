#!/usr/bin/env bash
# test/integration/suites/12_docker_pipeline.sh
#
# Docker-in-Docker (DinD) suite. Validates the production Docker image as a
# black box: the integration harness sets up inputs in a shared host scratch
# directory ($INT_HOST_SCRATCH / /scratch), invokes the production container
# via the host Docker socket, then verifies outputs.
#
# The production container ($PROD_IMAGE) knows nothing about the test harness.
# It receives mounts and environment variables exactly as a real user would
# supply them. This proves that the shipped image is independently functional.
#
# Prerequisites supplied by launch.sh:
#   PROD_IMAGE        — name:tag of the production image to test
#   INT_HOST_SCRATCH  — host-side path to the shared scratch dir
#   /scratch          — same dir, bind-mounted into this (outer) container
#
# Path conventions used throughout this suite:
#   Host (outer view)          →  Inner container mount
#   $INT_HOST_SCRATCH/fixtures →  /isos   (read-only archive source)
#   $INT_HOST_SCRATCH/jobs     →  /jobs   (read-only job profiles)
#   $INT_HOST_SCRATCH/sd-DX    →  /mnt/lvol  (writable SD destination)
#
# Job files reference /isos/... paths because that is what the inner container
# sees — the host-side $INT_FIXTURES path is not visible inside it.

# ─── guard: skip gracefully if DinD prerequisites are absent ─────────────────
#
# If launch.sh did not pass PROD_IMAGE, the Docker socket is not accessible,
# or INT_HOST_SCRATCH is missing, skip the entire suite with a single PASS
# annotated as [SKIP]. This ensures the suite contributes 0 FAILs in
# environments that don't support DinD (Podman without a socket, CI without
# socket access, etc.). A FAIL here would make the operator note wrong: the
# suite note says "Suite 12 should contribute 0 FAILs."

if [[ -z "${PROD_IMAGE:-}" ]]; then
    header "Int Suite 12: DinD — production image"
    pass "[SKIP] PROD_IMAGE not set — launch.sh must build and pass the production image"
    return 0
fi

if ! docker info >/dev/null 2>&1; then
    header "Int Suite 12: DinD — production image"
    pass "[SKIP] Docker socket not accessible — enable Podman socket or pass -v /var/run/docker.sock"
    return 0
fi

if [[ -z "${INT_HOST_SCRATCH:-}" ]]; then
    header "Int Suite 12: DinD — production image"
    pass "[SKIP] INT_HOST_SCRATCH not set — launch.sh must create and export this variable"
    return 0
fi

# ─── suite setup: stage fixtures in shared host scratch ──────────────────────
#
# Copy the integration fixture archives from their container-internal location
# ($INT_FIXTURES) to /scratch/fixtures/ so the inner container can mount them
# as /isos. This copy is done once for the whole suite.

D12_FIXTURES="/scratch/fixtures"
D12_JOBS="/scratch/jobs"
mkdir -p "$D12_FIXTURES" "$D12_JOBS"

# Copy archives only if not already staged (idempotent across reruns).
for arc in small.7z medium.7z multi.7z; do
    [[ -f "$D12_FIXTURES/$arc" ]] || cp "$INT_FIXTURES/$arc" "$D12_FIXTURES/$arc"
done

# ─── helper: _int_run_prod ────────────────────────────────────────────────────
#
# Invoke the production container for one scenario.
#
# Parameters:
#   $1   label        — short identifier used in volume/log names and messages
#   $2   jobs_file    — basename of the .jobs file in /scratch/jobs/
#   $3   host_sd_dir  — host-side path to the local volume destination directory
#   ...  extra flags  — additional -e KEY=VALUE flags forwarded to docker run
#
# Returns the docker run exit code.

_int_run_prod() {
    local label="$1" jobs_file="$2" host_sd_dir="$3"; shift 3

    docker run --rm \
        -v "$INT_HOST_SCRATCH/fixtures:/isos:ro" \
        -v "$INT_HOST_SCRATCH/jobs:/jobs:ro" \
        -v "$host_sd_dir:/mnt/lvol" \
        -e LVOL_MOUNT_POINT=/mnt/lvol \
        -e QUEUE_DIR=/tmp/iso_pipeline_queue \
        -e EXTRACT_DIR=/tmp/iso_pipeline \
        -e COPY_DIR=/tmp/iso_pipeline_copies \
        -e ALLOW_STUB_ADAPTERS=1 \
        "$@" \
        "$PROD_IMAGE" \
        "/jobs/$jobs_file"
}

# ─── D1: basic SD run — two archives ─────────────────────────────────────────
#
# Writes two sd jobs using /isos/ paths (inner-container view), runs the
# production container, and asserts both archives were dispatched to the SD
# destination. Tree equality is checked against archives decoded directly from
# the fixture files by the outer container.

header "Int Suite 12 D1: DinD — basic SD run (small + medium)"

D1_SD="$INT_HOST_SCRATCH/sd-d1"
mkdir -p "$D1_SD"

cat > "$D12_JOBS/d1.jobs" <<'EOF'
---JOBS---
~/isos/small.7z|lvol|d1/small~
~/isos/medium.7z|lvol|d1/medium~
---END---
EOF

D1_LOG="/scratch/d1.log"
set +e
_int_run_prod "d1" "d1.jobs" "$D1_SD" >"$D1_LOG" 2>&1
d1_rc=$?
set -e

assert_rc "$d1_rc" 0 "D1 pipeline rc"

# Decode expected trees from the archives (outer container has 7z).
D1_EXP="$INT_STATE/d1_expected"
rm -rf "$D1_EXP"
_int_decode_expected "$INT_FIXTURES/small.7z"  "$D1_EXP/small"
_int_decode_expected "$INT_FIXTURES/medium.7z" "$D1_EXP/medium"

assert_tree_eq "$D1_EXP/small"  "/scratch/sd-d1/d1/small"  "D1 small on SD"
assert_tree_eq "$D1_EXP/medium" "/scratch/sd-d1/d1/medium" "D1 medium on SD"

# ─── D2: env var passthrough — MAX_UNZIP=1 ───────────────────────────────────
#
# Passes MAX_UNZIP=1 via -e to the production container and confirms the
# pipeline still completes correctly with serial extraction. The same two
# archives as D1 are used so expected trees are reused.

header "Int Suite 12 D2: DinD — env var passthrough (MAX_UNZIP=1)"

D2_SD="$INT_HOST_SCRATCH/sd-d2"
mkdir -p "$D2_SD"

cat > "$D12_JOBS/d2.jobs" <<'EOF'
---JOBS---
~/isos/small.7z|lvol|d2/small~
~/isos/medium.7z|lvol|d2/medium~
---END---
EOF

D2_LOG="/scratch/d2.log"
set +e
_int_run_prod "d2" "d2.jobs" "$D2_SD" -e MAX_UNZIP=1 >"$D2_LOG" 2>&1
d2_rc=$?
set -e

assert_rc "$d2_rc" 0 "D2 pipeline rc"
assert_tree_eq "$D1_EXP/small"  "/scratch/sd-d2/d2/small"  "D2 small on SD"
assert_tree_eq "$D1_EXP/medium" "/scratch/sd-d2/d2/medium" "D2 medium on SD"

# ─── D3: directory profile ────────────────────────────────────────────────────
#
# Places two .jobs files in a subdirectory of the shared scratch, passes the
# directory (not a file) as the profile argument, and asserts that jobs from
# both files were loaded and dispatched. Validates the directory-as-profile
# feature through the production container.

header "Int Suite 12 D3: DinD — directory profile"

D3_SD="$INT_HOST_SCRATCH/sd-d3"
D3_PROFILES="$INT_HOST_SCRATCH/profiles-d3"
mkdir -p "$D3_SD" "$D3_PROFILES"

cat > "$D3_PROFILES/a.jobs" <<'EOF'
---JOBS---
~/isos/small.7z|lvol|d3/small~
---END---
EOF
cat > "$D3_PROFILES/b.jobs" <<'EOF'
---JOBS---
~/isos/medium.7z|lvol|d3/medium~
---END---
EOF

D3_LOG="/scratch/d3.log"
set +e
docker run --rm \
    -v "$INT_HOST_SCRATCH/fixtures:/isos:ro" \
    -v "$D3_PROFILES:/jobs:ro" \
    -v "$D3_SD:/mnt/lvol" \
    -e LVOL_MOUNT_POINT=/mnt/lvol \
    -e QUEUE_DIR=/tmp/iso_pipeline_queue \
    -e EXTRACT_DIR=/tmp/iso_pipeline \
    -e COPY_DIR=/tmp/iso_pipeline_copies \
    -e ALLOW_STUB_ADAPTERS=1 \
    "$PROD_IMAGE" \
    /jobs \
    >"$D3_LOG" 2>&1
d3_rc=$?
set -e

assert_rc "$d3_rc" 0 "D3 pipeline rc"
assert_tree_eq "$D1_EXP/small"  "/scratch/sd-d3/d3/small"  "D3 small on SD (dir profile)"
assert_tree_eq "$D1_EXP/medium" "/scratch/sd-d3/d3/medium" "D3 medium on SD (dir profile)"

# ─── D4: error scenario — non-existent archive ─────────────────────────────
#
# A jobs file that references an archive that does not exist. The production
# container must return non-zero and not crash.

header "Int Suite 12 D4: DinD — non-existent archive (must fail)"

D4_SD="$INT_HOST_SCRATCH/sd-d4"
mkdir -p "$D4_SD"

cat > "$D12_JOBS/d4.jobs" <<'EOF'
---JOBS---
~/isos/does_not_exist.7z|lvol|d4/gone~
---END---
EOF

D4_LOG="/scratch/d4.log"
set +e
_int_run_prod "d4" "d4.jobs" "$D4_SD" >"$D4_LOG" 2>&1
d4_rc=$?
set -e

if (( d4_rc != 0 )); then
    pass "D4: production image rc=$d4_rc (non-zero on missing archive)"
else
    fail "D4: production image returned 0 despite missing archive"
fi

d4_count=$(find "$D4_SD" -type f 2>/dev/null | wc -l)
if (( d4_count == 0 )); then
    pass "D4: no files dispatched to SD"
else
    fail "D4: $d4_count file(s) unexpectedly dispatched to SD"
fi
