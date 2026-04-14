#!/usr/bin/env bash
# test/integration/launch.sh
#
# Host-side entrypoint for the loadout-pipeline integration suite.
#
# Builds the privileged test container from test/integration/Dockerfile,
# then runs it with the repo bind-mounted so edits take effect without a
# rebuild on the shell/fixture paths. The container's exit status is
# propagated unchanged so CI can rely on `launch.sh && echo ok`.
#
# Requirements on the host:
#   - Docker (or Podman with --privileged support)
#   - A kernel that has the `loop` and `vfat` modules available
#     (any stock Linux kernel; on WSL2 loop works, vfat requires the
#     distro-provided kernel — `uname -r` should contain `-microsoft`)
#
# Usage:
#   bash test/integration/launch.sh                 # default run
#   INT_IMAGE_TAG=mytag bash test/integration/launch.sh
#   INT_DOCKER=podman bash test/integration/launch.sh
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

echo "[launch] building image $IMAGE_TAG …"
"$DOCKER" build \
    -t "$IMAGE_TAG" \
    -f "$ROOT_DIR/test/integration/Dockerfile" \
    "$ROOT_DIR"

echo "[launch] running integration suite (privileged) …"

# --privileged   loop devices, mount, mkfs.vfat all need CAP_SYS_ADMIN.
# --rm           tear down the container on exit unconditionally.
# --init         reap zombies from pure-ftpd / sshd / watcher subshells.
# --tmpfs /tmp   isolate the test tmpfs scratch from whatever the image
#                carries; keeps the suite hermetic across reruns.
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
    "$IMAGE_TAG"
rc=$?
set -e

echo "[launch] container exited rc=$rc"
exit "$rc"
