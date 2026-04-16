# Subsystem: Worker Registry

`queue_pop` removes a job from the queue atomically before any work
begins. If a worker is SIGKILL'd mid-job, the job simply vanishes
unless someone remembers it. The worker registry is that someone:
each worker writes its current job string here when it starts
processing and removes it when it finishes. After every extract
worker has exited, anything still in the registry was abandoned
mid-flight, and `_recover_orphans` re-queues those entries for a
recovery pass.

**Registry row format**: one line per active job.

```
<owner_pid> <job_string>
```

A single space separates the pid from the job, and job strings
start with `~` and cannot contain newlines, so "everything after the
first space" is unambiguously the full job string.

All mutations are guarded by an exclusive flock on
`$QUEUE_DIR/.worker_registry.lock`.

### `_wr_path`

**Source**: `lib/worker_registry.sh:52`
**Visibility**: private
**Test coverage**: none — not currently asserted directly; exercised indirectly by every other registry helper.

**Signature**
```
_wr_path
```

Takes no arguments.

**Returns**: `0` always.
**Stdout**: `$QUEUE_DIR/.worker_registry` (no trailing newline).
**Stderr**: silent.

**Preconditions**: `$QUEUE_DIR` is set.

**Postconditions**: pure string print.

**Invariants**

- Single source of truth for the registry file path. Every
  `worker_job_*` helper calls this rather than hard-coding the path.
- No trailing newline — callers use `reg="$(_wr_path)"` and need a
  clean string.

**Side effects**: none.

**Error modes**: none.

**Example**
```bash
reg="$(_wr_path)"
```

### `_wr_lock_path`

**Source**: `lib/worker_registry.sh:53`
**Visibility**: private
**Test coverage**: none — not currently asserted directly.

**Signature**
```
_wr_lock_path
```

Takes no arguments.

**Returns**: `0` always.
**Stdout**: `$QUEUE_DIR/.worker_registry.lock` (no trailing newline).
**Stderr**: silent.

**Preconditions**: `$QUEUE_DIR` is set.

**Postconditions**: pure string print.

**Invariants**

- Lock file is a sibling of the registry, not the registry itself —
  registry rewrites happen via `awk > tmp && mv tmp registry`, and
  flock-ing a file that gets replaced by `mv` would lose the lock
  guarantee.

**Side effects**: none.

**Error modes**: none.

**Example**
```bash
lock="$(_wr_lock_path)"
```

### `worker_registry_init`

**Source**: `lib/worker_registry.sh:69`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R5, `test/suites/06_worker_registry.sh`

**Signature**
```
worker_registry_init
```

Takes no arguments.

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: silent.

**Preconditions**: `$QUEUE_DIR` is set.

**Postconditions**

- `$QUEUE_DIR` exists.
- `$QUEUE_DIR/.worker_registry` exists and is empty.
- `$QUEUE_DIR/.worker_registry.lock` exists and is empty.

**Invariants**

- Called at the top of every pipeline run and before every
  recovery pass, so stale rows from a SIGKILL'd previous run never
  leak into a new run.
- `rm -f` before `: >` severs any pre-planted symlink at either
  path (same pattern as `space_init`). An attacker who managed to
  plant a symlink at `.worker_registry` would otherwise have their
  target file written to.
- Idempotent.

**Side effects**

- May create `$QUEUE_DIR`.
- Truncates registry and lock files.

**Error modes**: none in normal use.

**Example**
```bash
# At the top of workers_start:
worker_registry_init
```

### `worker_job_begin`

**Source**: `lib/worker_registry.sh:104`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R5, `test/suites/06_worker_registry.sh`, `test/suites/19_unit_concurrency.sh` R7 (two concurrent begins for the same pid)

