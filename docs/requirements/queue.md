# Subsystem: Queue

A file-based FIFO backed by `.job` files in a directory. Atomic-mv
rename is the claim primitive: for a single job file, exactly one
concurrent caller wins the `mv` to `<file>.claimed.<BASHPID>`,
everyone else re-tries the next candidate. Two sub-queues are in
use in the pipeline today — `$EXTRACT_QUEUE_DIR` (jobs waiting for
an unzip worker) and `$DISPATCH_QUEUE_DIR` (extracted trees waiting
for a dispatch worker) — but the helpers are queue-dir-agnostic so a
third queue would drop in without code changes.

### `queue_init`

**Source**: `lib/queue.sh:22`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R4

**Signature**
```
queue_init <qdir>
```

| Position | Name | Type          | Constraint                                                          |
| -------: | ---- | ------------- | ------------------------------------------------------------------- |
|       $1 | qdir | absolute path | Must be writable by the current user. May or may not already exist. |

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: `log_enter` line when `DEBUG_IND=1`; otherwise silent.

**Preconditions**

- Caller has write permission on `qdir`'s parent directory (for the
  `mkdir -p` on first run).
- `qdir` is not a symlink pointing outside the expected queue root —
  `_assert_pipeline_dir_safe` should have run first on the enclosing
  `$QUEUE_DIR` to enforce that.

**Postconditions**

- `qdir` exists as a real directory.
- Every `*.job` file inside `qdir` has been deleted (non-recursive).
- Every `*.claimed.*` file inside `qdir` has been deleted.
- Any other file already in `qdir` is **left alone** (e.g.
  `.space_ledger`, `.worker_registry`, and their `.lock` siblings) —
  callers that store sidecar state in the same directory as the
  queue files are not disturbed.

**Invariants**

- Idempotent. Calling `queue_init` twice in a row is safe and
  produces the same state.
- `find -delete` is used instead of `rm -rf *.job` to avoid the
  nullglob ambiguity — a `rm -rf` with no matching glob would try
  to delete the literal `*.job`.
- Only non-recursive cleanup (`-maxdepth 1`). Sub-queues live as
  siblings under `$QUEUE_DIR`, so recursive cleanup would wipe
  neighbouring queues.

**Side effects**

- May create `qdir` via `mkdir -p`.
- Deletes any pre-existing `.job` or `.claimed.*` files inside
  `qdir`.

**Error modes**: none in normal use. A permission failure on
`mkdir -p` or `find -delete` surfaces as a non-zero exit from the
underlying command, which `set -e` in the caller will propagate.

**Example**

```bash
queue_init "$EXTRACT_QUEUE_DIR"
queue_init "$DISPATCH_QUEUE_DIR"
```

### `queue_push`

**Source**: `lib/queue.sh:51`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R4, `test/suites/19_unit_concurrency.sh` Q1/Q3

**Signature**
```
queue_push <qdir> <input_job>
```

| Position | Name      | Type          | Constraint                                                                                                                                            |
| -------: | --------- | ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
|       $1 | qdir      | absolute path | Must already exist and be writable.                                                                                                                   |
|       $2 | input_job | string        | Arbitrary job payload. Typically a `~src\|adapter\|dest~` line but the queue is format-agnostic. Terminating newline is added by `queue_push` itself. |

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: `log_enter` line when `DEBUG_IND=1`; otherwise silent.

**Preconditions**

- `queue_init` has been called on `qdir` at least once (so the
  directory exists).
- `date +%s%N` produces nanosecond-precision output — true on Linux
  coreutils. BusyBox `date` without `%N` would collapse multiple
  pushes per second into the same timestamp; the `.$BASHPID` suffix
  prevents collision but the FIFO order would degrade to "arrival
  order within the same second".

**Postconditions**

- A new file `<nanosec>.<BASHPID>.job` exists inside `qdir`.
- The file contains `$input_job` followed by a single newline.
- Nothing else in `qdir` is modified.

**Invariants**

- Filename format is `<nanosec>.<BASHPID>.job`. The nanosecond
  component gives per-process monotonic ordering; the `BASHPID`
  suffix disambiguates concurrent pushes that hit the same
  nanosecond count.
