# Subsystem: Extraction Pipeline

The per-job work unit. `extract.sh` runs as a subprocess of
`unzip_worker` for every claimed job; `precheck.sh` runs inside
`extract.sh` as a preflight gate; `dispatch.sh` runs as a subprocess
of `dispatch_worker` for every claimed dispatch token. All three are
invoked via `bash <script> <argv>`, not sourced — this keeps per-job
state (EXIT traps, `set -euo pipefail`, reservation ids) cleanly
scoped to a single subprocess.

The space-retry contract is anchored here: `extract.sh` exits `75`
when `space_reserve` refuses the reservation, and the unzip worker
re-queues the job for a later pass. Any change to this exit code
breaks the worker's retry recognition in `lib/workers.sh:_unzip_handle_job`.

### Script contract: `lib/extract.sh`

**Source**: `lib/extract.sh:1`
**Visibility**: script (invoked as `bash lib/extract.sh <job>`)
**Test coverage**: `test/suites/02_core_pipeline.sh` (end-to-end),
`test/suites/04_failure_handling.sh` (SIGKILL + space-retry),
`test/suites/09_real_archive.sh` (full real 7z),
`test/suites/11_wrapper_flatten.sh` (wrapper payloads)

**Invocation**
```
bash lib/extract.sh <job>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | job | string | Full job token `~iso_path\|adapter\|dest~`. |

**Env dependencies**

| Var | Read by | Purpose |
|---|---|---|
| `ROOT_DIR` | self + sourced libs | Resolve sibling libraries. Derived from `$0` if unset. |
| `QUEUE_DIR` | `lib/space.sh`, `lib/queue.sh` | Space ledger + dispatch queue location. |
| `COPY_DIR` | space reserve / copy stage | Fast scratch area for the archive copy. |
| `COPY_SPOOL` | copy stage | Optional per-worker override of `$COPY_DIR` (workers set this via `_spool_sweep_and_claim`). |
| `EXTRACT_DIR` | extract stage | Where `7z x` writes the payload tree. |
| `EXTRACT_STRIP_LIST` | `_strip_pass` | Optional override; defaults to `$ROOT_DIR/strip.list`. |
| `DISPATCH_QUEUE_DIR` | `queue_push` at end | Target of the handoff token. |
| `LOG_LEVEL`, `DEBUG_IND` | sourced `logging.sh` | Log verbosity knobs. |

**Returns**:

| rc | Meaning |
|---:|---|
| `0` | Success. Either precheck skipped the job, or the full copy+extract+strip+dispatch-queue-push ran and the dispatch token was queued. |
| `1` | Hard failure — malformed job, empty/broken archive, invalid archive basename, symlink at `out_dir`, flatten ambiguity, dispatch queue push failed. |
| `2` | Precheck fatal (malformed archive, unknown adapter). Propagated verbatim from `precheck.sh`. |
| `75` | Space reservation did not fit. Worker re-queues for a later retry. Chosen so it collides with no normal shell exit code. |

**Stdout**: `[extract] Copying ...`, `[extract] Extracting ...`,
`[extract] Stripping ...`, `[extract] Flattening ...`, and
`[skip] <job> (reason: already exists at destination)` on precheck
skip. These are consumed by the pipeline operator's log tail.

**Stderr**: `log_*` lines from the sourced `logging.sh` helpers. On
error the `log_error` lines identify the offending job and stage.

**Preconditions**

- `ROOT_DIR` is set (or derivable from `$0`).
- `QUEUE_DIR`, `COPY_DIR`, `EXTRACT_DIR`, `DISPATCH_QUEUE_DIR` all
  point to real, writable directories.
- `space_init` has already run (so `.space_ledger` exists).
- `7z`, `stat`, `cp`, `rm`, `mv`, `find` are on `$PATH`.
- The job string parses under `parse_job_line`.

**Postconditions (on rc=0, precheck skip)**

- No scratch copy created.
- No entry added to `$EXTRACT_DIR`.
- Space ledger unchanged.

**Postconditions (on rc=0, full run)**

- `$EXTRACT_DIR/<archive_basename>/` contains the extracted payload
  with every member's original filename.
- The scratch `.7z` copy has been removed.
- A dispatch token `~<out_dir>|<adapter>|<dest>~` has been pushed
  onto `$DISPATCH_QUEUE_DIR`.
- The extract-side space reservation has been released.

**Postconditions (on rc=75)**

- Any partial scratch copy has been removed by the EXIT trap.
- Any partial `$out_dir` has been removed by the EXIT trap.
- The space reservation has been released by the EXIT trap (the
  flag was cleared before `exit 75` specifically so the trap does
  **not** call `space_release` on a reservation that was never
  committed).

**Postconditions (on rc=1 or rc=2)**

- Any partial scratch copy has been removed by the EXIT trap.
- Any partial `$out_dir` has been removed by the EXIT trap, **except**
  when the failure happens after `_out_dir=""` is cleared (the
  last step before `queue_push`). A dispatch-push failure that late
  is vanishingly rare — the token is just one filesystem create.
- If a reservation was held, it has been released.

**Invariants**

- `_reserved=1` flag is set **before** `space_reserve` is invoked,
  not after. Rationale: a SIGTERM delivered between a successful
  `space_reserve` and the flag assignment would leave the EXIT trap
  with `_reserved=0` and leak the reservation. Setting the flag
  first and clearing it on refusal keeps the trap correct.
- The scratch copy filename is `<basename>.<BASHPID>`, not
  `<basename_noext>.<BASHPID>.<ext>`. The pid suffix is appended
  **after** the full original filename so operators and log readers
  can identify the original archive by prefix. Two concurrent extract
  workers handling the same archive get distinct spool paths via
  their distinct `BASHPID`s.
- The archive-basename guard at line 194 refuses `name` values of
  `""`, `"."`, `".."`, or anything starting with a dot. This is
  belt-and-braces against `jobs.sh`'s equivalent guard: if `extract.sh`
  is ever called through a path that bypasses `load_jobs`, the
  guard still prevents `out_dir` from resolving to `$EXTRACT_DIR`
  itself and mixing sibling workers' output.
- The `$out_dir` symlink guard at line 203 refuses to write into a
  pre-existing symlink at the output path — a TOCTOU attacker who
  plants a symlink at `$EXTRACT_DIR/<name>` between scheduling and
  extraction could otherwise redirect the entire `7z x` output to
  an arbitrary filesystem location (pinned by suite 16 H3).
- `_strip_pass` runs **twice**: once before `_maybe_flatten_wrapper`
  (to clear strip-listed files that sit alongside a wrapper dir,
  which would otherwise force flatten to refuse), and once after
  flatten (to clean strip-listed files that lived inside the
  wrapper). A single strip pass would leave either pre- or
  post-wrapper cruft.
- `_out_dir=""` is cleared **after** the post-flatten strip and
  **before** `queue_push`. This disarms the EXIT trap's rm-rf so
  that a dispatch-queue-push failure cannot wipe the freshly
  prepared content that was about to be handed off.
- `LC_ALL=C` pins `7z l -slt` + awk Size summation. Without it, a
  locale like `de_DE.UTF-8` could format sizes with thousands
  separators ("1.234.567.890"); awk's `+=` would evaluate only the
  leading integer and undercount by orders of magnitude, causing
  sibling workers to overshoot the filesystem.
- `stat -c %s "$archive"` is allowed to `set -e` the script on a
  missing/unreadable archive. Failing open to 0 bytes would
  under-reserve capacity and let sibling workers overshoot.

**Side effects**

- Acquires and releases space reservation via `lib/space.sh`.
- Creates `$COPY_SPOOL`, `$EXTRACT_DIR` if missing.
- Creates `$COPY_SPOOL/<basename>.<BASHPID>` (scratch copy), then
  removes it after extraction.
- Creates `$EXTRACT_DIR/<archive_basename>/` and populates it.
- Pushes one token to `$DISPATCH_QUEUE_DIR`.
- Installs an EXIT trap (`_on_exit`).

**Error modes**

| rc | Condition | Characteristic stderr |
|---:|---|---|
| 1 | Malformed job token | `extract.sh: malformed job token (parser rejected): <job>` |
| 1 | Invalid archive basename | `extract: refusing invalid archive basename: '<name>' ...` |
| 1 | Symlink at `out_dir` | `extract: refusing to write into symlink at output dir: <path>` |
| 1 | Flatten ambiguity (mixed top-level) | `extract: cannot flatten wrapper for ... — top level has N directories and M non-directory entries; skipping this job` |
| 1 | Wrapper rmdir failed | `extract: failed to remove emptied wrapper dir <wrapper>` |
| 2 | Precheck fatal (propagated) | (from `precheck.sh`) |
| 75 | Space reservation did not fit | `← extract.sh  space reservation did not fit, will retry` |

**Example**
```bash
bash lib/extract.sh "~/isos/game1.7z|lvol|games/game1~"
case $? in
    0)  : ;;
    75) queue_push "$EXTRACT_QUEUE_DIR" "$job" ;;  # re-queue for later
    *)  log_error "extract failed with rc=$?" ;;
