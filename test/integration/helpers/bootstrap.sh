#!/usr/bin/env bash
# test/integration/helpers/bootstrap.sh
#
# Provisions the real substrate the integration suite runs against. All
# paths and device refs are written into exported INT_* variables so
# suites can reference them without hard-coding /var/lib/... anywhere.
#
# Substrates provisioned (see docs in the plan for the full rationale):
#
#   $INT_STATE            — root of everything this bootstrap creates
#   $INT_EXTRACT          — 256 MB tmpfs, acts as EXTRACT_DIR/COPY_DIR
#   $INT_SCARCE           — 6 MB tmpfs, forces real ENOSPC for scarcity tests
#   $INT_QUEUE            — queue dir on the ext4 container FS (flock needs real FS)
#   $INT_SD_IMG           — backing file for the vfat SD card loopback
#   $INT_SD_LOOP          — /dev/loopN allocated by losetup
#   $INT_SD_VFAT          — mountpoint for the vfat filesystem
#   $INT_FTP_ROOT         — pure-ftpd chroot
#   $INT_FTP_PORT         — port pure-ftpd listens on
#   $INT_RCLONE_REMOTE    — rclone remote name (points at a local dir)
#   $INT_RCLONE_BASE      — directory the rclone remote resolves to
#   $INT_RCLONE_CONF      — rclone config file path
#   $INT_SSH_PORT         — port sshd listens on for the rsync adapter
#   $INT_SSH_KEY          — path to the ed25519 private key used by rsync
#   $INT_HDL_APA          — loopback file for hdl_dump APA-formatted target
#
# Bootstrap is all-or-nothing and hard-fails on any provisioning error.
# No silent degradation — the test-21 philosophy is applied uniformly.
#
# The caller installs a single EXIT/INT/TERM trap that invokes
# bootstrap_teardown. Each provisioning step appends its cleanup command
# to $INT_TEARDOWN_CMDS so teardown runs in reverse order deterministically.

# Fail early if sourced outside the integration container. /etc sentinel
# is created by the Dockerfile. This guard prevents a careless host-side
# run from losetup-ing the developer's real SD card.
if [[ ! -f /etc/loadout-integration-container ]]; then
    echo "[bootstrap] ERROR: not running in the integration container." >&2
    echo "[bootstrap]        Run via test/integration/launch.sh instead." >&2
    exit 2
fi

# Per-run state root. Re-used across all substrates.
export INT_STATE="${INT_STATE:-/var/lib/loadout-int}"

# Teardown command stack (LIFO). Each step appends; bootstrap_teardown pops.
declare -a INT_TEARDOWN_CMDS=()

_int_push_teardown() { INT_TEARDOWN_CMDS+=("$*"); }

