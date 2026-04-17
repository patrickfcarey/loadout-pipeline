# Subsystem: Bootstrap

Covers everything that runs before a single job line is parsed: the
`.env` loader and numeric-config validator in `lib/config.sh`, the
logging framework in `lib/logging.sh`, the prerequisite check in
`lib/prereq.sh`, the working-directory safety validator in
`lib/init.sh`, and the `bin/loadout-pipeline.sh` entry point that
sources them all.

All functions in this doc run in the parent shell before any worker
fork, so they have no concurrency concerns — their contract is with
the single operator process and with `exit` as the primary failure
channel.

## Script contract: `bin/loadout-pipeline.sh`

**Source**: `bin/loadout-pipeline.sh:1`
**Test coverage**: `test/suites/02_core_pipeline.sh` (end-to-end smoke), `test/suites/13_prereq.sh` P5 (ordering), `test/suites/04_failure_handling.sh` (SIGKILL recovery)

**Invocation**

```
bin/loadout-pipeline.sh [<jobs_file>]
```

| Position | Name      | Type | Constraint                                                                                                                                                                         |
| -------: | --------- | ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|       $1 | jobs_file | path | Optional. Either a regular file in `~src\|adapter\|dest~` format, or a directory containing one or more `*.jobs` files. Defaults to `$ROOT_DIR/examples/example.jobs` when absent. |

**Returns**: `0` on clean completion of every job; non-zero on any
fatal startup failure. Per-job failures are logged but do not
short-circuit the pipeline — surviving workers continue and the
process exits 0 as long as the orchestrator itself completes.

**Source order** (deliberate — load-time side effects depend on it):

1. `lib/config.sh` — `.env` parse, numeric validation, `export` every
   tunable. Sets `DEBUG_IND`, `QUEUE_DIR`, `EXTRACT_DIR`, `COPY_DIR`,
   and every adapter env var. **Must precede `logging.sh`** because
   `logging.sh`'s RETURN trap decision depends on `DEBUG_IND` being
   set.
2. `lib/logging.sh` — `log_*` helpers and the `DEBUG_IND=1` RETURN
   trap installer.
3. `lib/prereq.sh` — `check_prerequisites` definition.
4. `lib/init.sh` — `_assert_pipeline_dir_safe` + `init_environment`.
5. `lib/jobs.sh`, `lib/queue.sh`, `lib/workers.sh` — higher layers
   that depend on the four files above.

After sourcing, the script calls (in order):

1. `check_prerequisites` — exits 1 on any missing binary.
2. `init_environment` — exits 1 on any unsafe working dir.
3. `load_jobs "$JOBS_FILE"` — populates the global jobs list.
4. `workers_start` — the main run loop.
5. `log_info "All jobs completed!"`.

**Env dependencies**

Every variable declared in `lib/config.sh`. The entry script itself
reads only `$1` from argv and `$ROOT_DIR` (set at the top of the
script from `BASH_SOURCE[0]`).

**Postconditions (on rc=0)**

- Every job in `$JOBS_FILE` has either been successfully adapted or
  logged as failed with a characteristic error message.
- `$EXTRACT_DIR`, `$COPY_DIR`, and `$QUEUE_DIR` are swept of
  leftover scratch state for completed jobs.
- No orphaned worker processes remain.

**Error modes**

| rc | Condition                                         | Where                       |
| --: | ------------------------------------------------- | --------------------------- |
|  1 | Missing prereq binary                             | `check_prerequisites`       |
|  1 | Unsafe working directory (symlink, wrong owner)   | `_assert_pipeline_dir_safe` |
|  2 | Invalid numeric config (e.g. `MAX_UNZIP=0`)       | `lib/config.sh` validator   |
|  2 | `DISPATCH_POLL_INITIAL_MS > DISPATCH_POLL_MAX_MS` | `lib/config.sh` validator   |

**Example**

```bash
DEBUG_IND=1 MAX_UNZIP=4 MAX_DISPATCH=2 \
    bin/loadout-pipeline.sh ./my.jobs
```

---

## `lib/config.sh`

`lib/config.sh` has no function definitions — it is executed as a
sourced script and runs a `.env` loader, a pile of `export VAR=default`
fallbacks, and three numeric-validation `for` loops. It is documented
here as a script contract because its behavior is part of the frozen
public interface and because suite 18 pins it directly.

### Script contract: `lib/config.sh`

