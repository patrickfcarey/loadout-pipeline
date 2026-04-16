# Subsystem: Space Ledger

The space ledger is the shared reservation-accounting layer that
keeps N concurrent extract workers from collectively overcommitting
scratch disk. Every reservation is atomic with respect to sibling
reservations because the full "read ledger → call df → decide →
append" sequence runs inside an exclusive `flock` on
`$QUEUE_DIR/.space_ledger.lock`.

Two subtle design points shape every function in this file:

- **Phantom GC.** A worker SIGKILL'd mid-reservation cannot run its
  EXIT trap and therefore never calls `space_release`. Its ledger
  row would otherwise permanently count against capacity. Every
  ledger row carries the worker's BASHPID as the 6th field, and
  `space_reserve` runs a phantom-eviction pass inside the lock before
  deciding whether a new reservation fits.
- **Same-filesystem pooling.** When `COPY_DIR` and `EXTRACT_DIR`
  share a mount (same `stat -c %d` device number), they are pooled
  against a single `df` number. Otherwise each is accounted for on
  its own device. Suite 16 H5/H6 pin the device-id walker and the
  per-device sum.

**Ledger row format** (space-separated, one reservation per line):

```
<id> <copy_dev> <copy_bytes> <extract_dev> <extract_bytes> <owner_pid>
```

**Test hook**: `SPACE_AVAIL_OVERRIDE_BYTES` — when set, replaces the
real `df` call inside `_space_avail_bytes`, so tests can simulate a
small filesystem without tmpfs privileges. **Not frozen** — see the
compat policy.

### `_space_ledger_path`

**Source**: `lib/space.sh:99`
**Visibility**: private
**Test coverage**: none — not currently asserted directly, but exercised indirectly by every other `lib/space.sh` function.

**Signature**
```
_space_ledger_path
```

Takes no arguments.

**Returns**: `0` always.
**Stdout**: `$QUEUE_DIR/.space_ledger` (no trailing newline).
**Stderr**: silent.

**Preconditions**: `$QUEUE_DIR` is set.

**Postconditions**: none beyond the stdout print.

**Invariants**

- The only place in the codebase that decides **where** the ledger
  lives. Every `space_*` helper calls this to resolve the path
  instead of hard-coding the string, so a future relocation only
  needs this one line touched.
- Uses `printf '%s'` (no trailing newline) so
  `ledger="$(_space_ledger_path)"` does not pick up a stray `\n`
  that would corrupt filename comparisons.

**Side effects**: none.

**Error modes**: none.

**Example**
```bash
ledger="$(_space_ledger_path)"   # => /tmp/iso_pipeline_queue/.space_ledger
```

### `_space_lock_path`

**Source**: `lib/space.sh:100`
**Visibility**: private
**Test coverage**: none — not currently asserted directly; exercised indirectly by `space_reserve` / `space_release`.

**Signature**
```
_space_lock_path
```

Takes no arguments.

**Returns**: `0` always.
**Stdout**: `$QUEUE_DIR/.space_ledger.lock` (no trailing newline).
**Stderr**: silent.

**Preconditions**: `$QUEUE_DIR` is set.

**Postconditions**: none beyond the stdout print.

**Invariants**

- Separate file from the ledger itself. `flock`-ing the ledger file
  would conflict with `mv` replacing it (as `space_release` does),
  so the lock is a dedicated sibling file.
- Same one-source-of-truth discipline as `_space_ledger_path`.

**Side effects**: none.

**Error modes**: none.

**Example**
```bash
lock="$(_space_lock_path)"
( flock -x 9; ... ) 9>"$lock"
```

### `space_init`

**Source**: `lib/space.sh:118`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R6, `test/suites/05_space_ledger.sh`

**Signature**
```
space_init
```

Takes no arguments.

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: silent.

**Preconditions**

- `$QUEUE_DIR` is set (guaranteed by `lib/config.sh`).

**Postconditions**

- `$QUEUE_DIR` exists.
- `$QUEUE_DIR/.space_ledger` exists and is empty.
- `$QUEUE_DIR/.space_ledger.lock` exists and is empty.

**Invariants**

- `rm -f` is called on each path **before** the `: >` creates the
  new empty file. This is a security measure: if a malicious actor
  planted a symlink at either path, `rm -f` removes the symlink
  itself (not its target), and the subsequent `: >` creates a fresh
  regular file owned by the current user. Using `: > "$path"` alone
  would write through the symlink into the attacker-controlled
  destination.
