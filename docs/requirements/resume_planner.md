# Subsystem: Resume Planner

Cold-restart fast-path pre-pass. Runs synchronously between
`_pipeline_run_init` and the JOBS enqueue loop in `workers_start()`.
Drops every job whose content is already fully present at the adapter
destination, saving potentially hundreds of bash + 7z forks and
thousands of SD-card stats on a 500-job re-submit.

The planner can only produce **false negatives** (keep a job that
was actually satisfied — precheck catches it later), never false
positives, so accuracy is identical to the no-planner baseline.

**Scope**: sd adapter only. `ftp`/`hdl`/`rclone`/`rsync` precheck is
a stub, so planning them buys nothing.

**Disable switch**: `RESUME_PLANNER_IND=0` bypasses the planner
entirely. The disabled path logs once and returns early, leaving
`JOBS` untouched. Useful for forced full re-verification during
debugging.

**Cache shape**: in-memory, per-run.
- `_resume_dest_cache` — associative array keyed by absolute dest
  dir, values are NUL-delimited relative paths (one `find` per
  unique destination, not per job).
- `_resume_archive_cache` — associative array keyed by absolute
  archive path, values are newline-delimited strip-filtered member
  lists (one `7z l` per unique archive, not per job line).

### `_resume_plan_member_is_safe`

**Source**: `lib/resume_planner.sh:84`
**Visibility**: private
**Test coverage**: none — not directly asserted. Structural twin of
`_precheck_member_is_safe` which is pinned by `test/suites/15_unit_runtime.sh` R2.
Exercised indirectly by suite 20 RP2/RP3/RP4.

**Signature**
```
_resume_plan_member_is_safe <member>
```

| Position | Name   | Type   | Constraint                                                   |
| -------: | ------ | ------ | ------------------------------------------------------------ |
|       $1 | member | string | Archive-member filename as emitted by `7z l -slt` Path line. |

**Returns**:

|  rc | Meaning                                                                          |
| --: | -------------------------------------------------------------------------------- |
| `0` | Safe — relative path that cannot escape the destination directory when appended. |
| `1` | Unsafe — absolute, contains `..`, empty, or contains newline.                    |

**Stdout**: silent.
**Stderr**: silent.

**Preconditions**: none.

**Postconditions**: pure — no state change.

**Invariants**

- **Structural twin** of `_precheck_member_is_safe` in
  `lib/precheck.sh:100`. `precheck.sh` is always forked as a
  subprocess so its helpers cannot be sourced; duplicating 7 lines
  is cheaper than refactoring the fork boundary. The two copies must
  stay in sync when either side changes.
- Rejects the same four categories:
  - Empty string
  - Absolute path (`/*`)
  - Embedded newline (`*$'\n'*`)
  - `..` component at any path boundary (`(^|/)\.\.(/|$)`)
- No `realpath` call — byte-level rejection only.

**Side effects**: none.

**Error modes**: none — rc=1 is normal rejection.

**Example**
```bash
_resume_plan_member_is_safe "../etc/passwd"  # returns 1
_resume_plan_member_is_safe "game/game.iso"  # returns 0
```

### `_resume_plan_dest_for_job`

**Source**: `lib/resume_planner.sh:113`
**Visibility**: private
**Test coverage**: `test/suites/20_unit_adapters_resume.sh` RP1

**Signature**
```
_resume_plan_dest_for_job <dest>
```

| Position | Name | Type   | Constraint                                   |
| -------: | ---- | ------ | -------------------------------------------- |
|       $1 | dest | string | Adapter destination field from the job line. |

**Returns**:

|  rc | Meaning                                                                            |
| --: | ---------------------------------------------------------------------------------- |
| `0` | Prints the canonical absolute destination path to stdout.                          |
| `1` | Containment escape, `realpath` unavailable, or `realpath` failed. Nothing printed. |

**Stdout**: on rc=0, the canonical absolute path (one line, trailing newline).
**Stderr**: silent.

**Preconditions**

- `$LVOL_MOUNT_POINT` is set.
- `realpath` is on `$PATH` (if absent, returns 1 — the job is kept
  and deferred to precheck).

**Postconditions (on rc=0)**

- The returned path starts with `realpath -m "$LVOL_MOUNT_POINT"`.
- The path is safe to use as a base for file-existence probes.

**Postconditions (on rc=1)**

- Nothing printed. The caller must keep the job and defer to
  precheck for the authoritative verdict.

**Invariants**

