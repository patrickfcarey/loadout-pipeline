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
#   - Docker (or Podman) with ROOTFUL access. The suite uses --privileged
#     for loop devices, mount, and mkfs.vfat. Rootless podman / rootless
#     Docker cannot grant host-level CAP_SYS_ADMIN, which the loop-device
#     allocator (LOOP_CTL_GET_FREE ioctl on /dev/loop-control) requires.
#     The script detects rootless runtimes early and exits with a clear
#     error rather than failing mid-bootstrap after a 2–3 minute build.
#   - A kernel that has the `loop` and `vfat` modules available
#     (any stock Linux kernel; on WSL2 loop works, vfat requires the
#     distro-provided kernel — `uname -r` should contain `-microsoft`)
#
# Usage:
#   sudo bash test/integration/launch.sh                   # typical local run
#   bash test/integration/launch.sh                        # works if your $DOCKER is rootful
#   INT_IMAGE_TAG=mytag sudo -E bash test/integration/launch.sh
#   INT_DOCKER=podman sudo -E bash test/integration/launch.sh
#   INT_PROD_IMAGE_TAG=myrepo/loadout:dev sudo -E bash test/integration/launch.sh
#
# The suite is intentionally NOT silent-skippable on the host — if Docker
# is missing, or the runtime is rootless, we fail loudly. The test-21
# philosophy: no silent success.

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

# ── early rootless-runtime guard ─────────────────────────────────────────────
# The integration suite needs host-level CAP_SYS_ADMIN to allocate loop devices
# via /dev/loop-control. Rootless podman cannot grant this even with
# --privileged, because the LOOP_CTL_GET_FREE ioctl checks the HOST capability
# set, not the user-namespace one. Without this check the suite would build
# two Docker images (2–3 minutes) and then fail in substrate bootstrap with a
# confusing "losetup: Permission denied" — fail fast instead.
#
# Detection: only complain when EUID != 0 (root-via-sudo always works), and
# only when the runtime's own `info` reports rootless. This matches both
# `rootless: true` (podman info) and `name=rootless` (docker info).
if [[ $EUID -ne 0 ]]; then
    runtime_info="$("$DOCKER" info 2>&1 || true)"
    if echo "$runtime_info" | grep -qiE 'rootless: *true|name=rootless'; then
        cat >&2 <<EOF
[launch] ERROR: detected rootless container runtime ($DOCKER).
[launch]
[launch] The integration suite uses --privileged for loop devices, mount,
[launch] and mkfs.vfat. Rootless podman / rootless Docker cannot grant the
[launch] host-level CAP_SYS_ADMIN that /dev/loop-control allocation requires,
[launch] so the substrate bootstrap will fail mid-run with:
[launch]
[launch]   losetup: cannot find an unused loop device: Permission denied
[launch]
[launch] Fix: rerun as root.
[launch]
[launch]   sudo bash test/integration/launch.sh
[launch]
[launch] (Or install rootful Docker and set INT_DOCKER=/path/to/rootful-docker.)
EOF
        exit 2
    fi
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

# ── detect Docker/Podman socket path ─────────────────────────────────────────
# Docker uses /var/run/docker.sock. Podman uses a user or system socket at a
# different path. Detect whichever exists so suite 12 (DinD) can bind-mount it
# into the integration container. If no socket is found, suite 12 will skip
# gracefully via its internal guard rather than crashing the whole run.
if [[ -S "/var/run/docker.sock" ]]; then
    DOCKER_SOCK="/var/run/docker.sock"
elif [[ -S "/run/user/$(id -u)/podman/podman.sock" ]]; then
    DOCKER_SOCK="/run/user/$(id -u)/podman/podman.sock"
elif [[ -S "/run/podman/podman.sock" ]]; then
    DOCKER_SOCK="/run/podman/podman.sock"
else
    DOCKER_SOCK=""
    echo "[launch] WARNING: no Docker/Podman socket found; suite 12 (DinD) will skip"
    echo "[launch]          To enable: systemctl --user enable --now podman.socket"
fi

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
SOCK_ARGS=()
if [[ -n "$DOCKER_SOCK" ]]; then
    SOCK_ARGS=(-v "$DOCKER_SOCK:/var/run/docker.sock")
fi

set +e
"$DOCKER" run \
    --rm \
    --privileged \
    --init \
    --tmpfs /tmp \
    "${SOCK_ARGS[@]}" \
    -v "$INT_HOST_SCRATCH:/scratch" \
    -e PROD_IMAGE="$PROD_IMAGE_TAG" \
    -e INT_HOST_SCRATCH="$INT_HOST_SCRATCH" \
    "$IMAGE_TAG"
rc=$?
set -e

echo "[launch] container exited rc=$rc"
exit "$rc"
