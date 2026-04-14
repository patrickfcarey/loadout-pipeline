#!/usr/bin/env bash
# test/integration/suites/01_prerequisites.sh
#
# Real-environment prerequisites. Every tool listed here is required for
# some downstream scenario; a missing entry hard-fails the whole suite
# because no amount of later fallback can rescue a missing 7z or losetup.

header "Int Test 1: container prerequisites"

_int_need_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "command present: $1"
    else
        fail "command missing: $1"
    fi
}

for cmd in 7z losetup mount umount mkfs.vfat realpath sha256sum flock \
           pgrep awk sed find stat dd ssh-keygen pure-ftpd rclone rsync; do
    _int_need_cmd "$cmd"
done

header "Int Test 1b: substrate readiness"

# Bootstrap should have exported every INT_* path and mounted every tmpfs.
for var in INT_STATE INT_EXTRACT INT_SCARCE INT_QUEUE INT_SD_VFAT \
           INT_FTP_ROOT INT_RCLONE_REMOTE INT_RCLONE_BASE INT_SSH_KEY INT_HDL_APA; do
    if [[ -n "${!var:-}" ]]; then
        pass "$var exported → ${!var}"
    else
        fail "$var not exported by bootstrap"
    fi
done

assert_dir_present "$INT_EXTRACT"  "INT_EXTRACT tmpfs"
assert_dir_present "$INT_SCARCE"   "INT_SCARCE tmpfs"
assert_dir_present "$INT_SD_VFAT"  "INT_SD_VFAT mount"

# The vfat mount must actually be vfat — otherwise we accidentally picked
# up a leftover bind-mount or tmpfs and the adapter would not exercise the
# real FAT driver at all.
if mount | grep -q "on $INT_SD_VFAT .*vfat"; then
    pass "INT_SD_VFAT is a real vfat filesystem"
else
    fail "INT_SD_VFAT is not mounted as vfat"
fi

# The scarce tmpfs must actually be small. A regression that sized it too
# large would make every ENOSPC test pass for the wrong reason.
scarce_total=$(df --output=size -B1 "$INT_SCARCE" | tail -n1 | tr -d ' ')
if (( scarce_total > 0 && scarce_total < 20 * 1024 * 1024 )); then
    pass "INT_SCARCE < 20 MB (actual $scarce_total bytes)"
else
    fail "INT_SCARCE size suspicious: $scarce_total bytes"
fi

header "Int Test 1c: fixture archives ready"

for fx in small.7z medium.7z large.7z multi.7z "parens (USA).7z" strip_target.7z; do
    if [[ -s "$INT_FIXTURES/$fx" ]]; then
        pass "fixture present: $fx"
    else
        fail "fixture missing or empty: $INT_FIXTURES/$fx"
    fi
done
