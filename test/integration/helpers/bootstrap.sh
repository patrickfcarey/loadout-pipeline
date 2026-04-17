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
#   $INT_SD_IMG           — backing file for the vfat local volume loopback
#   $INT_SD_LOOP          — /dev/loopN allocated by losetup
#   $INT_SD_VFAT          — mountpoint for the vfat filesystem
#   $INT_FTP_ROOT         — pure-ftpd chroot
#   $INT_FTP_PORT         — port pure-ftpd listens on
#   $INT_RCLONE_REMOTE    — rclone remote name (points at a local dir)
#   $INT_RCLONE_BASE      — directory the rclone remote resolves to
#   $INT_RCLONE_CONF      — rclone config file path
#   $INT_SSH_PORT         — port sshd listens on for the rsync adapter
#   $INT_SSH_KEY          — path to the ed25519 private key used by rsync
#   $INT_HDL_STATE        — state dir the mock hdl_dump writes its TOC into
#   $INT_HDL_DEVICE       — logical device id the mock resolves (hdd0)
#   $INT_HDL_BIN          — path to the mock hdl_dump shim the suite uses
#
# Bootstrap is all-or-nothing and hard-fails on any provisioning error.
# No silent degradation — the test-21 philosophy is applied uniformly.
#
# The caller installs a single EXIT/INT/TERM trap that invokes
# bootstrap_teardown. Each provisioning step appends its cleanup command
# to $INT_TEARDOWN_CMDS so teardown runs in reverse order deterministically.

# Fail early if sourced outside the integration container. /etc sentinel
# is created by the Dockerfile. This guard prevents a careless host-side
# run from losetup-ing the developer's real local volume.
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

# ── substrate: $INT_EXTRACT — 1.5 GB tmpfs ───────────────────────────────────
#
# Used as EXTRACT_DIR / COPY_DIR for the happy-path end-to-end scenarios.
# Sized to accommodate a full PS2 game ISO (~650 MB–1.5 GB decompressed)
# so Test 21 and similar real-archive scenarios can run without redirecting
# to the container rootfs. Tests that DELIBERATELY want to exhaust space
# use $INT_SCARCE instead.