esac
```

**Exemptions**: none. All behavior documented here is frozen under
the compat policy.

### `_on_exit` (`lib/extract.sh`)

**Source**: `lib/extract.sh:85`
**Visibility**: private
**Test coverage**: `test/suites/04_failure_handling.sh` (SIGKILL end-to-end),
exercised indirectly by every extract test.

**Signature**
```
_on_exit
```

Takes no arguments — reads `$?` as the script's exit code at trap time.

**Returns**: preserves the script's original exit code via `return $rc`.
**Stdout**: silent.
**Stderr**: silent on success. On release or cleanup failure, may
surface `space_release` error via `|| true` (suppressed).

**Preconditions**

- Installed as `trap _on_exit EXIT` at line 113.
- The state vars `_reserved`, `_copy_path`, `_out_dir`,
  `_reservation_id` are in scope.

**Postconditions**

- If `_reserved == 1`, the reservation has been released (or the
  release attempt failed silently — `|| true` keeps the trap path
  from cascading to another non-zero).
- On `rc != 0`: `_copy_path` has been removed if it existed,
  `_out_dir` has been removed if it was a real directory and
  passed **every** hard guard (not `$EXTRACT_DIR`, not
  `$EXTRACT_DIR/`, not `*/.`, not `*/..`, not `/`).
- On `rc == 0`: `_copy_path` and `_out_dir` are left alone — the
  extracted payload is the work product handed to dispatch and
  must not be deleted.

**Invariants**

- Trap runs on **every** exit path the shell can intercept: normal
  completion, `set -e` abort, SIGTERM, `exit N`. SIGKILL cannot be
  intercepted — that is why `space_init` wipes the ledger and
  `worker_registry_recover` re-queues the orphaned job on the next
  pipeline run.
- The `_out_dir` hard guards are load-bearing on busybox and BSD
  `rm`, which do **not** refuse `.`/`..` like GNU `rm` does. A
  naive `rm -rf "$_out_dir"` with `_out_dir == "$EXTRACT_DIR"`
  (e.g. from a bug that left `_out_dir` misassigned) would wipe
  every sibling worker's output. The explicit `!=` checks make the
  safety portable.
- Release-first, delete-second ordering: the ledger release runs
  unconditionally (on `_reserved == 1`), and the filesystem cleanup
  runs only on non-zero rc. A reversed order would delete scratch
  before releasing the reservation, which is harmless today but
  would break any future attempt to use the spool's byte count as
  a release parameter.
- `_copy_path` is cleared to `""` right after the scratch copy is
  removed (line 218), so a later failure doesn't double-delete.
- `_out_dir` is cleared to `""` after post-flatten strip and
  **before** the dispatch queue push (line 345) so the trap does
  not wipe the freshly prepared payload if the push fails.

**Side effects**

- Calls `space_release "$_reservation_id"`.
- Removes `$_copy_path` if present and rc != 0.
- Removes `$_out_dir` recursively if present, rc != 0, and all hard
  guards pass.

**Error modes**: none surfaced. `space_release` failure is
suppressed via `|| true` to keep the trap idempotent; filesystem
cleanup failures are absorbed by the `[[ -e ]]` guards.

**Example**
```bash
_reserved=1
_copy_path="/tmp/spool/game.7z.12345"
_out_dir="/tmp/extract/game"
trap _on_exit EXIT
# ... any failure here is cleaned up automatically ...
```

### `_strip_pass` (`lib/extract.sh`)

**Source**: `lib/extract.sh:235`
**Visibility**: private
**Test coverage**: `test/suites/17_unit_extract_internals.sh` E1, E2, E3

**Signature**
```
_strip_pass <target_dir>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | target_dir | absolute path | Directory containing the freshly extracted payload. |