- `printf '%s\n'` is used, not `echo` — a job line beginning with
  `-n` or `-e` would be interpreted as a flag by `echo` and dropped.
  Jobs today begin with `~` so this is belt-and-braces, but the
  contract still holds.

**Side effects**

- Creates exactly one file in `qdir`.

**Error modes**: none in normal use.

**Example**

```bash
queue_push "$EXTRACT_QUEUE_DIR" "~/iso/game.7z|lvol|games/game~"
```

### `queue_pop`

**Source**: `lib/queue.sh:92`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R4, `test/suites/19_unit_concurrency.sh` Q1/Q2/Q3

**Signature**
```
queue_pop <qdir>
```

| Position | Name | Type          | Constraint  |
| -------: | ---- | ------------- | ----------- |
|       $1 | qdir | absolute path | Must exist. |

**Returns**:

|  rc | Meaning                                                                                                                                                                                                                                                        |
| --: | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0` | Success. The claimed job string is written to stdout (one line, trailing newline).                                                                                                                                                                             |
| `1` | Queue is empty. No `.job` files exist in `qdir` that this caller could claim.                                                                                                                                                                                  |
| `2` | Hard error. The caller won the atomic-mv race but the claimed file could not be read back (`cat` failed). This is specifically **not** "queue empty" — collapsing the two would cause a worker to exit its `while queue_pop` loop with jobs still outstanding. |

**Stdout**: on rc=0, the job string followed by a newline.
**Stderr**: `log_enter` line when `DEBUG_IND=1`; otherwise silent.

**Preconditions**

- `qdir` exists.
- `$BASHPID` is available (bash >= 4.x — guaranteed by
  `check_prerequisites`).

**Postconditions (on rc=0)**

- Exactly one `.job` file has been removed from `qdir`.
- The caller holds the corresponding job string on stdout.
- No `.claimed.<BASHPID>` sidecar remains — the function removes it
  before printing.

**Postconditions (on rc=1)**

- `qdir` is unchanged.

**Postconditions (on rc=2)**

- The `.job` file that was raced for has been consumed (removed,
  then the sidecar cleaned up) but its contents were lost. Callers
  must treat this as a worker-level error, log it, and either
  recover or abort. They must **not** treat rc=2 as an empty queue.

**Invariants**

- The mv-rename is atomic on the same filesystem. Exactly one
  concurrent caller wins per `.job` file.
- Lost the race? The helper does **not** fail — it continues to the
  next candidate in the sorted list. A single failed `mv` only
  eliminates one candidate, never the whole pop attempt. This is
  load-bearing for parallelism under contention: a naive `|| return 1`
  after the `mv` would collapse parallelism by turning one
  lost race into "queue appears empty to this worker".
- Files are walked in sorted order, not glob order. The glob
  expansion is "almost" chronological for `<nanosec>.<pid>.job`
  filenames, but pid wraparound and clock skew can break the
  ordering; `find | sort` gives the reliable FIFO.
- `$BASHPID` is used in the claim suffix, not `$$`. Background
  workers spawned with `&` share `$$` (the parent script's PID),
  which would make every worker's claim suffix identical and break
  the race. `$BASHPID` reflects the real current process.
- Read-then-remove-then-print order is load-bearing under `set -e`:
  if the `cat` failed after the `rm`, the content would be lost
  AND the sidecar orphaned. The current order reads first, cleans
  up unconditionally, and only prints after both succeed.

**Side effects**

- Renames one file (mv).
- Reads one file (cat).
- Removes the renamed file (rm -f).
- On rc=1 or rc=2, no further mutation.

**Error modes**

| rc | Condition                     | Notes                                              |
| --: | ----------------------------- | -------------------------------------------------- |
|  1 | Empty queue                   | Normal loop terminator.                            |
|  2 | Won the claim but read failed | Caller must log and handle; do not treat as empty. |

**Example**

```bash
while job=$(queue_pop "$EXTRACT_QUEUE_DIR"); do
    # ... process $job ...
    :
done
rc=$?
case "$rc" in
    1) log_debug "queue drained normally" ;;
    2) log_error "queue_pop returned corruption rc; bailing out"; exit 1 ;;
esac
```