_int_setup_extract() {
    export INT_EXTRACT="$INT_STATE/extract"
    mkdir -p "$INT_EXTRACT"
    mount -t tmpfs -o size=1536M tmpfs "$INT_EXTRACT" \
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

# ── substrate: $INT_SD_VFAT — loop-mounted vfat local volume ─────────────────────
#
# Reproduces a real PS2 SD-card target: 64 MB FAT32 filesystem on a
# loopback file. The lvol adapter will copy files into this mount just
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
# Exercises the real FTP adapter via pure-ftpd on 127.0.0.1:2121 with a
# dedicated authenticated user. Used by integration suite 07 (Tests 16, 16b, 16c).
#
# Anonymous logins are deliberately NOT used: pure-ftpd hardcodes an
# anonymous-no-overwrite restriction that triggers "550 Anonymous users may
# not overwrite existing files" even on first-time uploads when lftp's
# `mirror -R` uses atomic upload or issues a trailing SITE CHMOD. A real
# system user bypasses that gate entirely and lets us exercise re-run /
# precheck-skip scenarios (Test 16b) honestly.

_int_setup_ftp() {
    export INT_FTP_ROOT="$INT_STATE/ftp"
    export INT_FTP_PORT=2121
    export INT_FTP_USER="ftptest"
    export INT_FTP_PASS="loadout-ftp-test"

    mkdir -p "$INT_FTP_ROOT"

    # Real system user for pure-ftpd's unix auth (-l unix). Home points at
    # the FTP root so -A (chroot-everyone) jails them there.
    if ! id "$INT_FTP_USER" >/dev/null 2>&1; then
        useradd -d "$INT_FTP_ROOT" -s /bin/bash -M "$INT_FTP_USER" \
            || bootstrap_fail "useradd $INT_FTP_USER failed"
    fi
    echo "$INT_FTP_USER:$INT_FTP_PASS" | chpasswd \
        || bootstrap_fail "chpasswd for $INT_FTP_USER failed"

    # The user needs to own its chroot root so uploads can write there.
    chown -R "$INT_FTP_USER:$INT_FTP_USER" "$INT_FTP_ROOT"
    chmod 755 "$INT_FTP_ROOT"

    # pure-ftpd's unix auth refuses users whose login shell isn't listed in
    # /etc/shells. Debian-slim ships an empty /etc/shells, so add bash.
    if ! grep -qxF "/bin/bash" /etc/shells 2>/dev/null; then
        echo "/bin/bash" >> /etc/shells
    fi

    # Run pure-ftpd in foreground mode, backgrounded via the shell (&).
    # Avoiding -B (daemonize) because some Debian builds exit non-zero
    # silently when attempting to fork inside a container. Shell-level
    # backgrounding gives us a concrete PID for teardown and avoids the
    # double-fork that makes error detection unreliable.
    #
    #   -l unix      authenticate against /etc/passwd + /etc/shadow directly
    #                (no PAM config required inside the container)
    #   -E           only authenticated logins (disable anonymous entirely)
    #   -A           force chroot() for every user into their home dir
    #   -j           auto-create user home dir if missing
    #   -M           allow authenticated users to create directories
    #   -S           bind address,port (no space between address and port)
    local ftpd_log="$INT_STATE/pure-ftpd.log"
    pure-ftpd \
        -l unix \
        -E \
        -A \
        -j \
        -M \
        -S "127.0.0.1,$INT_FTP_PORT" \
        >"$ftpd_log" 2>&1 &
    local INT_FTP_PID=$!

    # Poll for up to 3 seconds until the port is listening. Try ss first
    # (needs iproute2); fall back to bash /dev/tcp probe if ss is absent.
    local i _ftp_up=0
    for i in $(seq 1 30); do
        if command -v ss >/dev/null 2>&1; then
            ss -tlnp 2>/dev/null | grep -q ":$INT_FTP_PORT " && { _ftp_up=1; break; }
        else
            (echo >/dev/tcp/127.0.0.1/$INT_FTP_PORT) 2>/dev/null && { _ftp_up=1; break; }
        fi
        sleep 0.1
    done

    if (( ! _ftp_up )); then
        echo "[bootstrap] pure-ftpd log:" >&2
        cat "$ftpd_log" >&2 2>/dev/null || true
        echo "[bootstrap] pure-ftpd process state:" >&2
        kill -0 "$INT_FTP_PID" 2>&1 >&2 || echo "[bootstrap]   PID $INT_FTP_PID is dead" >&2
        kill "$INT_FTP_PID" 2>/dev/null || true
        bootstrap_fail "pure-ftpd failed to start on port $INT_FTP_PORT (pid $INT_FTP_PID)"
    fi

    _int_push_teardown "kill '$INT_FTP_PID' 2>/dev/null || true"
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
    local _i
    for _i in $(seq 1 30); do
        ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "$INT_SSH_KEY" -p "$INT_SSH_PORT" 127.0.0.1 true 2>/dev/null && break
        sleep 0.1
    done
}

# ── substrate: hdl_dump mock shim ───────────────────────────────────────────
#
# A real end-to-end hdl_dump inject requires a PS2 HDD pre-formatted with an
# APA partition table and seeded with a signed MBR KELF (a cryptographically-
# signed PS2 executable that we cannot ship or synthesize in CI). Accordingly,
# the integration bootstrap installs a lightweight shim at /usr/local/bin/hdl_dump
# that implements just enough of the real CLI for our tests:
#
#   hdl_dump toc <device>:
#     Reads "$HOME/.hdl_dump.conf" to resolve <device> → host path, then prints
#     the TOC (stored as plain text in a state-dir file keyed by host path).
#     Exits 0 even if no titles are present (empty output).
#
#   hdl_dump inject_cd <device>: <title> <iso_path>
#   hdl_dump inject_dvd <device>: <title> <iso_path>
#     Resolves <device> via "$HOME/.hdl_dump.conf", validates <iso_path> exists,
#     and appends <title> to the TOC state file. Idempotent — injecting the same
#     title twice is a no-op.
#
# This mirrors the real hdl_dump's HOME/.hdl_dump.conf contract exactly (see
# ps2homebrew/hdl-dump common.c:get_config_file). The shim is installed during
# bootstrap (rather than baked into the Dockerfile) so a developer iterating on
# hdl_dump test behaviour can tweak the shim without a container rebuild.

_int_setup_hdl() {
    export INT_HDL_STATE="$INT_STATE/hdl_state"
    export INT_HDL_DEVICE="hdd0"
    export INT_HDL_BIN="/usr/local/bin/hdl_dump"
    mkdir -p "$INT_HDL_STATE" || bootstrap_fail "mkdir $INT_HDL_STATE"
    _int_push_teardown "rm -rf '$INT_HDL_STATE'"
    _int_push_teardown "rm -f '$INT_HDL_BIN'"

    cat > "$INT_HDL_BIN" <<'MOCK_HDL_DUMP'
#!/usr/bin/env bash
# Integration-test mock for ps2homebrew/hdl-dump.
# State lives under $INT_HDL_STATE, keyed by the host path resolved from
# "$HOME/.hdl_dump.conf" — exactly the contract the real upstream binary uses.
set -euo pipefail

die() { echo "hdl_dump(mock): $*" >&2; exit 1; }

_resolve() {
    local dev_arg="$1" dev="${1%:}" cfg="$HOME/.hdl_dump.conf"
    [[ "$dev_arg" == *: ]] || die "device arg must end with ':' (got '$dev_arg')"
    [[ -f "$cfg" ]] || die "config not found: $cfg"
    local line host_path
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        # <device> <host_path> <mode>
        read -r cfg_dev cfg_path _ <<< "$line" || true
        if [[ "$cfg_dev" == "$dev" ]]; then
            host_path="$cfg_path"
            break
        fi
    done < "$cfg"
    [[ -n "${host_path:-}" ]] || die "no mapping for '$dev' in $cfg"
    printf '%s\n' "$host_path"
}

_state_file() {
    local host_path="$1"
    local state_dir="${INT_HDL_STATE:?INT_HDL_STATE not exported to mock}"
    # Flatten the host path into a filename-safe key.
    local key
    key="$(printf '%s' "$host_path" | tr '/' '_')"
    printf '%s/%s.toc\n' "$state_dir" "$key"
}

cmd="${1:-}"
case "$cmd" in
    toc)
        [[ $# -eq 2 ]] || die "usage: hdl_dump toc <device>:"
        host_path="$(_resolve "$2")"
        state_file="$(_state_file "$host_path")"
        [[ -f "$state_file" ]] && cat "$state_file" || true
        ;;
    inject_cd|inject_dvd)
        [[ $# -eq 4 ]] || die "usage: hdl_dump $cmd <device>: <title> <iso>"
        host_path="$(_resolve "$2")"
        title="$3"
        iso="$4"
        [[ -f "$iso" ]] || die "iso not found: $iso"
        state_file="$(_state_file "$host_path")"
        if ! [[ -f "$state_file" ]] || ! grep -qxF "$title" "$state_file"; then
            printf '%s\n' "$title" >> "$state_file"
        fi
        echo "hdl_dump(mock): $cmd injected \"$title\" from $iso into $host_path"
        ;;
    "")
        die "no subcommand"
        ;;
    *)
        die "unsupported subcommand '$cmd' (mock supports: toc, inject_cd, inject_dvd)"
        ;;
esac
MOCK_HDL_DUMP
    chmod 0755 "$INT_HDL_BIN" || bootstrap_fail "chmod $INT_HDL_BIN"
}

# ── top-level entrypoint ─────────────────────────────────────────────────────

bootstrap_all() {
    echo "[bootstrap] provisioning substrates under $INT_STATE …"
    _int_setup_state
    _int_setup_queue
    _int_setup_extract
    _int_setup_scarce
    _int_setup_sd_vfat
    _int_setup_rclone
    _int_setup_ssh
    _int_setup_hdl
    _int_setup_ftp
    echo "[bootstrap] done."
    echo "[bootstrap]   INT_STATE        = $INT_STATE"
    echo "[bootstrap]   INT_EXTRACT      = $INT_EXTRACT (1536M tmpfs)"
    echo "[bootstrap]   INT_SCARCE       = $INT_SCARCE (6M tmpfs)"
    echo "[bootstrap]   INT_QUEUE        = $INT_QUEUE"
    echo "[bootstrap]   INT_SD_VFAT      = $INT_SD_VFAT (loop $INT_SD_LOOP on $INT_SD_IMG)"
    echo "[bootstrap]   INT_RCLONE_REMOTE= $INT_RCLONE_REMOTE: → $INT_RCLONE_BASE"
    echo "[bootstrap]   INT_SSH_PORT     = $INT_SSH_PORT (key $INT_SSH_KEY)"
    echo "[bootstrap]   INT_HDL_BIN      = $INT_HDL_BIN (mock, device ${INT_HDL_DEVICE}:, state $INT_HDL_STATE)"
    echo "[bootstrap]   INT_FTP_PORT     = $INT_FTP_PORT (root $INT_FTP_ROOT, user $INT_FTP_USER)"
}