- Called **once per pipeline run**, at the top of `workers_start`.
  Any stale entry from a SIGKILL'd previous run is erased, so
  phantoms never leak across runs. Within-run phantoms are handled
  by `_space_ledger_gc_phantoms` — this function does not care
  about them.
- Idempotent. Calling twice in a row leaves the same state.

**Side effects**

- May create `$QUEUE_DIR`.
- Creates/truncates `$QUEUE_DIR/.space_ledger` and its `.lock` sibling.

**Error modes**: none in normal use. A permission failure inside
`mkdir -p` or the `rm -f` / `: >` propagates the command's own non-zero
exit code, which `set -e` in the caller handles.

**Example**
```bash
# At the top of workers_start:
space_init
```

### `_space_dev`

**Source**: `lib/space.sh:146`
**Visibility**: private
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H5

**Signature**
```
_space_dev <path>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | path | directory path | Need not exist yet. |

**Returns**: `0` always.
**Stdout**: numeric device ID from `stat -c %d`, or `0` on error.
**Stderr**: silent.

**Preconditions**: `stat` is on `$PATH` (guaranteed by
`check_prerequisites`).

**Postconditions**: pure read.

**Invariants**

- Walks up the directory tree with `${p%/*}` until an existing
  ancestor is found. The target directory may not exist yet on the
  first reservation against it; walking up to the parent gives the
  device number of the filesystem it will land on.
- The walk has a guard for relative paths with no slash: `${p%/*}`
  on `"foo"` returns `"foo"` unchanged (pattern does not match),
  which would spin forever. The guard detects the unchanged case
  and falls back to `.` (the CWD) before calling `stat`.
- Empty-path guard: if the walk strips the last component to an
  empty string, it falls back to `/`.
- Prints `0` on any `stat` failure rather than aborting. Callers
  that see dev=0 on both copy and extract dirs still treat them as
  "same filesystem" and pool; the worst-case is an over-conservative
  reservation decision, never an over-commit.

**Side effects**: calls `stat -c %d` on exactly one path.

**Error modes**: `stat` failure falls through to the `echo 0` safety
net.

**Example**
```bash
cdev="$(_space_dev "$COPY_DIR")"
edev="$(_space_dev "$EXTRACT_DIR")"
if [[ "$cdev" == "$edev" ]]; then ...; fi
```

### `_space_avail_bytes`

**Source**: `lib/space.sh:185`
**Visibility**: private
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H4

**Signature**
```
_space_avail_bytes <path>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | path | directory path | Need not exist yet. |

**Returns**: `0` always.
**Stdout**: a decimal byte count (from `df --output=avail -B1 | tail -n1 | tr -d ' '`),
or the override value, or empty on a hard `df` failure.
**Stderr**: silent.

**Preconditions**: `df` and `tail` and `tr` are on `$PATH`.

**Postconditions**: pure read.

**Invariants**

- Honours `SPACE_AVAIL_OVERRIDE_BYTES` as a test hook. When that
  variable is set (even to `0`), its value is returned verbatim and
  `df` is not called. Suite 16 H4 pins this.
- Same walk-up-to-existing-ancestor logic as `_space_dev`, including
  the unchanged-path guard.
- Unit-scale is bytes (`-B1`), never kibibytes — callers rely on
  the integer byte count to compare directly against archive sizes
  and extracted sizes from `stat -c %s` / `du -sb`.
- `tr -d ' '` strips the whitespace `df` emits in column output; the
  result is a plain integer suitable for arithmetic expansion.
- `| tail -n1` drops the header row from `df`'s column output.
- Empty stdout is possible on a `df` hard failure (the `tail | tr`
  pipeline runs anyway). Callers are expected to re-check with a
  `[[ ! "$avail" =~ ^[0-9]+$ ]]` regex and treat non-numeric output
  as "no fit right now" — `space_reserve` does exactly this.

**Side effects**: one `df` call per invocation (unless overridden).

**Error modes**: empty stdout is the only failure signal. Callers
validate numerically.

**Exemptions**

- `SPACE_AVAIL_OVERRIDE_BYTES` is a test hook. **Not frozen.**

**Example**
```bash
avail="$(_space_avail_bytes "$COPY_DIR")"
if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
    log_warn "df returned non-numeric; treating as no-fit"
    exit 1
fi
```

### `_space_reserved_on_dev`

**Source**: `lib/space.sh:228`
**Visibility**: private
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H6

**Signature**
```
_space_reserved_on_dev <dev> <mode>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | dev | integer | Device ID from `stat -c %d`. |
| $2 | mode | keyword | One of `copy`, `extract`, `both`. |

**Returns**: `0` always.
**Stdout**: a decimal byte count — `0` if the ledger is missing or
no row matches.
**Stderr**: silent.

**Preconditions**: `awk` is available.

**Postconditions**: pure read.

**Invariants**

- Mode `copy` sums field 3 (copy_bytes) on every row where field 2
  (copy_dev) equals `dev`.
- Mode `extract` sums field 5 (extract_bytes) on every row where
  field 4 (extract_dev) equals `dev`.
- Mode `both` is the pooled case — on each row, if copy_dev equals
  `dev`, add copy_bytes; if extract_dev equals `dev`, add
  extract_bytes. Both conditions may fire on the same row (same
  device on both columns), in which case the row contributes
  copy_bytes + extract_bytes. This is load-bearing for the shared-FS
  code path in `space_reserve`.
- Missing ledger returns `0` via the `[[ -f $ledger ]]` guard, not
  an awk error.
- Uses `sum+0` in the END block so an empty file still prints `0`
  rather than an empty line.

**Side effects**: one `awk` pass over the ledger per call.

**Error modes**: none — a corrupt line (too few fields) silently
contributes zero to the sum.

**Example**
```bash
# In space_reserve's shared-FS branch:
total_reserved="$(_space_reserved_on_dev "$cdev" both)"
```

### `_space_apply_overhead`

**Source**: `lib/space.sh:264`
**Visibility**: private
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H3

**Signature**
```
_space_apply_overhead <bytes>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | bytes | integer | Non-negative. |

**Returns**: `0` always.
**Stdout**: `$(( bytes * (100 + SPACE_OVERHEAD_PCT) / 100 ))`.
**Stderr**: silent.

**Preconditions**: `SPACE_OVERHEAD_PCT` is set (default 20 via
`lib/config.sh`) and non-negative.

**Postconditions**: pure integer math.

**Invariants**

- Integer math only. No decimals, no floating point. Bash arithmetic
  expansion truncates, so a `bytes * 100 / 100` on the exact path
  returns `bytes` unchanged.
- `SPACE_OVERHEAD_PCT=0` is valid and returns `bytes` unchanged.
  Suite 16 H3 pins this.
- Overflow: integer `bytes * 150` fits in bash's signed 64-bit
  arithmetic for any sane archive size, so no overflow guard is
  needed.

**Side effects**: none.

**Error modes**: none.

**Example**
```bash
need="$(_space_apply_overhead $(( cbytes + ebytes )))"
# With SPACE_OVERHEAD_PCT=20: 1000000 bytes -> 1200000 bytes
```

### `_space_ledger_gc_phantoms`

**Source**: `lib/space.sh:292`
**Visibility**: private
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H7

**Signature**
```
_space_ledger_gc_phantoms
```

Takes no arguments.

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: silent.

**Preconditions**

- Caller **must** hold the exclusive flock on `_space_lock_path`.
  This function is not safe to call outside the lock — it rewrites
  the ledger file in place, and a concurrent append would clobber
  the tmp file or race the `mv`.
- `awk` is available.

**Postconditions**

- Every ledger row whose field 6 (owner PID) does not pass
  `kill -0` has been removed.
- Rows whose owner PID is still alive are preserved verbatim.

**Invariants**

- Atomic rewrite via `awk > $tmp && mv $tmp $ledger`. If the awk
  fails, the `mv` is skipped and the stale ledger is left intact.
- Defence-in-depth on awk's `system()` call: the 6th field is
  validated against `^[0-9]+$` **before** being interpolated into
  `system("kill -0 " $6)`. A corrupt ledger row with a non-numeric
  PID field is treated as "dead" (dropped from the output). This
  prevents any command-injection vector if someone managed to
  smuggle a malicious string into the ledger.
- A worker whose reservation was successfully released between the
  caller reading the ledger and this function running is still
  preserved, because it has already been removed by `space_release`
  earlier.
- Bail-out on missing / empty ledger — no awk invocation, no temp
  file. This is both a performance optimization and a correctness
  guarantee: an empty ledger has no phantoms to evict.

**Side effects**

- Rewrites `$QUEUE_DIR/.space_ledger` in place via a sibling tmp
  file and an atomic `mv`.
- Forks one `awk`, which forks one `kill -0` per ledger row via
  `system()`.

**Error modes**: none — awk errors fall through to `rm -f $tmp`.

**Example**
```bash
# Inside space_reserve's flock subshell:
_space_ledger_gc_phantoms
```

### `space_reserve`

**Source**: `lib/space.sh:353`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R6, `test/suites/05_space_ledger.sh`, `test/suites/16_unit_lib_helpers.sh` H4/H5/H6/H7 (sub-helpers)

**Signature**
```
space_reserve <id> <copy_dir> <copy_bytes> <extract_dir> <extract_bytes>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | id | string | Unique reservation key; `space_release` uses this to find the row later. Convention: `extract.$BASHPID.<nonce>`. |
| $2 | copy_dir | directory path | Scratch directory where the copied archive will land. |
| $3 | copy_bytes | integer | Archive size in bytes (from `stat -c %s`). |
| $4 | extract_dir | directory path | Directory where 7z will write extracted members. |
| $5 | extract_bytes | integer | Sum of uncompressed member sizes (from `7z l`). |

**Returns**:

| rc | Meaning |
|---:|---|
| `0` | Reservation committed. Caller may proceed with copy + extract. |
| `1` | Does not fit right now. Caller should sleep and retry, OR fast-fail if `space_ledger_empty` says no siblings hold space. |

**Stdout**: silent.
**Stderr**: silent on success. On a non-numeric `df` result, a single
`log_warn` line: `space_reserve: df returned non-numeric for <dir> — treating as no-fit` or `space_reserve: df returned non-numeric — treating as no-fit`.

**Preconditions**

- `$QUEUE_DIR` is set.
- `log_warn` is defined.
- `_space_dev`, `_space_avail_bytes`, `_space_reserved_on_dev`,
  `_space_apply_overhead`, `_space_ledger_gc_phantoms` are all
  defined (same file).

**Postconditions (on rc=0)**

- One new row appended to `$QUEUE_DIR/.space_ledger`:
  `<id> <cdev> <cbytes> <edev> <ebytes> <owner_pid>`.
- The ledger no longer contains phantom entries from dead siblings
  (the GC pass ran inside the lock).

**Postconditions (on rc=1)**

- Ledger unchanged.

**Invariants**

- Full critical section runs inside `flock -x 9` on
  `_space_lock_path`. The subshell that holds the lock does:
  1. `_space_ledger_gc_phantoms`
  2. `df`-via-`_space_avail_bytes`
  3. Per-device or pooled arithmetic
  4. Append (on success) or `exit 1` (on no-fit).
- `owner_pid` is captured **outside** the flock subshell. Inside the
  subshell, `$BASHPID` is the subshell's own PID, not the worker's.
  Using the subshell PID would make every ledger row reference a
  PID that died as soon as the subshell exited, and every reservation
  would be evicted as a phantom on the next `space_reserve` call.
- `cdev == edev` → **pooled** path. One `df`, one
  `_space_reserved_on_dev ... both`. This is the common case on
  single-disk hosts.
- `cdev != edev` → **independent** path. Two `df` calls, two
  reserved-on-dev sums, two fit checks. Either failing the fit
  check aborts with rc=1.
- Overhead is applied via `_space_apply_overhead` to the raw byte
  sums before comparison. `SPACE_OVERHEAD_PCT=0` disables the
  padding entirely.
- Non-numeric `df` output is treated as "no fit right now", not as
  an error, so a transient `df` hiccup does not abort the whole
  pipeline.
- Does **not** call `space_release` on its own. Callers must register
  an EXIT trap that calls `space_release "$id"` to unwind the
  reservation on success, error, or SIGTERM. SIGKILL leaks the row
  until either a sibling `space_reserve` GC sweep evicts it, or
  the next `space_init` wipes the ledger.

**Side effects**

- Acquires `flock -x` on `$QUEUE_DIR/.space_ledger.lock`.
- May rewrite `$QUEUE_DIR/.space_ledger` (via the inner GC pass).
- Appends one row on success.
- Forks for `df`, `awk`, `stat`, and `kill -0` (via the GC pass).

**Error modes**

| rc | Condition | Characteristic stderr |
|---:|---|---|
| 1 | Pooled or independent fit check fails | silent |
| 1 | `df` returned non-numeric | `space_reserve: df returned non-numeric ...` via `log_warn` |

**Exemptions**

- `SPACE_AVAIL_OVERRIDE_BYTES` bypasses `df` via
  `_space_avail_bytes`. **Not frozen.**

**Example**
```bash
if space_reserve "extract.$BASHPID.$id" "$COPY_DIR" "$archive_bytes" \
                  "$EXTRACT_DIR" "$extracted_bytes"; then
    # ... do the copy + extract ...
    :
else
    if space_ledger_empty; then
        log_error "archive does not fit on this filesystem"
        exit 1
    fi
    sleep "$retry_sec"
fi
```

### `space_release`

**Source**: `lib/space.sh:428`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R6, `test/suites/05_space_ledger.sh`

**Signature**
```
space_release <id>
```

| Position | Name | Type | Constraint |
|---:|---|---|---|
| $1 | id | string | Same key that was passed to `space_reserve`. |

**Returns**: `0` always.
**Stdout**: silent.
**Stderr**: silent.

**Preconditions**

- `$QUEUE_DIR` is set.
- `awk` is available.

**Postconditions**

- Every row whose field 1 matches `$id` has been removed from the
  ledger.
- Other rows are preserved verbatim.

**Invariants**

- Full critical section runs inside `flock -x 9`, same lock as
  `space_reserve`. A concurrent `space_reserve` from another worker
  blocks until this release finishes.
- A missing ledger is a no-op, not an error. This keeps the EXIT
  trap in `extract.sh` safe to call even if `space_init` is yet to
  run (e.g. on a test that skips the real worker startup).
- Works via `awk '$1 != id' > $tmp && mv $tmp $ledger`. If awk
  fails, the tmp file is removed and the ledger is left intact.
  This is a conservative failure mode: stale rows get GC'd by the
  next `space_reserve` call anyway.
- `mv` is atomic within the same directory, so concurrent readers
  (like `space_ledger_empty`) either see the old or new file, never
  a partial rewrite.
- Matching is by field 1 exact comparison. A row with a leading
  space (corrupt) would not match; it would leak as a phantom to
  be GC'd later by PID.

**Side effects**

- Acquires `flock -x`.
- Rewrites the ledger via sibling tmp + `mv`.

**Error modes**: none.

**Example**
```bash
trap 'space_release "$SPACE_ID"' EXIT
```

### `space_ledger_empty`

**Source**: `lib/space.sh:472`
**Visibility**: public
**Test coverage**: `test/suites/15_unit_runtime.sh` R6, `test/suites/05_space_ledger.sh`

**Signature**
```
space_ledger_empty
```

Takes no arguments.

**Returns**:

| rc | Meaning |
|---:|---|
| `0` | Ledger is effectively empty — missing, zero-size, or every row is a phantom (owner PID no longer alive). |
| `1` | At least one row has a live owner PID. |

**Stdout**: silent.
**Stderr**: silent.

**Preconditions**: `$QUEUE_DIR` is set.

**Postconditions**: pure read.

**Invariants**

- **Lock-free** by design. `space_reserve` already ran a GC pass
  inside its lock moments before this is called, so phantoms are
  almost always already gone. A concurrent `space_reserve` from
  another worker could append a new row between this read and the
  caller's decision; in the worst case that causes one extra retry
  sleep in the caller, never silent data loss.
- Treats phantoms as absent so the retry backoff in
  `_unzip_handle_job` can fast-fail correctly after a SIGKILL storm,
  instead of waiting forever on reservations that will never be
  released.
- Missing file → `return 0` (empty).
- Zero-size file → `return 0` (empty). The `[[ -s $ledger ]]` guard
  avoids even opening the read loop in that case.
- Field 6 is the owner PID. An empty PID line (malformed row) is
  silently skipped; the helper does not count it as live.

**Side effects**

- Reads the ledger line by line.
- Forks one `kill -0` per line (until the first live owner is
  found, at which point the function short-circuits).

**Error modes**: none.

**Example**
```bash
if ! space_reserve "$id" ...; then
    if space_ledger_empty; then
        log_error "archive too big for this filesystem; giving up"
        exit 1
    fi
    sleep "$backoff_sec"
fi
```