**Returns**: `0` always.
**Stdout**: `[extract] Stripping '<filename>'` for each removed entry.
**Stderr**: `log_warn` lines for slash entries and `rm` failures; `log_trace` for every strip.

**Preconditions**

- `$EXTRACT_STRIP_LIST` (optional env var) and `$ROOT_DIR` are set.

**Postconditions**

- For every non-blank, non-comment line in the strip list that is a
  bare filename (no `/`) and names a plain file inside `target_dir`,
  that file has been removed.
- Lines containing `/` are skipped with a warning and leave the
  filesystem untouched.
- A missing strip list is a no-op.

**Invariants**

- Blank lines and full-line comments (`^[[:space:]]*#`) are silently
  skipped, matching the `strip_list_contains` grammar.
- Trailing whitespace is trimmed from each entry before comparison
  (`${strip_filename%"${strip_filename##*[![:space:]]}"}`), so a
  `strip.list` edited on Windows with trailing spaces still matches.
- Slash entries are **refused with a warning**, not matched as paths.
  The strip list is a bare-filename list; slash entries would need
  different semantics (path vs. filename) and the helper refuses to
  guess. This is the single-source-of-truth rule with
  `strip_list_contains` — they must agree, since `resume_planner.sh`
  uses one and `precheck.sh` uses the other to decide "is this file
  even a candidate".