**Signature**
```
worker_job_begin <pid> <job>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | pid | integer | Must be `$BASHPID` of the current worker, **not** `$$` (see invariants). |
| $2 | job | string | Full job line including the leading and trailing `~`. No newlines. |

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: silent.

**Preconditions**

- `worker_registry_init` has run at least once.
- `$QUEUE_DIR` is set.

**Postconditions**

- Exactly one row for `pid` exists in the registry after this call,
  carrying `job` as its payload.
- Any pre-existing row for the same `pid` has been removed first.

**Invariants**

- Must pass `$BASHPID`, not `$$`. Workers spawned with `&` share
  the parent script's `$$`, so using `$$` would make every worker
  overwrite the same registry row — a SIGKILL recovery would see
  only the last-written job and silently drop every other
  in-flight job.
- "Remove stale row for pid, then append" is atomic under the flock.
  Suite 19 R7 pins this: two concurrent `worker_job_begin` calls
  for the same pid never leave two rows in the registry.
- Uses `awk '$1 != pid'` to filter stale rows, then appends with
  `printf '%s %s\n' "$pid" "$job"`. The awk-vs-append ordering is
  important: a naive "append then dedupe" would leave a second row
  in the registry if the awk step failed.
- Tmp-file + `mv` pattern with error recovery: a failed awk removes
  the tmp file rather than leaving an orphan in `$QUEUE_DIR`.

**Side effects**

- Acquires `flock -x 9` on `$QUEUE_DIR/.worker_registry.lock`.
- Rewrites (and appends to) `$QUEUE_DIR/.worker_registry`.

**Error modes**: none in normal use. An awk or mv failure falls
through to a `rm -f $tmp` and the registry is left intact (the new
row is still appended).

**Example**
```bash
worker_job_begin "$BASHPID" "$job"
# ... run the job ...
worker_job_end "$BASHPID"
```

### `worker_job_end`

**Source**: `lib/worker_registry.sh:143`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R5, `test/suites/06_worker_registry.sh`

**Signature**
```
worker_job_end <pid>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | pid | integer | Same `$BASHPID` that was passed to `worker_job_begin`. |

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: silent.

**Preconditions**: `$QUEUE_DIR` is set.

**Postconditions**

- No row for `pid` exists in the registry.
- Other rows are preserved verbatim.

**Invariants**

- Missing registry file is a no-op (early return via `[[ -f ]]`
  guard). This keeps the helper safe to call from cleanup paths
  even if the registry was never initialized in a test harness.
- Awk tmp + mv pattern. A missing row is not an error — `awk '$1 != pid'`
  on a row-less registry produces an empty file, which
  replaces the (also empty) registry.
- Same flock as `worker_job_begin`, so a concurrent begin/end pair
  for different pids is safe.
- Always call in the EXIT trap of the worker so a clean exit,
  abort, or re-queue all drop the row. SIGKILL is the only failure
  mode that cannot call this — that is exactly what
  `worker_registry_recover` exists for.

**Side effects**

- Acquires `flock -x 9`.
- Rewrites the registry via tmp + mv.

**Error modes**: none — awk failure leaves the registry intact.

**Example**
```bash
trap 'worker_job_end "$BASHPID"' EXIT
```

### `worker_registry_recover`

**Source**: `lib/worker_registry.sh:178`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R5, `test/suites/06_worker_registry.sh`, `test/suites/04_failure_handling.sh` (SIGKILL end-to-end)

**Signature**
```
worker_registry_recover
```

Takes no arguments.

**Returns**: `0` always.
**Stdout**: one line per recovered job — the original job string
without the `<pid>` prefix. Empty registry produces no output.
**Stderr**: silent.

**Preconditions**: `$QUEUE_DIR` is set.

**Postconditions**

- The registry file is truncated to empty.
- Every recovered job has been written to stdout, one per line, in
  the order they appeared in the file.

**Invariants**

- Uses `awk '{ i = index($0, " "); if (i > 0) print substr($0, i + 1) }'`
  to strip the `<pid>` prefix. This is a **load-bearing** choice:
  the naive `{ $1=""; sub(/^ /,""); print }` form causes awk to
  rebuild `$0` using `OFS` (default single space), which would
  collapse runs of whitespace anywhere in the job string. A job
  path containing two consecutive spaces would come back with one
  space and would then fail to re-queue correctly.
- `substr` is byte-exact: the output is the original line from the
  registry with the first space and everything before it removed.
- Truncation happens inside the flock subshell, so a concurrent
  `worker_job_begin` from a surviving worker blocks until the
  truncation completes. In practice this is only called from
  `_recover_orphans` **after** all workers have already exited,
  so there is nothing to block.
- Missing registry is a no-op (early return via `[[ -f ]]` guard).

**Side effects**

- Acquires `flock -x 9`.
- Reads the registry line by line via awk.
- Removes and re-creates the registry file (`rm -f -- "$reg"; : > "$reg"`).

**Error modes**: none.

**Example**
```bash
while IFS= read -r leftover_job; do
    queue_push "$EXTRACT_QUEUE_DIR" "$leftover_job"
done < <(worker_registry_recover)
```
