# Dockerfile
#
# Production image for loadout-pipeline.
#
# Packages the pipeline scripts and all required runtime binaries. Archives,
# job profiles, and adapter credentials are supplied entirely at runtime via
# bind-mounts and environment variables — nothing user-specific is baked in.
#
# Build:
#   docker build -t loadout-pipeline .
#
# Run (local volume adapter example):
#   docker run --rm \
#     -v /path/to/isos:/isos:ro \
#     -v /mnt/lvol:/mnt/lvol \
#     -v /path/to/profiles:/jobs:ro \
#     -e LVOL_MOUNT_POINT=/mnt/lvol \
#     loadout-pipeline /jobs/my_games.jobs
#
# All environment variables documented in .env.example are accepted via -e or
# --env-file. The priority order (inline -e > .env > defaults) is preserved.
# Bind-mount your .env at /opt/loadout-pipeline/.env for credential safety:
#   -v /path/to/.env:/opt/loadout-pipeline/.env:ro

FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies:
#   bash, coreutils, findutils, procps  — script runtime + stat/realpath/install
#   p7zip-full                          — 7z x / 7z l (extraction + size probe)
#   util-linux                          — flock (atomic ledger), losetup
#   rsync                               — lvol adapter + rsync adapter
#   rclone                              — rclone adapter
#   openssh-client                      — rsync-over-SSH (rsync adapter)
#   ca-certificates                     — rclone TLS handshakes
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        coreutils \
        findutils \
        procps \
        p7zip-full \
        util-linux \
        rsync \
        rclone \
        openssh-client \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/loadout-pipeline
COPY . /opt/loadout-pipeline

# Ensure all scripts are executable regardless of host filesystem permissions.
RUN find /opt/loadout-pipeline -type f -name '*.sh' -exec chmod +x {} +

# Conventional mount points that match the default values in lib/config.sh.
# Declaring them documents intent; actual mounts are supplied at runtime.
#
#   /isos          — read-only source archives (iso_path in .jobs files)
#   /jobs          — read-only job profiles (.jobs files)
#   /mnt/lvol    — local volume mount point (LVOL_MOUNT_POINT default)
#   /tmp           — scratch space for EXTRACT_DIR, COPY_DIR, QUEUE_DIR
VOLUME ["/isos", "/jobs", "/mnt/lvol"]

# The pipeline entry point. All documented invocation patterns are preserved:
#
#   No argument  — loads examples/example.jobs (built-in default)
#   Positional   — docker run loadout-pipeline /jobs/my.jobs
#   Env vars     — docker run -e MAX_UNZIP=4 -e LVOL_MOUNT_POINT=/mnt/sd …
#   .env file    — bind-mount at /opt/loadout-pipeline/.env
ENTRYPOINT ["/usr/bin/env", "bash", "/opt/loadout-pipeline/bin/loadout-pipeline.sh"]