- The strip pass is **non-fatal**. A missing list, an unremovable
  file, or any other step failure only logs a warning — a strip
  failure never aborts the pipeline run. Rationale: strip-list
  content is cosmetic ("remove Thumbs.db"), and losing a file that
  was going to be deleted anyway is not worth crashing over.
- Only plain files are stripped (`[[ -f "$strip_target" ]]`). A
  directory named `Thumbs.db` in the target is left alone — the
  strip list is for files.
- `rm -f --` with `--` end-of-options disambiguates filenames that
  start with a dash.

**Side effects**

- Reads `$EXTRACT_STRIP_LIST` (or `$ROOT_DIR/strip.list`).
- Removes zero or more files from `target_dir`.

**Error modes**: none fatal. Individual `rm` failures are logged
and skipped.

**Example**
```bash
_strip_pass "$out_dir"  # before flatten
_maybe_flatten_wrapper "$out_dir"
_strip_pass "$out_dir"  # after flatten — catches files that lived inside the wrapper
```

### `_maybe_flatten_wrapper` (`lib/extract.sh`)

**Source**: `lib/extract.sh:272`
**Visibility**: private
**Test coverage**: `test/suites/17_unit_extract_internals.sh` E4, E5, E6, E7;
`test/suites/11_wrapper_flatten.sh` (end-to-end)

