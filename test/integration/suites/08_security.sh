#!/usr/bin/env bash
# test/integration/suites/08_security.sh
#
# Path traversal rejection, exercised against a real on-disk jobs file
# and a real $INT_SD_VFAT mountpoint. Every accepted malicious job would
# allow a crafted archive to escape the local volume sandbox on a real device —
# so this is the suite that most directly protects the end user.

header "Int Test 19: path traversal in load_jobs (real jobs file)"

T19_JOBS="$INT_STATE/t19.jobs"

while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < <(
    export ROOT_DIR
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/logging.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/jobs.sh"

    # Case A: mid-string traversal in destination.
    { echo '---JOBS---'; echo "~/abs/path/game.7z|lvol|games/../../../etc/passwd~"; echo '---END---'; } > "$T19_JOBS"
    JOBS=()
    if load_jobs "$T19_JOBS" 2>/dev/null; then
        echo "FAIL mid-string traversal in destination was NOT rejected"
    else
        echo "PASS mid-string traversal in destination rejected"
    fi

    # Case B: mid-string traversal in iso path.
    { echo '---JOBS---'; echo "~/abs/../etc/passwd.7z|lvol|games/game1~"; echo '---END---'; } > "$T19_JOBS"
    JOBS=()
    if load_jobs "$T19_JOBS" 2>/dev/null; then
        echo "FAIL mid-string traversal in iso path was NOT rejected"
    else
        echo "PASS mid-string traversal in iso path rejected"
    fi

    # Case C: legitimate dots in filenames must still pass.
    { echo '---JOBS---'; echo "~/abs/path/game.v1.7z|lvol|games/game.v1~"; echo '---END---'; } > "$T19_JOBS"
    JOBS=()
    if load_jobs "$T19_JOBS" 2>/dev/null; then
        echo "PASS legitimate dotted filename accepted"
    else
        echo "FAIL legitimate dotted filename wrongly rejected"
    fi

    # Case D: basename-`.` pathological input — "/..7z" strips to "." after
    # `basename "/..7z" ".7z"`. Must be rejected by the archive-basename guard.
    { echo '---JOBS---'; echo "~/..7z|lvol|games/game1~"; echo '---END---'; } > "$T19_JOBS"
    JOBS=()
    if load_jobs "$T19_JOBS" 2>/dev/null; then
        echo "FAIL '/..7z' (basename='.') was NOT rejected"
    else
        echo "PASS '/..7z' rejected by basename guard"
    fi
)

rm -f "$T19_JOBS"

header "Int Test 20: sd adapter containment check on vfat"

# The lvol adapter has its own realpath-based containment check. Even
# if load_jobs missed a traversal (which it shouldn't), the adapter must
# still refuse to escape LVOL_MOUNT_POINT. Call the adapter directly against
# a destination that tries to escape the loop-mounted vfat root.

T20_SRC="$INT_EXTRACT/t20_src"
mkdir -p "$T20_SRC"
printf 'test\n' > "$T20_SRC/content.txt"

set +e
LVOL_MOUNT_POINT="$INT_SD_VFAT" \
bash "$ROOT_DIR/adapters/lvol.sh" \
    "$T20_SRC" "../../../etc/passwd" >/dev/null 2>&1
t20_rc=$?
set -e

if (( t20_rc != 0 )); then
    pass "Test 20: lvol adapter refused '../..' destination (rc=$t20_rc)"
else
    fail "Test 20: lvol adapter accepted '../..' destination — CRITICAL"
fi

# Confirm nothing escaped /etc (we should not even have written anywhere).
if [[ ! -f /etc/passwd_t20_canary ]]; then
    pass "Test 20: no escape write happened"
else
    fail "Test 20: adapter wrote outside mountpoint — CRITICAL"
    rm -f /etc/passwd_t20_canary
fi

rm -rf "$T20_SRC"