bootstrap_teardown() {
    local i cmd
    # Iterate in reverse so mounts come down before the backing files they
    # were mounted from.
    for (( i=${#INT_TEARDOWN_CMDS[@]}-1; i>=0; i-- )); do
        cmd="${INT_TEARDOWN_CMDS[i]}"
        # Never abort teardown — best-effort only, always continue.
        eval "$cmd" 2>/dev/null || true
    done
}

bootstrap_fail() {
    echo "[bootstrap] FATAL: $*" >&2
    exit 2
}

# ── substrate: state root ────────────────────────────────────────────────────

_int_setup_state() {
    rm -rf "$INT_STATE"
    mkdir -p "$INT_STATE"
    _int_push_teardown "rm -rf '$INT_STATE'"
}

# ── substrate: $INT_EXTRACT — 256 MB tmpfs ───────────────────────────────────
#
# Used as EXTRACT_DIR / COPY_DIR for the happy-path end-to-end scenarios.
# Sized generously so tests do not accidentally fail on legitimate large
# archives. Tests that DELIBERATELY want to exhaust space use $INT_SCARCE.

_int_setup_extract() {
    export INT_EXTRACT="$INT_STATE/extract"
    mkdir -p "$INT_EXTRACT"
    mount -t tmpfs -o size=256M tmpfs "$INT_EXTRACT" \
        || bootstrap_fail "mount tmpfs on $INT_EXTRACT"
    _int_push_teardown "umount '$INT_EXTRACT'"
}

# ── substrate: $INT_SCARCE — 6 MB tmpfs (deliberate ENOSPC) ─────────────────

_int_setup_scarce() {
    export INT_SCARCE="$INT_STATE/scarce"
    mkdir -p "$INT_SCARCE"
    mount -t tmpfs -o size=6M tmpfs "$INT_SCARCE" \
        || bootstrap_fail "mount tmpfs on $INT_SCARCE"
    _int_push_teardown "umount '$INT_SCARCE'"
}

# ── substrate: $INT_QUEUE ────────────────────────────────────────────────────
#
# The pipeline uses flock on files in QUEUE_DIR. tmpfs supports flock, but
# we put the queue on the regular container rootfs so it survives across
# scenarios that would otherwise want to unmount and remount $INT_EXTRACT.

_int_setup_queue() {
    export INT_QUEUE="$INT_STATE/queue"
    mkdir -p "$INT_QUEUE"
    _int_push_teardown "rm -rf '$INT_QUEUE'"
}

# ── substrate: $INT_SD_VFAT — loop-mounted vfat SD card ─────────────────────
#
# Reproduces a real PS2 SD-card target: 64 MB FAT32 filesystem on a
# loopback file. The sdcard adapter will copy files into this mount just
# like it would onto a real card. Loopback via losetup keeps us off real
# hardware while still exercising the kernel's vfat driver end-to-end.

_int_setup_sd_vfat() {
    export INT_SD_IMG="$INT_STATE/sd.img"
    export INT_SD_VFAT="$INT_STATE/sd"
    mkdir -p "$INT_SD_VFAT"
    truncate -s 64M "$INT_SD_IMG" || bootstrap_fail "truncate $INT_SD_IMG"
    mkfs.vfat -F 32 "$INT_SD_IMG" >/dev/null 2>&1 \
        || bootstrap_fail "mkfs.vfat on $INT_SD_IMG"
    INT_SD_LOOP="$(losetup -f --show "$INT_SD_IMG")" \
        || bootstrap_fail "losetup on $INT_SD_IMG"
    export INT_SD_LOOP
    _int_push_teardown "losetup -d '$INT_SD_LOOP'"
    mount -t vfat "$INT_SD_LOOP" "$INT_SD_VFAT" \
        || bootstrap_fail "mount vfat $INT_SD_LOOP on $INT_SD_VFAT"
    _int_push_teardown "umount '$INT_SD_VFAT'"
}

# ── substrate: pure-ftpd loopback ────────────────────────────────────────────
#
# Provisioned but NOT exercised by the current suites (the ftp adapter is
# a stub). Bootstrap still sets it up so when the real adapter lands the
# only change needed is in the corresponding suite file.

_int_setup_ftp() {
    export INT_FTP_ROOT="$INT_STATE/ftp"
    export INT_FTP_PORT=2121
    mkdir -p "$INT_FTP_ROOT"
    chmod 777 "$INT_FTP_ROOT"
    # pure-ftpd --daemonize detaches to the background. Teardown uses pkill
    # on the bind address pattern to stop it. Anonymous mode lets tests
    # write without managing passwd files.
    pure-ftpd \
        --anonymousonly \
        --anonymouscancreatedirs \
        --anonymouscantupload=no \
        --daemonize \
        --bind=127.0.0.1,"$INT_FTP_PORT" \
        --chrooteveryone \
        --noanonymous=no \
        -e \
        -- "$INT_FTP_ROOT" >/dev/null 2>&1 \
        || bootstrap_fail "pure-ftpd failed to start on port $INT_FTP_PORT"
    _int_push_teardown "pkill -f 'pure-ftpd.*--bind=127.0.0.1,$INT_FTP_PORT' || true"
}

# ── substrate: rclone local remote ───────────────────────────────────────────

_int_setup_rclone() {
    export INT_RCLONE_BASE="$INT_STATE/rclone-base"
    export INT_RCLONE_CONF="$INT_STATE/rclone.conf"
    export INT_RCLONE_REMOTE="int_local"
    mkdir -p "$INT_RCLONE_BASE"
    cat > "$INT_RCLONE_CONF" <<EOF
[$INT_RCLONE_REMOTE]
type = local
EOF
    _int_push_teardown "rm -f '$INT_RCLONE_CONF'; rm -rf '$INT_RCLONE_BASE'"
}

# ── substrate: sshd for rsync adapter ────────────────────────────────────────

_int_setup_ssh() {
    export INT_SSH_PORT=2222
    export INT_SSH_KEY="$INT_STATE/ssh_int_ed25519"
    ssh-keygen -q -t ed25519 -N '' -f "$INT_SSH_KEY" \
        || bootstrap_fail "ssh-keygen failed"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    cat "${INT_SSH_KEY}.pub" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    # Write a minimal sshd config on the ephemeral port.
    local cfg="$INT_STATE/sshd_config"
    cat > "$cfg" <<EOF
Port $INT_SSH_PORT
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
UsePAM no
Subsystem sftp /usr/lib/openssh/sftp-server
PidFile $INT_STATE/sshd.pid
EOF
    /usr/sbin/sshd -f "$cfg" \
        || bootstrap_fail "sshd failed to start on port $INT_SSH_PORT"
    _int_push_teardown "[[ -f '$INT_STATE/sshd.pid' ]] && kill \$(cat '$INT_STATE/sshd.pid')"
}

# ── substrate: hdl_dump APA loopback target ─────────────────────────────────
#
# Provisioned but NOT exercised (hdl_dump adapter is a stub). A 16 MB
# loopback file is enough to accept the APA header the real adapter would
# eventually write. We do not pre-format with hdl_dump because the image
# may not carry it — the corresponding suite scenario hard-fails anyway.

_int_setup_hdl() {
    export INT_HDL_APA="$INT_STATE/hdl_apa.img"
    truncate -s 16M "$INT_HDL_APA" || bootstrap_fail "truncate $INT_HDL_APA"
    _int_push_teardown "rm -f '$INT_HDL_APA'"
}

# ── top-level entrypoint ─────────────────────────────────────────────────────

bootstrap_all() {
    echo "[bootstrap] provisioning substrates under $INT_STATE …"
    _int_setup_state
    _int_setup_queue
    _int_setup_extract
    _int_setup_scarce
    _int_setup_sd_vfat
    _int_setup_ftp
    _int_setup_rclone
    _int_setup_ssh
    _int_setup_hdl
    echo "[bootstrap] done."
    echo "[bootstrap]   INT_STATE        = $INT_STATE"
    echo "[bootstrap]   INT_EXTRACT      = $INT_EXTRACT (256M tmpfs)"
    echo "[bootstrap]   INT_SCARCE       = $INT_SCARCE (6M tmpfs)"
    echo "[bootstrap]   INT_QUEUE        = $INT_QUEUE"
    echo "[bootstrap]   INT_SD_VFAT      = $INT_SD_VFAT (loop $INT_SD_LOOP on $INT_SD_IMG)"
    echo "[bootstrap]   INT_FTP_ROOT     = $INT_FTP_ROOT (pure-ftpd :$INT_FTP_PORT)"
    echo "[bootstrap]   INT_RCLONE_REMOTE= $INT_RCLONE_REMOTE: → $INT_RCLONE_BASE"
    echo "[bootstrap]   INT_SSH_PORT     = $INT_SSH_PORT (key $INT_SSH_KEY)"
    echo "[bootstrap]   INT_HDL_APA      = $INT_HDL_APA"
}