- Mirrors the containment guard at `lib/precheck.sh:125-135`.
  Uses `realpath -m` which accepts paths whose tail does not yet
  exist — the destination directory may be a fresh directory that
  has not been created yet.
- Canonicalization of both `$local_root` and `$LVOL_MOUNT_POINT`
  before the `case` prefix match ensures that symlinks in either
  path do not defeat the containment check.
- The trailing `/` appended to `${local_root_canonical}/` in the
  case pattern prevents `$LVOL_MOUNT_POINT/games` from matching
  `$LVOL_MOUNT_POINT/games_extra`. Without the `/`, any destination
  that shares a common prefix with another destination would match.
- Fails closed: any error (realpath missing, realpath failed,
  containment escaped) returns 1 → "cannot plan" → job kept →
  precheck decides. The planner never drops a job it cannot verify.

**Side effects**: none.

**Error modes**: none surfaced. All failures return 1.

**Example**
```bash
if local_root="$(_resume_plan_dest_for_job "$dest")"; then
    # $local_root is canonical and inside LVOL_MOUNT_POINT
else
    # keep job, defer to precheck
fi
```

### `_resume_plan_load_dest_cache`

**Source**: `lib/resume_planner.sh:146`
**Visibility**: private
**Test coverage**: none — not directly asserted. Exercised indirectly
by `test/suites/20_unit_adapters_resume.sh` RP4 (cache hit + miss paths).

**Signature**
```
_resume_plan_load_dest_cache <dir>
```

| Position | Name | Type          | Constraint                                |
| -------: | ---- | ------------- | ----------------------------------------- |
|       $1 | dir  | absolute path | Canonical absolute destination directory. |

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: silent.

**Preconditions**

- The caller-supplied associative array `_resume_dest_cache` exists
  in scope.

**Postconditions**

- `_resume_dest_cache[$dir]` is set. If `$dir` exists, the value
  is a NUL-delimited set of every file and symlink beneath `$dir`
  (relative to `$dir`). If `$dir` does not exist, the value is an
  empty string.

**Invariants**

- **No-op on cache hit**: `[[ -n "${_resume_dest_cache[$dir]+_}" ]]`
  checks for key presence (not value truthiness), so an empty-string
  value from a missing dir is still a cache hit on the second call.
- Uses `find ... -type f -o -type l` to match the follow-symlinks
  semantics of `[[ -e ]]` used by `precheck.sh:152`. A plain
  `-type f` would miss symlinks that precheck considers present.
- `find -printf '%P\0'` outputs paths **relative** to `$dir` with
  NUL delimiters. NUL is the only character that cannot appear in a
  Unix filename, making the delimiter unambiguous.
- Missing dirs store an empty string rather than erroring. Every
  subsequent membership test against a missing dir cleanly misses,
  causing the job to be kept — which is the correct conservative
  behavior.
- `2>/dev/null` on `find` suppresses permission-denied errors on
  inaccessible subdirectories. Those files are treated as missing →
  job kept → precheck decides.

**Side effects**

- Populates `_resume_dest_cache[$dir]`.
- On cache miss: runs `find` on `$dir`.

**Error modes**: none. A `find` failure produces an empty or partial
cache entry — job kept.

**Example**
```bash
_resume_plan_load_dest_cache "$local_root"
present="${_resume_dest_cache[$local_root]}"
```

### `_resume_plan_archive_members`

**Source**: `lib/resume_planner.sh:186`
**Visibility**: private
**Test coverage**: `test/suites/20_unit_adapters_resume.sh` RP2 (empty archive),
RP3 (strip-list filtering)

**Signature**
```
_resume_plan_archive_members <archive>
```

| Position | Name    | Type          | Constraint             |
| -------: | ------- | ------------- | ---------------------- |
|       $1 | archive | absolute path | `.7z` archive on disk. |

**Returns**:

|  rc | Meaning                                                                                                |
| --: | ------------------------------------------------------------------------------------------------------ |
| `0` | Members printed to stdout (newline-delimited, strip-filtered, safe).                                   |
| `1` | 7z failed, archive unreadable, empty listing, or an unsafe member was found. Caller must keep the job. |

**Stdout**: on rc=0, newline-delimited list of safe, non-stripped
archive members. Trailing newline after the last member.
**Stderr**: silent.

**Preconditions**

- `_resume_archive_cache` associative array exists in scope.
- `7z`, `awk`, `tail` are on `$PATH`.
- `strip_list_contains` is defined.