**Source**: `lib/config.sh:1`
**Test coverage**: `test/suites/18_unit_config_jobs_edges.sh` C1–C5 (`.env` edge cases and numeric validation)

**Invocation**

```
source "$ROOT_DIR/lib/config.sh"
```

Must be the **first** file sourced by `bin/loadout-pipeline.sh` so
later files can rely on all env vars being set. Requires `$ROOT_DIR`
to be set in the caller's environment.

**Env dependencies** (read before defaulting)

- Every variable listed in the "frozen env var surface" of the compat
  policy, including `DEBUG_IND`, `RESUME_PLANNER_IND`, `MAX_UNZIP`,
  `MAX_DISPATCH`, `SCRATCH_DISK_DIR`, `QUEUE_DIR`, `EXTRACT_QUEUE_DIR`, `DISPATCH_QUEUE_DIR`,
  `EXTRACT_DIR`, `COPY_DIR`, `SPACE_OVERHEAD_PCT`,
  `FTP_*`, `HDL_DUMP_BIN`, `LVOL_MOUNT_POINT`, `RCLONE_*`, `RSYNC_*`,
  `MAX_RECOVERY_ATTEMPTS`, `DISPATCH_POLL_INITIAL_MS`,
  `DISPATCH_POLL_MAX_MS`, `EXTRACT_STRIP_LIST`,
  `SPACE_RETRY_BACKOFF_INITIAL_SEC`, `SPACE_RETRY_BACKOFF_MAX_SEC`.
- `$ROOT_DIR/.env` — optional; if present, parsed line by line.

**Preconditions**

- `$ROOT_DIR` is set by the caller to the repo root.
- `$ROOT_DIR/.env` (if present) is a text file of `KEY=value` lines.

**Postconditions**

- Every env var in the list above is exported, with caller-supplied
  values taking priority over `.env` values taking priority over
  built-in defaults.
- All integer vars (`MAX_UNZIP`, `MAX_DISPATCH`,
  `MAX_RECOVERY_ATTEMPTS`, `DISPATCH_POLL_*`) are `>= 1`.
- `SPACE_OVERHEAD_PCT` is `>= 0`.
- Decimal-allowed vars (`SPACE_RETRY_BACKOFF_*`) match
  `^[0-9]+(\.[0-9]+)?$`.
- `DISPATCH_POLL_INITIAL_MS <= DISPATCH_POLL_MAX_MS`.

**Invariants**

- The `.env` loader never overwrites an env var that was already
  set in the caller's environment. `MAX_UNZIP=4 bin/loadout-pipeline.sh`
  always wins over a `MAX_UNZIP=8` line in `.env`.
- `.env` lines containing `=` but with non-identifier keys are
  silently skipped, not treated as errors. Comments and blank lines
  are skipped.
- A `.env` file with group/other read permissions triggers a warning
  on stderr but does not abort the run.
- CRLF line endings in `.env` are tolerated (trailing `\r` is
  stripped from each line).

**Side effects**

- Exports all the env vars listed above.
- Writes a single warning line to stderr if `.env` is
  group/other-readable.
- Exits `2` on any numeric-validation failure with a `[config] ERROR:
  <VAR> must be ...` message.

**Error modes**

| rc | Condition                                                                                         | Characteristic stderr                                                                       |
| --: | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
|  2 | `MAX_UNZIP` / `MAX_DISPATCH` / `MAX_RECOVERY_ATTEMPTS` / `DISPATCH_POLL_*` not a positive integer | `[config] ERROR: <VAR> must be a positive integer, got '<val>'`                             |
|  2 | `SPACE_OVERHEAD_PCT` not a non-negative integer                                                   | `[config] ERROR: SPACE_OVERHEAD_PCT must be a non-negative integer, got '<val>'`            |
|  2 | `SPACE_RETRY_BACKOFF_*` not a non-negative number                                                 | `[config] ERROR: <VAR> must be a non-negative number, got '<val>'`                          |
|  2 | `DISPATCH_POLL_INITIAL_MS > DISPATCH_POLL_MAX_MS`                                                 | `[config] ERROR: DISPATCH_POLL_INITIAL_MS (<i>) must not exceed DISPATCH_POLL_MAX_MS (<m>)` |

**Example**

```bash
# Loaded implicitly by the entry script
source "$ROOT_DIR/lib/config.sh"
echo "$MAX_UNZIP"   # always a positive integer after this point
```

---

## `lib/logging.sh`

