#!/usr/bin/env bash
# =============================================================================
# EXTRACT WORKER STAGE — runs once per job, as a subprocess of unzip_worker.
# =============================================================================
# Pipeline stages:
#   1. Parse the job line (~iso|adapter|dest~).
#   2. Precheck: "already at destination?" gate. Three outcomes:
#        rc=0 → content already present → log skip and exit 0
#        rc=1 → proceed with reservation + copy + extract + push
#        rc=2 → fatal (malformed archive, unknown adapter) → exit non-zero
#   3. Reserve scratch space via lib/space.sh before touching the disk.
#      This is an atomic check-and-commit under a shared flock so concurrent
#      workers never collectively overshoot the filesystem. If reservation
#      does not fit right now, exit 75 so the worker re-queues the job and
#      retries when a sibling finishes and releases its hold.
#   4. Copy the archive to COPY_DIR (fast scratch) under a unique name that
#      preserves the original filename.
#   5. 7z-extract to EXTRACT_DIR, then delete the scratch copy.
#      Extraction preserves every member's original filename (works for
#      single- and multi-file archives alike — e.g. a .bin + .cue pair).
#   6. Strip unwanted files from the extracted directory. Any filenames
#      listed in EXTRACT_STRIP_LIST (default: strip.list in ROOT_DIR) are
#      deleted before the content is dispatched, so they never reach the
#      adapter destination. See strip.list for the default set.
#   7. Push a new job onto DISPATCH_QUEUE_DIR for a dispatch worker.
#
# Exit trap
#   An EXIT trap runs on every exit path (success, set -e abort, SIGTERM).
#   It always releases the space reservation and, on non-zero exit, removes
#   the scratch copy and the partial extract dir so no litter is left behind.
#   SIGKILL bypasses the trap; space_init at the start of the next pipeline
#   run wipes the ledger so stale reservations do not persist across runs.
#
# Filename-preservation convention
#   Any decoration this pipeline adds to its own filenames is appended to the
#   original name — never interpolated in the middle. A scratch copy of
#   game1.7z is named `game1.7z.<pid>`, not `game1.<pid>.7z`. Extracted
#   members keep their archive-supplied names exactly.
# =============================================================================
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/job_format.sh"
source "$ROOT_DIR/lib/queue.sh"
source "$ROOT_DIR/lib/space.sh"

job="$1"

# State used by the exit trap. copy/out_dir are populated as soon as the
# extract stage knows their final paths; the trap cleans them up on ANY
# non-zero exit so a mid-extract failure never leaves scratch litter behind.
# The space reservation, if taken, must always be released — even on success,
# signal, or `set -e` abort.
_copy_path=""
_out_dir=""
_reserved=0
_reservation_id="extract.$BASHPID"

# ─── _on_exit ─────────────────────────────────────────────────────────────────
# EXIT trap handler. Runs on every exit path from this script: normal completion,
# set -e abort, SIGTERM. SIGKILL bypasses it (the pipeline handles SIGKILL
# recovery separately via the space ledger GC and worker registry).
#
# Always releases the space reservation when _reserved=1. On non-zero exit,
# also removes the scratch copy (_copy_path) and partial extract directory
# (_out_dir) so failed runs leave no litter in the scratch filesystem.
#
# The _out_dir guard is intentionally only applied on rc!=0: on success, the
# extracted directory is the work product handed off to dispatch and must not
# be deleted. The _out_dir variable is also cleared to "" immediately after
# successful extraction (line ~160) so a later failure in the dispatch-queue
# push cannot accidentally trigger a rm -rf of the freshly extracted content.
#
# Parameters  : none (reads $? automatically as the script's exit code)
# Returns     : preserves the original exit code via `return $rc`
# Modifies
#   space ledger — space_release is called when _reserved == 1; removes this
#                  worker's reservation so siblings can use the freed bytes
#   filesystem   — on rc!=0: deletes $_copy_path (scratch .7z copy) if it exists;
#                  deletes $_out_dir (partial extract dir) if it exists
#
# Locals
#   rc — the exit code of the script at the moment the trap fires ($?)
# ──────────────────────────────────────────────────────────────────────────────
_on_exit() {
    local rc=$?
    if (( _reserved == 1 )); then
        space_release "$_reservation_id" || true
    fi
    if (( rc != 0 )); then
        [[ -n "$_copy_path" && -e "$_copy_path" ]] && rm -f "$_copy_path"
        # Only tear down the out_dir if WE created it this run. An idempotent
        # re-run against an already-populated $out_dir should not be clobbered
        # by a later failure on a different stage — but since we rm -rf only
        # on rc!=0 and extract is the creator, this is safe for the one-job
        # subprocess scope of this script.
        #
        # Hard guards against accidentally wiping EXTRACT_DIR itself: GNU rm
        # already refuses '.'/'..', but busybox and BSD rm do not, and we run
        # on whatever /usr/bin/rm the operator's image provides. The explicit
        # checks below make the safety portable to every rm implementation.
        if [[ -n "$_out_dir" && -d "$_out_dir"
              && "$_out_dir" != "$EXTRACT_DIR"
              && "$_out_dir" != "$EXTRACT_DIR/"
              && "$_out_dir" != */.
              && "$_out_dir" != */..
              && "$_out_dir" != "/" ]]; then
            rm -rf "$_out_dir"
        fi
    fi
    return $rc
}
trap _on_exit EXIT