**Postconditions (on rc=0)**

- `_resume_archive_cache[$archive]` has been populated with the
  member list.
- Every returned member passed `_resume_plan_member_is_safe`.
- Every returned member was **not** matched by `strip_list_contains`.

**Postconditions (on rc=1)**

- Cache is NOT populated (failed archives are not memoized).

**Invariants**

- **Memoised**: the same archive referenced by multiple job lines
  only pays one `7z l` invocation. The cache key is the absolute
  archive path.
- **Strip-aware**: any member that `strip_list_contains` matches is
  dropped from the returned list, matching the invariant at
  `precheck.sh:151`. Without this, the planner would report "member
  X is missing at destination" for a file that was never dispatched,
  causing a false "not satisfied" and defeating the fast-path.
- **Unsafe member → fail-closed**: a single unsafe member causes
  `return 1` immediately — the whole job is kept, not just the
  unsafe member dropped. Rationale: an archive with malicious member
  names is suspect; precheck should issue the authoritative exit 2.
- **Empty after filtering → return 1**: an archive where every
  member is stripped has zero deliverables. `precheck.sh:64` exits 2
  for an empty archive; the planner defers to it.
- `LC_ALL=C` pins `7z l -slt` + awk, matching `extract.sh` and
  `precheck.sh`.
- `tail -n +2` drops the archive's own Path line (the first
  `Path = ` line emitted by `7z l -slt` is the archive itself).

**Side effects**

- On cache miss: runs `7z l -slt` on the archive (read-only).
- Populates `_resume_archive_cache[$archive]` on success.
- Reads the strip list via `strip_list_contains`.

**Error modes**: rc=1 on any failure — never surfaces as a pipeline
abort.

**Example**
```bash
members="$(_resume_plan_archive_members "$archive")" || {
    survivors+=("$raw_job")
    continue
}
```

### `_resume_plan_job_is_satisfied`

**Source**: `lib/resume_planner.sh:236`
**Visibility**: private
**Test coverage**: `test/suites/20_unit_adapters_resume.sh` RP4

**Signature**
```
_resume_plan_job_is_satisfied <archive> <local_root>
```

| Position | Name       | Type          | Constraint                                                               |
| -------: | ---------- | ------------- | ------------------------------------------------------------------------ |
|       $1 | archive    | absolute path | `.7z` archive on disk.                                                   |
|       $2 | local_root | absolute path | Canonical destination directory (output of `_resume_plan_dest_for_job`). |

**Returns**:

|  rc | Meaning                                                                              |
| --: | ------------------------------------------------------------------------------------ |
| `0` | Every strip-filtered member present at `$local_root`. Caller should drop the job.    |
| `1` | At least one member missing, or the planner cannot decide. Caller must keep the job. |

**Stdout**: silent.
**Stderr**: silent.

**Preconditions**

- `_resume_dest_cache` and `_resume_archive_cache` associative
  arrays exist in scope.
- `_resume_plan_archive_members` and `_resume_plan_load_dest_cache`
  are defined.

**Postconditions (on rc=0)**

- The dest and archive caches have been populated (as side effects
  of the helper calls).

**Postconditions (on rc=1)**

- The dest cache may or may not be populated, depending on where
  the failure occurred.

**Invariants**

- **Fast early-exit**: if `$local_root` does not exist as a
  directory (`[[ -d "$local_root" ]] || return 1`), skip the
  `7z l` entirely and return 1 immediately. This keeps the
  planner's cold-run overhead near zero for the common
  first-ever-run case where no destination directories exist yet.
- **NUL-delimited membership test**: the `case` pattern
  `$'\0'"$present"` prepends a NUL to the cache string so the
  first entry also matches the `*$'\0'"$member"$'\0'*` pattern.
  This is a byte-exact substring match, not a glob. NUL is the
  only character that cannot appear in a Unix filename, so the
  test has zero false positives.
- The membership test checks each member one by one. A large
  archive with many members pays O(n×m) in the `case` pattern
  match, where n = members and m = cache size. This is acceptable
  because the cache values are typically small (hundreds of
  entries) and the bash pattern match is a simple substring search.
- Missing member → `return 1` immediately with no further iteration.
  Partial presence is treated as "not satisfied" — the pipeline
  will re-extract and re-dispatch the whole archive.

**Side effects**

- Populates `_resume_dest_cache[$local_root]` via
  `_resume_plan_load_dest_cache` if not already cached.
