# test/integration/Dockerfile
#
# Privileged test container for the loadout-pipeline integration suite.
# The suite provisions real loopback block devices, real vfat mounts, real
# sized tmpfs, real pure-ftpd, sshd and rclone substrates — so the image
# must run with --privileged and a kernel that exposes the loop and vfat
# modules on the host.
#
# Not intended for any runtime use. Do not publish.

FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling:
#   bash, coreutils, findutils, procps — script runtime
#   p7zip-full                         — archive extraction
#   dosfstools                         — mkfs.vfat for the SD loopback
#   util-linux, mount                  — losetup, mount, stat, flock, unshare
#   rsync                              — sdcard adapter + real rsync adapter
#   openssh-server, openssh-client     — rsync-over-ssh to localhost
#   pure-ftpd                          — ftp adapter loopback
#   rclone                             — rclone adapter loopback (type=local)
#   jq                                 — occasional JSON probing in helpers
#   ca-certificates                    — rclone TLS, apt-get sanity
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        coreutils \
        findutils \
        procps \
        p7zip-full \
        dosfstools \
        util-linux \
        mount \
        rsync \
        openssh-server \
        openssh-client \
        pure-ftpd \
        rclone \
        jq \
        ca-certificates \
        docker.io \
 && rm -rf /var/lib/apt/lists/*

# sshd needs /run/sshd to exist before it can start.
RUN mkdir -p /run/sshd

# Copy the repo into a well-known path. The integration runner expects to
# find itself at /opt/loadout-pipeline/test/integration/run_integration.sh.
WORKDIR /opt/loadout-pipeline
COPY . /opt/loadout-pipeline

# Strip Windows CRLF line endings from all shell scripts. Windows hosts
# (and Windows-backed git checkouts on WSL2) may produce \r\n files even
# when .gitattributes says eol=lf. bash rejects \r in shebang lines and
# silently misnames functions (e.g. `neg_check\r` vs `neg_check`), so we
# normalize unconditionally on every image build.
RUN find /opt/loadout-pipeline -type f -name '*.sh' -exec sed -i 's/\r//' {} + \
 && find /opt/loadout-pipeline -type f -name '*.sh' -exec chmod +x {} +

# Sentinel file so helpers can detect whether they're running inside the
# container or on the host and fail loudly if misused.
RUN touch /etc/loadout-integration-container

ENV INT_IN_CONTAINER=1

ENTRYPOINT ["/usr/bin/env", "bash", "/opt/loadout-pipeline/test/integration/run_integration.sh"]
