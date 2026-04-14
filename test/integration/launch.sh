#!/usr/bin/env bash
# test/integration/launch.sh
#
# Host-side entrypoint for the loadout-pipeline integration suite.
#
# Build order:
#   1. Production image  (Dockerfile)                    → loadout-pipeline:latest
#   2. Integration image (test/integration/Dockerfile)   → loadout-pipeline-integration:local
#
# The integration container runs with:
#   --privileged          loop devices, mount, mkfs.vfat (existing substrate tests)
#   --docker-socket       /var/run/docker.sock bind-mounted for DinD suite 12
#   --scratch             $INT_HOST_SCRATCH bind-mounted at /scratch so suite 12
#                         can share directories with the production container it spawns
#
# Suite 12 (DinD) invokes the production container from inside the integration
# container via the host Docker socket, passing host-side paths from
# $INT_HOST_SCRATCH as volumes. The production container is a true black box —
# it receives mounts and env vars exactly as a real user would provide.
#
# Requirements on the host:
#   - Docker (or Podman with --privileged support)
#   - A kernel that has the `loop` and `vfat` modules available
#     (any stock Linux kernel; on WSL2 loop works, vfat requires the
#     distro-provided kernel — `uname -r` should contain `-microsoft`)
#
# Usage:
#   bash test/integration/launch.sh                        # default run
#   INT_IMAGE_TAG=mytag bash test/integration/launch.sh
#   INT_DOCKER=podman bash test/integration/launch.sh
#   INT_PROD_IMAGE_TAG=myrepo/loadout:dev bash test/integration/launch.sh
#
# The suite is intentionally NOT silent-skippable on the host — if Docker
# is missing we fail loudly. The test-21 philosophy: no silent success.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${INT_IMAGE_TAG:-loadout-pipeline-integration:local}"
if [[ -n "${INT_DOCKER:-}" ]]; then
    DOCKER="$INT_DOCKER"
elif command -v docker >/dev/null 2>&1; then
    DOCKER="docker"
elif command -v podman >/dev/null 2>&1; then
    DOCKER="podman"
else
    DOCKER="docker"   # fall through to the existing "not found" error below
fi

if ! command -v "$DOCKER" >/dev/null 2>&1; then
    echo "[launch] ERROR: '$DOCKER' not found on PATH." >&2
    echo "[launch]        Install Docker or set INT_DOCKER=podman." >&2
    exit 2
fi

PROD_IMAGE_TAG="${INT_PROD_IMAGE_TAG:-loadout-pipeline:latest}"

# ── 1. build production image ─────────────────────────────────────────────────
echo "[launch] building production image $PROD_IMAGE_TAG …"
"$DOCKER" build \
    -t "$PROD_IMAGE_TAG" \
    -f "$ROOT_DIR/Dockerfile" \
    "$ROOT_DIR"

# ── 2. build integration harness image ───────────────────────────────────────
echo "[launch] building integration image $IMAGE_TAG …"
"$DOCKER" build \
    -t "$IMAGE_TAG" \
    -f "$ROOT_DIR/test/integration/Dockerfile" \
    "$ROOT_DIR"

# ── 3. create host scratch dir for DinD suite 12 ─────────────────────────────
# Suite 12 spawns the production container via the Docker socket. Docker resolves
# volume source paths on the HOST, not inside the outer container. This scratch
# dir is created on the host and bind-mounted into the outer container at /scratch
# so the outer container can stage fixtures/jobs/destinations that are also
# reachable by the inner (production) container as HOST-side volume paths.
INT_HOST_SCRATCH="$(mktemp -d)"
# Cleanup: inner container writes as root; use docker to remove those files.
trap '
    "$DOCKER" run --rm \
        -v "'"$INT_HOST_SCRATCH"':/s" \
        debian:stable-slim \
        rm -rf /s/fixtures /s/jobs /s/sd /s/profiles 2>/dev/null || true
    rm -rf "'"$INT_HOST_SCRATCH"'"
' EXIT

echo "[launch] running integration suite (privileged) …"

# --privileged   loop devices, mount, mkfs.vfat all need CAP_SYS_ADMIN.
# --rm           tear down the container on exit unconditionally.
# --init         reap zombies from pure-ftpd / sshd / watcher subshells.
# --tmpfs /tmp   isolate the test tmpfs scratch from whatever the image
#                carries; keeps the suite hermetic across reruns.
# --docker-sock  DinD: suite 12 invokes the production container via host daemon.
# --scratch      /scratch bind-mount shares the host scratch dir with suite 12.
# --env vars     PROD_IMAGE and INT_HOST_SCRATCH forwarded to suite 12.
#
# We deliberately do NOT bind-mount the repo here: the COPY in the
# Dockerfile already baked it in. Bind-mounting makes the suite sensitive
# to host FS quirks (CRLF, permissions) which we explicitly want to
# insulate against.
set +e
"$DOCKER" run \
    --rm \
    --privileged \
    --init \
    --tmpfs /tmp \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$INT_HOST_SCRATCH:/scratch" \
    -e PROD_IMAGE="$PROD_IMAGE_TAG" \
    -e INT_HOST_SCRATCH="$INT_HOST_SCRATCH" \
    "$IMAGE_TAG"
rc=$?
set -e

echo "[launch] container exited rc=$rc"
exit "$rc"