Six one-line helpers plus a conditional RETURN trap. The functions
all write through `printf` / `echo`, take no filesystem action, and
have no concurrency concerns. They are gated by `DEBUG_IND` — a
truthy `1` unlocks the three tracing helpers and installs a
function-exit trap; any other value leaves them silent.

### `log_enter`

**Source**: `lib/logging.sh:22`
**Visibility**: public
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H1

**Signature**
```
log_enter
```

Takes no arguments. The caller's function name is read from
`FUNCNAME[1]` automatically.

**Returns**: `0` always
**Stdout**: silent
**Stderr**: When `DEBUG_IND=1`: one line `[DEBUG] → <caller>()`. When
`DEBUG_IND` is unset or not `"1"`: silent.

**Preconditions**: must be called from inside a function (otherwise
`FUNCNAME[1]` expands to `main` or empty — still valid but less
informative).

**Postconditions**: none beyond the optional stderr write.

**Invariants**

- Silent when `DEBUG_IND != "1"`, including when it is unset.
- Never writes to stdout — stdout is reserved for the operator-facing
  `log_info` channel so that stdout can be piped through `tee` without
  debug noise.

**Side effects**

- Writes one line to file descriptor 2 when gated on.

**Error modes**: none — this function cannot fail.

**Example**

```bash
my_helper() {
    log_enter
    # ... body ...
}
# DEBUG_IND=1 my_helper → "[DEBUG] → my_helper()" on stderr
```

### `log_debug`

**Source**: `lib/logging.sh:36`
**Visibility**: public
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H1

**Signature**
```
log_debug <message_tokens...>
```

| Position | Name           | Type   | Constraint                                       |
| -------: | -------------- | ------ | ------------------------------------------------ |
|       $@ | message_tokens | string | Free-form text; concatenated with single spaces. |

**Returns**: `0` always
**Stdout**: silent
**Stderr**: When `DEBUG_IND=1`: `[DEBUG]   <caller>: <message>`.
Otherwise silent.

**Preconditions**: must be called from inside a function for a
meaningful caller name.

**Postconditions**: none beyond the optional stderr write.

**Invariants**

- Silent when `DEBUG_IND != "1"`.
- Caller name is resolved at call time (`FUNCNAME[1]`), so indirect
  callers see their own name, not the helper they dispatched through.

**Side effects**: one optional stderr line.

**Error modes**: none.

**Example**

```bash
space_reserve() {
    log_debug "reserving $archive_bytes + $extracted_bytes on dev=$dev"
}
```

### `log_trace`

**Source**: `lib/logging.sh:51`
**Visibility**: public
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H1

**Signature**
```
log_trace <message_tokens...>
```

| Position | Name           | Type   | Constraint      |
| -------: | -------------- | ------ | --------------- |
|       $@ | message_tokens | string | Free-form text. |

**Returns**: `0` always
**Stdout**: silent
**Stderr**: When `DEBUG_IND=1`: `[DEBUG] <message>` — no caller
attribution prefix.
Otherwise silent.

**Preconditions**: none — this helper exists specifically for
subprocess scripts (`extract.sh`, `precheck.sh`, `dispatch.sh`) where
`FUNCNAME[1]` would be misleading because they run as `bash <script>`
with no surrounding function frame.

**Postconditions**: none beyond the optional stderr write.

**Invariants**

- Silent when `DEBUG_IND != "1"`.
- No function-name prefix — distinguishes it visually from the
  `log_debug` / `log_enter` output so an operator can tell the
  subprocess scripts apart from parent-shell functions in a combined
  log.

**Side effects**: one optional stderr line.

**Error modes**: none.

**Example**

```bash
# Inside lib/extract.sh (run as `bash extract.sh`):
log_trace "starting extract for $job_path"
```

### `log_info`

**Source**: `lib/logging.sh:83`
**Visibility**: public
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H1

**Signature**
```
log_info <message_tokens...>
```

| Position | Name           | Type   | Constraint      |
| -------: | -------------- | ------ | --------------- |
|       $@ | message_tokens | string | Free-form text. |

**Returns**: `0` always
**Stdout**: `[pipeline] <message>` — always visible regardless of
`DEBUG_IND`.
**Stderr**: silent.

**Preconditions**: none.

**Postconditions**: one line written to stdout.

**Invariants**

- Always emits, regardless of `DEBUG_IND`. This is the one channel
  that must remain visible for operator-facing status milestones
  ("Loading jobs", "Starting pipeline", "All jobs completed").
- Uses stdout so an operator can pipe the run output to a log file
  without losing progress messages.

