#!/usr/bin/env bash
# =============================================================================
# ADAPTER: LOCAL VOLUME  (local directory copy)
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"
# =============================================================================
# Copies an extracted directory to a local path under LVOL_MOUNT_POINT.
# LVOL_MOUNT_POINT can be any writable local directory: an SD card, a USB
# drive (NVMe/SSD/HDD), a NAS mountpoint, or a plain folder on disk.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory to copy
#   $2  dest  — destination subdirectory path under LVOL_MOUNT_POINT
#               (e.g. "games/game1" → copies to $LVOL_MOUNT_POINT/games/game1/)
#
# ENVIRONMENT VARIABLES (set in .env or passed at call time)
#   LVOL_MOUNT_POINT — destination root (default: /mnt/lvol)
#
# COPY STRATEGY
#   rsync is used when available: it is progress-aware, skips files that are
#   already identical (size + modtime), and handles large transfers gracefully.
#   cp -r is used as a fallback when rsync is not installed.
#
#   In both cases, the *contents* of $src are copied into $target — not $src
#   itself as a subdirectory. This matches the precheck convention where
#   members are expected at $LVOL_MOUNT_POINT/$dest/<member>, not at
#   $LVOL_MOUNT_POINT/$dest/$(basename $src)/<member>.
# =============================================================================

set -euo pipefail

src="$1"
dest="$2"

# Normalise: strip trailing slash from mount point, leading slash from dest
# so the join is always a clean single-slash separator.
mount_point="${LVOL_MOUNT_POINT%/}"
dest_clean="${dest#/}"
target="${mount_point}/${dest_clean}"

# ── Validate ─────────────────────────────────────────────────────────────────

if [[ ! -d "$src" ]]; then
    log_error "lvol: source directory does not exist: $src"
    exit 1
fi

if [[ -z "$mount_point" ]]; then
    log_error "lvol: LVOL_MOUNT_POINT is not set"
    exit 1
fi

if [[ ! -d "$mount_point" ]]; then
    log_error "lvol: LVOL_MOUNT_POINT does not exist: $mount_point"
    exit 1
fi

if [[ ! -w "$mount_point" ]]; then
    log_error "lvol: LVOL_MOUNT_POINT is not writable: $mount_point"
    exit 1
fi

# ── Containment check ─────────────────────────────────────────────────────────
# Resolve both paths to canonical absolute form (without requiring the target to
# exist yet) and assert that target stays inside mount_point. This defends
# against destination fields containing ".." path segments that would escape the
# mount-point sandbox (e.g. dest="../../etc/cron.d").
#
# realpath -m is POSIX-extended GNU coreutils — available on Linux; macOS users
# can install coreutils via Homebrew for the same flag. It is MANDATORY: a
# missing realpath would skip the containment check entirely, allowing a
# malicious jobs.txt with "../../etc/passwd" destinations to overwrite arbitrary
# filesystem locations. Failing hard is safer than degrading to no check.
if ! command -v realpath >/dev/null 2>&1; then
    log_error "lvol: realpath not found — containment check is mandatory, refusing to proceed"
    log_error "lvol: install GNU coreutils (apt: coreutils, brew: coreutils) to enable the adapter"
    exit 1
fi
target_canonical="$(realpath -m "$target")"
mount_canonical="$(realpath -m "$mount_point")"
case "${target_canonical}/" in
    "${mount_canonical}/"*) : ;;   # contained — all good
    *)
        log_error "lvol: destination escapes LVOL_MOUNT_POINT"
        log_error "lvol:   resolved target : $target_canonical"
        log_error "lvol:   allowed root    : $mount_canonical"
        exit 1
        ;;
esac

# ── Copy ─────────────────────────────────────────────────────────────────────

mkdir -p "$target"

log_trace "lvol: copying $src → $target"
echo "[lvol] Copying $src → $target"

if command -v rsync >/dev/null 2>&1; then
    # Trailing slash on $src/ copies the contents of src into target rather
    # than nesting src as a subdirectory inside target.
    rsync -a "$src/" "$target/"
else
    cp -r "$src/." "$target/"
fi

log_trace "lvol: done → $target"