# Parse the ~iso|adapter|dest~ form using the canonical parser from
# lib/job_format.sh (sourced above). This is the single implementation used
# by every pipeline stage; there is no inline duplicate.
if ! _parsed_job_fields="$(parse_job_line "$job")"; then
    log_error "extract.sh: malformed job token (parser rejected): $job"
    exit 1
fi
# parse_job_line emits three newline-separated fields; read them line-by-line.
{ read -r archive; read -r adapter; read -r dest; } <<< "$_parsed_job_fields"
unset _parsed_job_fields

log_trace "→ extract.sh  archive=$archive  adapter=$adapter  dest=$dest"

# ── 1. Precheck preflight (skip / proceed / fatal) ───────────────────────
precheck_rc=0
bash "$ROOT_DIR/lib/precheck.sh" "$adapter" "$archive" "$dest" || precheck_rc=$?

case "$precheck_rc" in
    0)
        echo "[skip] $job (reason: already exists at destination)"
        log_trace "← extract.sh  skipped"
        exit 0
        ;;
    1)
        : # proceed
        ;;
    *)
        log_error "precheck failed ($precheck_rc) for $job"
        exit "$precheck_rc"
        ;;
esac

# ── 2. Reserve scratch space under the shared ledger ─────────────────────
# Must happen before copy so concurrent workers can't collectively overshoot
# the filesystem. rc=75 signals the worker to re-queue and retry; the release
# is handled by the EXIT trap above.
#
# A missing or unreadable archive is fatal: failing open to 0 bytes here
# would silently under-reserve capacity and let sibling workers overshoot
# the filesystem before the actual cp later fails. Let stat error naturally
# and set -e abort — the trap will release any reservation we've taken.
archive_bytes=$(stat -c %s "$archive")
# LC_ALL=C forces 7z and awk to emit ASCII numbers without thousands
# separators. Without this, a locale like de_DE.UTF-8 would format Size
# values as "1.234.567.890"; awk's += on that evaluates only the leading
# integer, undercounting by orders of magnitude and under-reserving space.
uncompressed_bytes=$(LC_ALL=C 7z l -slt "$archive" 2>/dev/null \
    | LC_ALL=C awk '/^Size = / { s += $3 } END { print s+0 }')
_spool="${COPY_SPOOL:-$COPY_DIR}"
mkdir -p "$_spool" "$EXTRACT_DIR"
# Flag ordering: set _reserved=1 BEFORE space_reserve so that if a signal
# arrives between the successful reserve and the flag assignment, the EXIT
# trap still calls space_release. If space_reserve returns non-zero we
# clear the flag again so we don't release a reservation we never took.
_reserved=1
if ! space_reserve "$_reservation_id" \
        "$_spool"      "$archive_bytes" \
        "$EXTRACT_DIR" "$uncompressed_bytes"; then
    _reserved=0
    log_trace "← extract.sh  space reservation did not fit, will retry"
    exit 75