**Side effects**: one stdout line.

**Error modes**: none.

**Example**

```bash
log_info "Loading jobs from $JOBS_FILE..."
```

### `log_warn`

**Source**: `lib/logging.sh:84`
**Visibility**: public
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H1

**Signature**
```
log_warn <message_tokens...>
```

| Position | Name           | Type   | Constraint      |
| -------: | -------------- | ------ | --------------- |
|       $@ | message_tokens | string | Free-form text. |

**Returns**: `0` always
**Stdout**: silent.
**Stderr**: `[WARN]  <message>` — always visible regardless of
`DEBUG_IND`.

**Preconditions**: none.

**Postconditions**: one line written to stderr.

**Invariants**

- Always emits, regardless of `DEBUG_IND`.
- Does not itself abort — callers decide whether a warning implies
  an exit.

**Side effects**: one stderr line.

**Error modes**: none — a warning never aborts.

**Example**

```bash
log_warn "archive has a wrapper dir; flattening: $wrapper_name"
```

### `log_error`

**Source**: `lib/logging.sh:85`
**Visibility**: public
**Test coverage**: `test/suites/16_unit_lib_helpers.sh` H1

**Signature**
```
log_error <message_tokens...>
```

| Position | Name           | Type   | Constraint      |
| -------: | -------------- | ------ | --------------- |
|       $@ | message_tokens | string | Free-form text. |

**Returns**: `0` always (does not itself exit).
**Stdout**: silent.
**Stderr**: `[ERROR] <message>` — always visible regardless of
`DEBUG_IND`.

**Preconditions**: none.

**Postconditions**: one line written to stderr.

**Invariants**

- Always emits.
- Does not abort — the caller decides whether to `exit`. Many callers
  emit several `log_error` lines and then `exit 1` to give the
  operator a complete summary before aborting.

**Side effects**: one stderr line.

**Error modes**: none — `log_error` never aborts by itself.

**Example**

```bash
log_error "loadout-pipeline prerequisite check FAILED"
log_error "the following required commands were not found on \$PATH:"
for cmd in "${missing[@]}"; do log_error "  - $cmd"; done
exit 1
```

---

## `lib/prereq.sh`

### `check_prerequisites`

**Source**: `lib/prereq.sh:39`
**Visibility**: public
**Test coverage**: `test/suites/13_prereq.sh` P1–P5

**Signature**
```
check_prerequisites
```

Takes no arguments.

**Returns**: `0` if every required binary is present (exits `1` on
the first failed run — does not return non-zero).
**Stdout**: silent.
**Stderr**: On failure, a multi-line actionable error via `log_error`:
a list of missing binaries plus a distro-by-distro install recipe
table and a pointer to `README.md`'s "Required packages" section.

**Preconditions**

- `log_error` is already defined (i.e. `lib/logging.sh` has been
  sourced before this helper is called).
- `BASH_VERSINFO` is available — it is a bash built-in, so this is
  trivially satisfied by the shebang on `bin/loadout-pipeline.sh`.

**Postconditions (on success)**

- Every core binary listed in the function body is on `$PATH`.
- `bash` is at least version `4.0` (required for associative arrays,
  `BASHPID`, `-v` tests, and several parameter-expansion forms).

**Invariants**

- Only the **unconditional** dependencies are checked. Adapter-specific
  tools (`rsync`, `rclone`, `ssh`, `hdl_dump`, `lftp`, `curl`) are
  validated lazily by each adapter when it is invoked, so a host that
  only uses the sd adapter does not need rclone installed.
- The required list matches README.md's "Core (always required)"
  section — if the list drifts, README.md drifts too, and vice versa.
- Runs **before** any filesystem touch: `bin/loadout-pipeline.sh`
  calls `check_prerequisites` before `init_environment`, so a
  missing-binary host never creates queue dirs or scratch files.

**Side effects**

- Reads `$PATH` via `command -v`.
- Writes multi-line error messages to stderr via `log_error` on
  failure.
- Exits the process with code `1` on any failure — does not return.

**Error modes**

| rc | Condition                   | Characteristic stderr                                                     |
| --: | --------------------------- | ------------------------------------------------------------------------- |
|  1 | `bash < 4.0`                | `loadout-pipeline requires bash >= 4.0 (found ...)`                       |
|  1 | Any required binary missing | `loadout-pipeline prerequisite check FAILED` followed by a `- <cmd>` list |

**Example**

