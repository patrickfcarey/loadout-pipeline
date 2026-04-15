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
# _out_dir remains armed for cleanup through strip + flatten: a failure in
# any of those post-extract passes leaves an unusable partial tree we want
# the EXIT trap to wipe. It is cleared to "" right before queue_push below.

# ── 6a. Strip unwanted files (top level, pre-flatten) ────────────────────
# Runs before flatten so strip-list entries that sit alongside a wrapper
# directory (classic "game_dir/ + Vimm's Lair.txt" pattern) are removed
# first — otherwise they would count as extra top-level files and force
# _maybe_flatten_wrapper to bail out.
#
# _strip_pass reads EXTRACT_STRIP_LIST (default: $ROOT_DIR/strip.list)
# and deletes any matching plain filenames found directly in the given
# directory. Only bare filenames are supported — entries containing '/'
# are skipped with a warning so the strip list cannot reference files
# outside the target directory. Strip failures are non-fatal: a missing
# list or unremovable file does not abort the pipeline run.
_strip_pass() {
    local target_dir="$1"
    local strip_list_path="${EXTRACT_STRIP_LIST:-$ROOT_DIR/strip.list}"
    [[ -f "$strip_list_path" ]] || return 0
    local strip_filename strip_target
    while IFS= read -r strip_filename; do
        [[ -z "$strip_filename" || "$strip_filename" =~ ^[[:space:]]*# ]] && continue
        strip_filename="${strip_filename%"${strip_filename##*[![:space:]]}"}"
        [[ -z "$strip_filename" ]] && continue
        if [[ "$strip_filename" == */* ]]; then
            log_warn "extract: strip list entry contains '/'; only bare filenames are supported — skipping: $strip_filename"
            continue
        fi
        strip_target="$target_dir/$strip_filename"
        if [[ -f "$strip_target" ]]; then
            log_trace "extract: stripping '$strip_filename' from $(basename "$target_dir")"
            echo "[extract] Stripping '$strip_filename'"
            rm -f -- "$strip_target" || log_warn "extract: failed to remove '$strip_target'"
        fi
    done < "$strip_list_path"
}
_strip_pass "$out_dir"

# ── 6b. Flatten single-directory wrapper, if present ─────────────────────
# Some 7z archives store their payload under a single top-level directory
# (e.g. "MyGame/game.iso" instead of "game.iso"). Dispatch expects the
# payload to live directly in $out_dir, so if — after the pre-flatten
# strip pass above — the only thing inside $out_dir is exactly one
# directory, lift its contents up one level and remove the now-empty
# wrapper. Then re-run strip so any strip-list entries that lived INSIDE
# the wrapper are also cleaned.
#
# Ambiguity policy: if $out_dir contains more than one directory, or any
# mix of files AND directories at the top level, the correct payload is
# undecidable from file listings alone. Log an error and return non-zero
# so extract.sh exits non-zero and unzip_worker moves on to the next job
# in the queue (the existing worker fail-and-continue behaviour).
_maybe_flatten_wrapper() {
    local dir="$1"
    local entries=() entry
    while IFS= read -r -d '' entry; do
        entries+=("$entry")
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)

    local n=${#entries[@]}
    (( n == 0 )) && return 0

    local dir_count=0 file_count=0 wrapper=""
    for entry in "${entries[@]}"; do
        if [[ -L "$entry" ]]; then
            # A top-level symlink is neither a clean wrapper nor a clean
            # payload file; it could redirect a later mv outside $out_dir.
            (( file_count++ )) || true
        elif [[ -d "$entry" ]]; then
            (( dir_count++ )) || true
            wrapper="$entry"
        else
            (( file_count++ )) || true
        fi
    done

    # No directory at the top level → archive stores its payload as loose
    # files directly (e.g. .bin + .cue pair). Nothing to flatten.
    if (( dir_count == 0 )); then
        return 0
    fi

    # Wrapper directory plus ANY other entry (another directory, a loose
    # file, or a symlink) → ambiguous. Strip has already run once, so the
    # extras here are not strip-list cruft; we cannot guess which set is
    # the real payload.
    if (( dir_count > 1 || file_count > 0 )); then
        log_error "extract: cannot flatten wrapper for '$(basename "$dir")' — top level has $dir_count directories and $file_count non-directory entries; skipping this job"
        return 1
    fi

    # Exactly one directory, nothing else → lift its contents up one level.
    log_info "extract: flattening single-directory wrapper '$(basename "$wrapper")' into '$(basename "$dir")'"
    echo "[extract] Flattening wrapper '$(basename "$wrapper")'"

    local inner
    # Enable dotglob so hidden files inside the wrapper come along. Use a
    # subshell to localise the shopt change and avoid leaking state.
    (
        shopt -s dotglob nullglob
        for inner in "$wrapper"/*; do
            # A member name collision with something already at the top
            # level is impossible here because the pre-flatten check
            # confirmed $dir contained exactly one entry ($wrapper).
            mv -- "$inner" "$dir/"
        done
    )

    rmdir "$wrapper" || {
        log_error "extract: failed to remove emptied wrapper dir $wrapper"
        return 1
    }
    return 0
}

if ! _maybe_flatten_wrapper "$out_dir"; then
    exit 1
fi

# ── 6c. Strip again (post-flatten, for files that lived inside wrapper) ──
_strip_pass "$out_dir"

# Post-success: clear out_dir from the trap's cleanup list so a later
# failure in the dispatch-queue push does not wipe the freshly prepared
# content we are about to hand off.
_out_dir=""

# ── 7. Push onto the dispatch queue ───────────────────────────────────────
queue_push "$DISPATCH_QUEUE_DIR" "~${out_dir}|${adapter}|${dest}~"

log_trace "← extract.sh  queued for dispatch"