fi

# ── 3. Copy the archive to scratch ────────────────────────────────────────
# Append the pid AFTER the original extension so the full archive name —
# including its real extension — is preserved as a recognisable prefix.
copy="$_spool/$(basename "$archive").$BASHPID"
_copy_path="$copy"
echo "[extract] Copying $archive → $copy"
cp "$archive" "$copy"

# ── 4. Extract ────────────────────────────────────────────────────────────
name="$(basename "$archive" .7z)"
# Belt-and-braces against a malformed archive name slipping past the jobs.sh
# validator. basename strips a trailing ".7z" suffix, so an input like
# "/..7z" yields name="." — without this check, out_dir would resolve to
# $EXTRACT_DIR itself and extraction would mix into every sibling worker's
# output. jobs.sh rejects this at parse time; the assert here keeps extract
# safe even if called through a path that bypassed jobs.sh.
if [[ -z "$name" || "$name" == "." || "$name" == ".." || "$name" == .* ]]; then
    log_error "extract: refusing invalid archive basename: '$name' (from $archive)"
    exit 1
fi
out_dir="${EXTRACT_DIR}/$name"
_out_dir="$out_dir"

# Guard: if $out_dir already exists as a symlink, an attacker could redirect
# 7z's output to an arbitrary filesystem location (H3). Refuse and fail hard.
if [[ -L "$out_dir" ]]; then
    log_error "extract: refusing to write into symlink at output dir: $out_dir"
    exit 1
fi

mkdir -p "$out_dir"

echo "[extract] Extracting $copy → $out_dir"
# -aoa = overwrite all existing files without prompting (idempotent reruns).
# 7z preserves every member's filename inside $out_dir, so multi-file
# archives (e.g. .bin + .cue) land with both names intact.
7z x -aoa "$copy" -o"$out_dir" >/dev/null

# Scratch copy served its purpose — delete it before we queue up dispatch.
rm -f "$copy"
_copy_path=""
# Successful extract: clear out_dir from the trap's cleanup list so a
# post-success failure (unlikely, but e.g. dispatch queue push) doesn't
# wipe the very content we just extracted.
_out_dir=""

# ── 6. Strip unwanted files from the extracted directory ─────────────────
# Reads EXTRACT_STRIP_LIST (default: $ROOT_DIR/strip.list) for plain
# filenames to delete. Runs after successful extraction so stripped files
# are never dispatched to the adapter destination.
#
# Only bare filenames are supported — entries containing '/' are skipped
# with a warning so the strip list cannot reference files outside $out_dir.
# Strip failures are non-fatal: a missing list or unremovable file does not
# abort the pipeline run.
_strip_list_path="${EXTRACT_STRIP_LIST:-$ROOT_DIR/strip.list}"
if [[ -f "$_strip_list_path" ]]; then
    while IFS= read -r _strip_filename; do
        # Skip blank lines and full-line comments.
        [[ -z "$_strip_filename" || "$_strip_filename" =~ ^[[:space:]]*# ]] && continue
        # Trim trailing whitespace (editor line-ending artifacts).
        _strip_filename="${_strip_filename%"${_strip_filename##*[![:space:]]}"}"
        [[ -z "$_strip_filename" ]] && continue
        # Reject paths: only bare filenames are valid strip-list entries.
        if [[ "$_strip_filename" == */* ]]; then
            log_warn "extract: strip list entry contains '/'; only bare filenames are supported — skipping: $_strip_filename"
            continue
        fi
        _strip_target="$out_dir/$_strip_filename"
        if [[ -f "$_strip_target" ]]; then
            log_trace "extract: stripping '$_strip_filename' from $(basename "$out_dir")"
            echo "[extract] Stripping '$_strip_filename'"
            rm -f -- "$_strip_target" || log_warn "extract: failed to remove '$_strip_target'"
        fi
    done < "$_strip_list_path"
fi

# ── 7. Push onto the dispatch queue ───────────────────────────────────────
queue_push "$DISPATCH_QUEUE_DIR" "~${out_dir}|${adapter}|${dest}~"

log_trace "← extract.sh  queued for dispatch"