```bash
# Inside bin/loadout-pipeline.sh
log_info "Checking prerequisites..."
check_prerequisites   # exits 1 on failure; returns 0 on success
```

---

## `lib/init.sh`

### `_assert_pipeline_dir_safe`

**Source**: `lib/init.sh:33`
**Visibility**: private
**Test coverage**: `test/suites/15_unit_runtime.sh` R1

**Signature**
```
_assert_pipeline_dir_safe <directory_path>
```

| Position | Name           | Type          | Constraint         |
| -------: | -------------- | ------------- | ------------------ |
|       $1 | directory_path | absolute path | Must not be empty. |

**Returns**: `0` on success. Exits `1` on any violation — does not
return non-zero.
**Stdout**: silent.
**Stderr**: On failure, a pair of `log_error` lines explaining the
violation and suggesting a remediation.

**Preconditions**

- `log_error` is defined.
- The caller has the right to `mkdir` at the path if it does not
  exist yet (i.e. the parent directory is writable by the current
  user).

**Postconditions (on return)**

- `<directory_path>` exists on the filesystem.
- It is not a symlink.
- It is owned by the current user.
- If it did not exist before the call, it was created with mode
  `0700` — no group/other access at all.

**Invariants**

- A symlink is **never** accepted, even if it points at a directory
  owned by the current user. A local attacker who replaces the
  directory with a symlink pointing elsewhere could redirect all
  pipeline writes into an attacker-controlled path, so the function
  refuses symlinks outright.
- Ownership is checked by numeric UID, not by name. An NFS mount with
  UID squashing that reports a different name but the same UID is
  still considered "owned by the current user".
- Newly-created directories are always `0700`, never `0755` —
  prevents other local users from reading scratch files (which may
  contain archive content or credentials passed via env vars).

**Side effects**

- May create `<directory_path>` with mode `0700` via `install -d -m 700`.
- Runs `stat -c %u` and `id -u` on the system.
- Writes to stderr and exits the process on any violation.

**Error modes**

| rc | Condition                             | Characteristic stderr                                                   |
| --: | ------------------------------------- | ----------------------------------------------------------------------- |
|  1 | Path is a symlink                     | `pipeline directory must not be a symlink: <path>`                      |
|  1 | Existing dir owned by a different UID | `pipeline directory is not owned by the current user (uid=<n>): <path>` |

**Example**

```bash
_assert_pipeline_dir_safe "$QUEUE_DIR"
_assert_pipeline_dir_safe "$EXTRACT_DIR"
_assert_pipeline_dir_safe "$COPY_DIR"
```

### `init_environment`

**Source**: `lib/init.sh:73`
**Visibility**: public
**Test coverage**: `test/suites/13_prereq.sh` P5 (ordering — prereq runs first), `test/suites/02_core_pipeline.sh` (end-to-end smoke)

**Signature**
```
init_environment
```

Takes no arguments.

**Returns**: `0` on success (exits the process on any safety
violation via the inner `_assert_pipeline_dir_safe` calls).
**Stdout**: silent.
**Stderr**: silent on success.

**Preconditions**

- `$QUEUE_DIR`, `$EXTRACT_DIR`, `$COPY_DIR` are all set (guaranteed
  by `lib/config.sh`).
- `_assert_pipeline_dir_safe` is defined (same file).

**Postconditions (on return)**

- All three working directories exist.
- All three are owned by the current user.
- None are symlinks.
- Any newly-created ones have mode `0700`.
- `mkdir -p` has been called on each as a belt-and-braces idempotent
  step so callers can immediately write inside them.

**Invariants**

- `_assert_pipeline_dir_safe` is called for **every** directory
  before any of them are populated. If any directory is unsafe, the
  process exits before any writes happen, so a failed
  `init_environment` never leaves half-created state behind.
- Order is fixed: `QUEUE_DIR`, then `EXTRACT_DIR`, then `COPY_DIR`.
  The order is not load-bearing today but suite 13 P5 pins the
  ordering as "runs after `check_prerequisites`", which is the
  invariant the compat freeze actually cares about.

**Side effects**

- May create `$QUEUE_DIR`, `$EXTRACT_DIR`, `$COPY_DIR` (each with
  mode `0700` on first run).
- Writes to stderr and exits the process on any safety violation.

**Error modes**

Inherits all `_assert_pipeline_dir_safe` error modes — same rc, same
characteristic stderr.

**Example**

```bash
# Inside bin/loadout-pipeline.sh, after check_prerequisites:
log_info "Initializing environment..."
init_environment
```