- Populates `_resume_archive_cache[$archive]` via
  `_resume_plan_archive_members` if not already cached.

**Error modes**: rc=1 on any failure.

**Example**
```bash
if _resume_plan_job_is_satisfied "$archive" "$local_root"; then
    (( dropped++ )) || true
    continue
fi
survivors+=("$raw_job")
```

### `resume_plan`

**Source**: `lib/resume_planner.sh:295`
**Visibility**: public
**Test coverage**: `test/suites/12_resume_planner.sh` (12A–12G end-to-end),
`test/suites/20_unit_adapters_resume.sh` RP5 (disable switch)

**Signature**
```
resume_plan
```

Takes no arguments — reads and mutates the global `JOBS` array.

**Returns**: `0` always — failures to plan fall through to the normal
precheck path, never aborting the pipeline.
**Stdout**: silent.
**Stderr**: `log_info` summary line `"resume planner: N of M already
satisfied in Xs (K to process)"`, or `"resume planner: disabled"`.

**Preconditions**

- The global `JOBS` array has been populated by `load_jobs`.
- `LVOL_MOUNT_POINT` is set (for sd adapter resolution).
- `parse_job_line`, `strip_list_contains`, `_resume_plan_*` helpers
  are all defined.
- No worker has forked yet — the planner runs in a quiescent window.

**Postconditions (RESUME_PLANNER_IND=0)**

- `JOBS` is untouched.
- One `log_info` "disabled" line emitted.

**Postconditions (RESUME_PLANNER_IND=1 or unset)**

- `JOBS` has been rewritten in place. Every job whose sd-adapter
  content is fully present at the destination has been removed.
  Surviving jobs appear in their original iteration order.
- One `log_info` summary line emitted.

**Invariants**

- **Quiescent-window safety**: the planner runs synchronously
  between `_pipeline_run_init` and the JOBS enqueue loop in
  `workers_start()`. No worker has forked, no dispatch is
  happening, the destination is static. Staleness is structurally
  impossible because the caches are only consulted during this
  window.
- **sd-only**: non-sd jobs (`adapter != "sd"`) are kept
  unconditionally. The planner has no logic for ftp/hdl/rclone/rsync
  stub adapters; adding per-adapter branches there is explicitly
  deferred.
- **Malformed jobs are kept**: if `parse_job_line` rejects a job
  token, the planner keeps it in `JOBS` so the downstream worker
  can issue the authoritative error with full context. The planner
  never drops a job silently.
- **Fails-open on containment escape**: if
  `_resume_plan_dest_for_job` returns 1 (containment escape or
  `realpath` unavailable), the job is kept with a `log_warn` and
  precheck issues the authoritative verdict.
- **Fresh per-call caches**: `declare -A` inside the function
  creates local scope, so caches do not leak between calls or
  into forked workers.
- **Original iteration order preserved**: survivors are appended in
  the order they appear in `JOBS`, so downstream FIFO assumptions
  hold. Reordering survivors would change the queue order, which
  changes the worker assignment pattern and could subtly affect
  space reservation pressure.
- `RESUME_PLANNER_IND` defaults to `"1"` if unset. The string
  comparison `!= "1"` means any non-`"1"` value disables the
  planner, not just `"0"`. This is intentional: an operator setting
  `RESUME_PLANNER_IND=off` or `RESUME_PLANNER_IND=false` gets the
  disable behavior rather than a silent ignore.
- The `(( dropped++ )) || true` guards against `set -e` triggering
  on arithmetic-expansion rc=1 when `dropped` increments from 0
  (the result of `(( 0++ ))` is 0, which `set -e` interprets as
  false).

**Side effects**

- Mutates the global `JOBS` array.
- Runs `find` on each unique sd destination directory (via the dest
  cache).
- Runs `7z l -slt` on each unique archive (via the archive cache).
- Reads the strip list via `strip_list_contains`.
- Calls `date +%s` twice (start + end, for the summary line).

**Error modes**: none surfaced. Any internal failure causes the
affected job to be kept — the planner is a pure performance
optimization and never causes work to be skipped that shouldn't be.

**Example**
```bash
# In workers_start(), after _pipeline_run_init:
resume_plan
# JOBS now contains only the jobs that need work.
for job in "${JOBS[@]}"; do
    queue_push "$EXTRACT_QUEUE_DIR" "$job"
done
```

**Exemptions**: `RESUME_PLANNER_IND=0` bypass is a test-convenience
hook. Not frozen — changing the env var name or default would not
break any public contract.