**Signature**
```
_maybe_flatten_wrapper <dir>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | dir | absolute path | Top-level of the extracted payload (`$out_dir`). |

**Returns**:

| rc | Meaning |
|---:|---|
| `0` | Either no flatten was needed (loose files or empty dir), or a single-wrapper-dir was successfully flattened. |
| `1` | Top-level is ambiguous (more than one directory, or a mix of files + directories, or a top-level symlink), or the `rmdir` of the emptied wrapper failed. |

**Stdout**: `[extract] Flattening wrapper '<name>'` on a successful flatten.
**Stderr**: `log_info` on flatten, `log_error` on ambiguous refusal or rmdir failure.

**Preconditions**

- `$dir` exists and is readable.
- `find`, `mv`, `rmdir` are on `$PATH`.

**Postconditions (on rc=0, flatten performed)**

- `$dir` no longer contains the wrapper subdirectory.
- Every file that lived inside `$wrapper` (including hidden files,
  via `dotglob`) now lives directly in `$dir`.

**Postconditions (on rc=0, no flatten)**

- `$dir` is unchanged.

**Postconditions (on rc=1)**

- `$dir` is unchanged (the refusal happens before any mutation).

**Invariants**

- Classification walks `find -mindepth 1 -maxdepth 1 -print0` with
  null-delimited reads. Filenames containing newlines or spaces are
  handled correctly. A glob-based walk would have subtle issues
  with `IFS` and hidden-file expansion.
- A **top-level symlink** counts as a non-directory entry
  (`file_count++`), not a directory. Rationale: a symlink could
  point outside `$dir`, and a later `mv -- "$inner" "$dir/"` would
  follow the symlink and move the target — an unbounded filesystem
  side effect. Pinned by suite 17 E7.
- The ambiguity policy is conservative: wrapper + any other entry
  (another directory, a loose file, a symlink) → refuse. The
  correct payload is undecidable from file listings alone, and
  guessing would silently misplace content.
- **`dir_count == 0`** is a no-op success: the archive stores its
  payload as loose files (e.g. `.bin` + `.cue` pair), and flatten
  has nothing to do.
- The flatten uses a subshell `(shopt -s dotglob nullglob; mv ...)`
  so the `dotglob`/`nullglob` changes do **not** leak back to the
  caller. Without `dotglob`, hidden files inside the wrapper would
  be left behind as `wrapper/.hiddenfile` → lost after `rmdir`.
  Pinned by suite 17 E6.
- The post-flatten `rmdir` must succeed on an empty wrapper. A
  non-empty wrapper after the `mv` loop would indicate a mv
  failure (the loop uses `mv --` to disambiguate dash-prefixed
  names); the `rmdir` then surfaces that via rc=1.
- No mv-collision handling is needed: the pre-flatten check
  confirmed `$dir` contained **exactly one** entry (`$wrapper`),
  so lifting `$wrapper/*` into `$dir/` cannot collide with anything
  at the top level.

**Side effects**

- Runs `find` on `$dir`.
- On flatten: `mv`'s every immediate child of `$wrapper` into `$dir`,
  then `rmdir`'s `$wrapper`.

**Error modes**

| rc | Condition | Characteristic stderr |
|---:|---|---|
| 1 | Ambiguous top level | `extract: cannot flatten wrapper for '<name>' — top level has N directories and M non-directory entries; skipping this job` |
| 1 | rmdir of emptied wrapper failed | `extract: failed to remove emptied wrapper dir <wrapper>` |

**Example**
```bash
if ! _maybe_flatten_wrapper "$out_dir"; then
    exit 1
fi
_strip_pass "$out_dir"  # post-flatten strip
```

### Script contract: `lib/precheck.sh`

**Source**: `lib/precheck.sh:1`
**Visibility**: script (invoked as `bash lib/precheck.sh <adapter> <archive> <dest>`)
**Test coverage**: `test/suites/03_precheck.sh` (tests 7/8/9 — end-to-end skip + multi-file),
`test/suites/08_security.sh` (member-path injection), `test/suites/15_unit_runtime.sh` R2 (member-safety helper)

**Invocation**
```
bash lib/precheck.sh <adapter> <archive> <dest>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | adapter | string | One of `lvol`, `ftp`, `hdl`, `rclone`, `rsync`. |
| $2 | archive | absolute path | `.7z` archive on disk. |
| $3 | dest | string | Adapter-specific destination path (from the job line). |

**Env dependencies**

| Var | Read by | Purpose |
|---|---|---|
| `ROOT_DIR` | self + sourced libs | Resolve `logging.sh`, `strip_list.sh`. |
| `LVOL_MOUNT_POINT` | sd arm | Mount point for the SD destination — used to build `local_root` and enforce containment. |
| `EXTRACT_STRIP_LIST` | `strip_list_contains` | Skip files that will never be dispatched anyway. |

**Returns**:

| rc | Meaning |
|---:|---|
| `0` | Content already at destination — skip this job. |
| `1` | Content not present — proceed with copy + extract + dispatch. |
| `2` | Fatal: empty/unreadable archive, unknown adapter, unsafe member path, or destination escapes `LVOL_MOUNT_POINT`. |

**Stdout**: silent (all progress goes to `log_trace`).
**Stderr**: `log_warn` for fatal conditions (unsafe member, empty archive, unknown adapter, destination escape).

**Preconditions**

- `$1..$3` are set.
- `7z`, `awk`, `tail` are on `$PATH`.
- For `lvol`: `$LVOL_MOUNT_POINT` is set.

**Postconditions (on rc=0)**

- Every non-stripped member of the archive exists at its expected
  destination path, so the operator's work product is already
  delivered.

**Postconditions (on rc=1)**

- At least one expected destination file is missing, or the adapter
  is a stub (always reports "not present").

**Postconditions (on rc=2)**

- Pipeline has been instructed not to touch this job in this run —
  either the archive is broken or the configuration is unsafe.

**Invariants**

- **Stubs are pessimistic**. `ftp`, `hdl`, `rclone`, `rsync` always
  return `already_present=0` — they always proceed with work rather
  than risk a false skip. Turning any stub into a real check is a
  drop-in replacement at the corresponding `case` arm.
- **Multi-file archives**: the sd arm checks **every** contained
  member. If ANY one is missing, the archive counts as "not
  present" and the whole job re-runs. Partial presence is treated
  as "not yet delivered" — the pipeline will re-extract and
  re-dispatch, overwriting what's already there.
- **Strip-listed members are not probed**. A file that will be
  stripped before dispatch is never delivered to the destination,
  so its absence must not cause a false "not present" result —
  `strip_list_contains "$f" && continue` skips them.
- `LC_ALL=C` pins the `7z l -slt` + awk pipeline. Without it, a
  7z build that localises field names ("Fichier = " in French)
  would yield an empty `$contained` and hit the "empty archive"
  fatal path on every run.
- `set +e` is **narrowed** to the `$(...)` command substitution
  that extracts the archive listing, not the whole script. A
  legitimately empty archive (exit 2 below) is handled explicitly;
  everything else in the script stays under `set -e` so real bugs
  fail loudly.
- `7z l -slt` prints the archive itself as the first `Path = ` line.
  `tail -n +2` drops it — without that, the archive filename
  would be probed at the destination and would almost always
  be missing, flipping the "already present" result to false.
- **Member-path containment** (`_precheck_member_is_safe`) is a
  defense-in-depth gate: it prevents `[[ -e "$local_root/$f" ]]`
  from escaping `$local_root` via `..` or absolute paths in a
  malicious archive. A skipped check would let an attacker either
  leak information ("does /etc/passwd exist?") or trigger a false
  precheck skip, causing the real payload to never extract.
- **SD destination containment**: the `local_root` is canonicalized
  with `realpath -m` and checked against `$LVOL_MOUNT_POINT`. A
  dest like `games/../../etc` that somehow slipped past
  `load_jobs` is caught here. `realpath -m` accepts paths whose
  tail does not exist yet (the destination may be a fresh
  directory).
- CRLF / trailing whitespace on contained members is not specifically
  stripped — 7z's output is used verbatim after awk's `sub`.
  Archives built with sane tooling emit clean paths; this is
  noted here so a future bug report ("files with trailing space
  don't match") finds its hook.

**Side effects**

- Runs `7z l -slt` on the archive (read-only; no extraction).
- On `lvol`: `stat`'s every expected destination file.
- Reads `$EXTRACT_STRIP_LIST` (via `strip_list_contains`).

**Error modes**

| rc | Condition | Characteristic stderr |
|---:|---|---|
| 2 | Empty/unreadable archive | `precheck: archive <archive> is empty or unreadable` |
| 2 | Unsafe member path | `precheck: archive <archive> contains unsafe member path — refusing to probe: <member>` |
| 2 | Destination escapes LVOL_MOUNT_POINT | `precheck: destination escapes LVOL_MOUNT_POINT — refusing probe: <canonical>` |
| 2 | Unknown adapter | `precheck: unknown adapter: <adapter>` |

**Example**
```bash
bash lib/precheck.sh sd /isos/game1.7z games/game1
case $? in
    0) echo "already done" ;;
    1) echo "proceed" ;;
    *) echo "fatal" ;;
esac
```

**Exemptions**: `ftp`, `hdl`, `rclone` stub behavior is **not**
frozen — each may be replaced with a real implementation without a
migration note, so long as the rc=0/1/2 contract is preserved.

### `_precheck_member_is_safe`

**Source**: `lib/precheck.sh:100`
**Visibility**: private
**Test coverage**: `test/suites/15_unit_runtime.sh` R2 (every rejection path),
`test/suites/08_security.sh` (end-to-end attacker archive)

**Signature**
```
_precheck_member_is_safe <member>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | member | string | Archive-member filename as emitted by `7z l -slt` on a `Path = ` line. |

**Returns**:

| rc | Meaning |
|---:|---|
| `0` | Safe — `member` is a relative path that cannot escape `$local_root` when appended. |
| `1` | Unsafe — caller must refuse to use `$member` as a relative path. |

**Stdout**: silent.
**Stderr**: silent (caller logs the warning with full context).

**Preconditions**: none.

**Postconditions**: pure — no state change.

**Invariants**

- **Empty string** → unsafe. An empty member would resolve
  `[[ -e "$local_root/" ]]` to a directory test on the root
  itself, trivially true.
- **Absolute path** → unsafe. `member == /*` means appending to
  `$local_root` gives `${local_root}/absolute_path` which is a
  valid path on some shells; regardless, absolute paths in archive
  members are never legitimate.
- **Newline** → unsafe. A newline inside a member name would let
  an attacker smuggle a second filename past any line-oriented
  downstream check.
- **`..` anywhere** → unsafe. The anchored regex
  `(^|/)\.\.(/|$)` matches `..` at every legitimate path-component
  boundary: start-of-string, after a slash, before a slash, or
  end-of-string. Rationale for the full-boundary regex: a naive
  `[[ "$member" == *..* ]]` would reject legitimate filenames
  containing literal `..` (e.g. `game..bin`).
- `member` is NOT canonicalized with `realpath` — that would
  follow symlinks on the filesystem, which is both slower and
  opens a TOCTOU window. Byte-level rejection is the correct check:
  any member that **looks** unsafe is rejected without touching
  the filesystem.
- The "four-barrel" style (`[[ test ]] || return 1` × 4 then
  `return 0`) is intentional: a single chained `&&`/`||` expression
  would make the failure line ambiguous under `set -x` debugging.

**Side effects**: none.

**Error modes**: none — rc=1 is normal rejection, not an error.

**Example**
```bash
if ! _precheck_member_is_safe "$member"; then
    log_warn "precheck: archive contains unsafe member path: $member"
    exit 2
fi
```

### Script contract: `lib/dispatch.sh`

**Source**: `lib/dispatch.sh:1`
**Visibility**: script (invoked as `bash lib/dispatch.sh <adapter> <src> <dest>`)
**Test coverage**: `test/suites/07_adapters.sh` (end-to-end adapter routing),
`test/suites/16_unit_lib_helpers.sh` H2 (env-strip list generation),
`test/suites/10_regression.sh` (adapter credential isolation)

**Invocation**
```
bash lib/dispatch.sh <adapter> <src> <dest>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | adapter | string | One of `ftp`, `hdl`, `lvol`, `rclone`, `rsync`. |
| $2 | src | absolute path | Extracted payload directory. |
| $3 | dest | string | Adapter-specific destination spec. |

**Env dependencies**

| Var | Read by | Purpose |
|---|---|---|
| `ROOT_DIR` | self + sourced libs | Resolve the target adapter script. |
| `FTP_HOST`, `FTP_USER`, `FTP_PASS`, `FTP_PORT` | ftp arm only | Forwarded to `ftp.sh`. |
| `HDL_DUMP_BIN` | hdl arm only | Forwarded to `hdl_dump.sh`. |
| `LVOL_MOUNT_POINT` | sd arm only | Forwarded to `lvol.sh`. |
| `RCLONE_REMOTE`, `RCLONE_DEST_BASE`, `RCLONE_FLAGS` | rclone arm only | Forwarded to `rclone.sh`. |
| `RSYNC_DEST_BASE`, `RSYNC_HOST`, `RSYNC_USER`, `RSYNC_SSH_PORT`, `RSYNC_FLAGS` | rsync arm only | Forwarded to `rsync.sh`. |

**Returns**: rc of the adapter subprocess; `1` on unknown adapter.
**Stdout**: silent (adapter's stdout passes through).
**Stderr**: adapter's stderr + `log_trace` entry/exit lines.

**Preconditions**

- The adapter script exists at `$ROOT_DIR/adapters/<adapter>.sh`.
- Env vars for the target adapter are set.

**Postconditions (on rc=0)**

- The adapter subprocess ran to completion and reported success.

**Invariants**

- **Credential scoping**: each adapter subprocess receives **only**
  the environment variables that belong to it. The variables of
  all other adapters are removed via `env -u` before the child
  process is forked. Rationale: if a future adapter accidentally
  leaks or logs its environment (debug flag, error handler), it
  will only expose its own credentials — not the other four
  adapters' secrets.
- `env -u VARNAME` removes the variable from the child's
  environment **without** modifying the parent shell. Every call
  to `dispatch.sh` sees the full set of credentials in its own
  env; only the forked adapter child sees a narrowed view.
- The `readonly _*_ENV_VARS` arrays are the **single source of
  truth** for "which vars belong to which adapter". Adding a new
  credential (e.g. `FTP_TLS`) requires one append to the relevant
  array; every other adapter automatically strips it. A second
  copy of the list in the case arms would drift.
- The group-name dispatch uses a `declare -n` nameref so `_build_strip_args`
  can iterate any group array by name. `unset -n group_ref` at
  the bottom of each loop iteration avoids a subtle bash bug where
  a nameref in a function-local scope can refer to the wrong
  variable on later reuse.
- `_strip_args` is a **global** array, not a stdout return. A
  stdout-based return would drop all shell quoting — `env -u` takes
  `-u VARNAME` pairs as separate argv, and serializing them through
  stdout + `read` would require `eval` and open an injection path.

**Side effects**

- `env`s the adapter subprocess with a narrowed environment.
- Exec's the adapter script.

**Error modes**

| rc | Condition | Characteristic stderr |
|---:|---|---|
| 1 | Unknown adapter | `unknown adapter: <adapter>` |
| * | Adapter subprocess failure | Adapter-specific |

**Example**
```bash
bash lib/dispatch.sh sd /tmp/extract/game1 games/game1
```

**Exemptions**: stub adapter rc semantics (ftp/hdl/rclone) are not
frozen — see `adapters.md`.

### `_build_strip_args`

**Source**: `lib/dispatch.sh:53`
**Visibility**: private
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H2

**Signature**
```
_build_strip_args <keep_array_name>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | keep | string | Name of the `_*_ENV_VARS` array to preserve (e.g. `_FTP_ENV_VARS`). |

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: silent.

**Preconditions**

- The five `readonly _*_ENV_VARS` arrays are defined in the parent
  scope.
- `$1` names one of them exactly.

**Postconditions**

- The global `_strip_args` array has been reset, then populated with
  alternating `-u VAR` tokens, one pair per variable in every
  adapter group **except** the one named by `$1`.
- If `$1` names a group that does not exist in `group_names`, the
  full variable set from all five groups is stripped (no-op on the
  "keep" filter, since no group matches the misspelled name).

**Invariants**

- Uses `declare -n group_ref="$group_name"` to obtain a nameref to
  each group array, then iterates its members. Namerefs are
  function-local and are explicitly `unset -n`'d at the end of
  each iteration to avoid cross-iteration nameref bleed.
- `_strip_args` is a **global** array because stdout-based return
  would drop shell quoting — the consumer needs each `-u` and
  each `VAR` as separate argv tokens for `env`.
- The `readonly _*_ENV_VARS` arrays are treated as the single
  source of truth. This function does NOT hard-code adapter-var
  names; adding a new variable to any group is a one-line append
  to the array.
- Order of output is: every group in `group_names` except `keep`,
  in array order. `env -u` does not care about order, but the
  deterministic ordering makes the H2 assertion easy to write.

**Side effects**

- Resets and populates the global `_strip_args` array.

**Error modes**: none — an unknown `keep` name degrades to
"strip everything", which is a safe over-approximation.

**Example**
```bash
_build_strip_args _FTP_ENV_VARS
env "${_strip_args[@]}" bash "$ROOT_DIR/adapters/ftp.sh" "$src" "$dest"
```
