# loadout-pipeline Architecture

## Entry Point

`bin/loadout-pipeline.sh` is the single entry point. On startup it:

1. Resolves `ROOT_DIR`
2. Sources `lib/config.sh`, which loads `.env` and exports all configuration defaults
3. Sources the remaining libraries in order: `logging.sh` → `init.sh` → `jobs.sh` → `queue.sh` → `workers.sh`
4. Calls `init_environment`, `load_jobs`, then `workers_start`

`lib/space.sh` and `lib/worker_registry.sh` are sourced lazily from inside
`workers_start` (via `_pipeline_run_init`) because they only become relevant
once a run actually begins.

---

## Library Files

| File                      | Responsibility                                                                 |
|---------------------------|--------------------------------------------------------------------------------|
| `lib/config.sh`           | `.env` loader + all exported variable defaults                                 |
| `lib/logging.sh`          | `log_enter`, `log_debug`, `log_trace`, `log_warn`, `log_error` + RETURN trap   |
| `lib/init.sh`             | `init_environment` — creates `EXTRACT_DIR`, `COPY_DIR`, `QUEUE_DIR`             |
| `lib/job_format.sh`       | `parse_job_line` — canonical `~iso\|adapter\|dest~` parser, sourced by all stages |
| `lib/jobs.sh`             | `load_jobs` — validate and parse the job file into `JOBS[]`                    |
| `lib/queue.sh`            | `queue_init`, `queue_push`, `queue_pop` — file-based FIFO, parameterised on queue dir |
| `lib/workers.sh`          | `workers_start`, `unzip_worker`, `dispatch_worker` — two-stage worker pools + recovery loop |
| `lib/extract.sh`          | Per-job extract stage: precheck → space reservation → copy → 7z → dispatch push |
| `lib/precheck.sh`         | Per-adapter "already at destination?" check                                    |
| `lib/dispatch.sh`         | Routes a dispatch-stage job to the correct adapter by adapter type             |
| `lib/space.sh`            | `flock`-guarded space reservation ledger (shared across concurrent workers)    |
| `lib/worker_registry.sh`  | `flock`-guarded registry of in-flight jobs → enables intra-run recovery        |

---

## Pipeline Flow

```
bin/loadout-pipeline.sh
│
├── lib/init.sh        → create EXTRACT_DIR, COPY_DIR, QUEUE_DIR
├── lib/jobs.sh        → parse job file → JOBS[]
│
└── lib/workers.sh (workers_start)
    │
    ├── _spool_sweep_and_claim   → sweep dead-PID subdirs in COPY_DIR,
    │                               export COPY_SPOOL="$COPY_DIR/$$"
    ├── _pipeline_run_init       → queues + sentinel + space ledger + registry
    ├── push every JOBS[] entry onto EXTRACT_QUEUE_DIR
    │
    ├─── pass loop ────────────────────────────────────────────────────┐
    │                                                                   │
    │   [MAX_UNZIP extract workers]                                     │
    │   │                                                               │
    │   └── worker_job_begin → lib/extract.sh → worker_job_end          │
    │       ├── lib/precheck.sh — already present? → [skip]             │
    │       ├── space_reserve (flock) — rc=75 retry if no fit           │
    │       ├── cp <archive> → $COPY_SPOOL/<name>.<pid>                 │
    │       ├── 7z x -aoa    → $EXTRACT_DIR/<name>/                     │
    │       ├── strip files listed in EXTRACT_STRIP_LIST                │
    │       ├── EXIT trap: space_release + scratch cleanup              │
    │       └── queue_push DISPATCH_QUEUE_DIR                           │
    │                                                                   │
    │   [MAX_DISPATCH dispatch workers, concurrent with extract]        │
    │   └── lib/dispatch.sh → adapter                                   │
    │                                                                   │
    │   after all workers exit:                                         │
    │   _recover_orphans → worker_registry_recover → re-queue orphans   │
    │   loop again (up to MAX_RECOVERY_ATTEMPTS passes)                 │
    ├───────────────────────────────────────────────────────────────────┘
    │
    └── rm -rf "$COPY_SPOOL"
```

Termination of a single pass: after all extract workers exit, `workers_start`
writes `$QUEUE_DIR/.extract_done`. Dispatch workers exit the moment both
conditions hold — dispatch queue empty AND the sentinel file exists.

---

## Queue Design

Two sub-queues live inside `$QUEUE_DIR`:

| Sub-queue             | Default                               |
|-----------------------|---------------------------------------|
| `EXTRACT_QUEUE_DIR`   | `$QUEUE_DIR/extract`                  |
| `DISPATCH_QUEUE_DIR`  | `$QUEUE_DIR/dispatch`                 |

Each sub-queue is a directory of `.job` files.

- `queue_push <dir> <job>` writes `<nanosecond_timestamp>.<pid>.job` — one file per job
- `queue_pop <dir>` uses a glob + atomic `mv` to claim a file before reading it
- The `mv` claim prevents two workers from processing the same job (race-safe)
- `queue_init <dir>` clears a sub-queue at the start of each pipeline run (and between recovery passes)

---

## Space Reservation Ledger (`lib/space.sh`)

Without coordination, N concurrent workers could all call `df`, all see the
same free bytes, all decide they fit, and collectively consume N× the
available space. The space ledger prevents that.

- Every reservation goes through `space_reserve <id> <copy_dir> <copy_bytes> <extract_dir> <extract_bytes>`, which acquires an exclusive `flock` on `$QUEUE_DIR/.space_ledger.lock`.
- The entire *read-ledger → call-`df` → arithmetic → append* sequence runs inside the lock, so the check-and-commit is atomic.
- **Same-filesystem pooling:** if `COPY_DIR` and `EXTRACT_DIR` share a device (`stat -c %d`), reservations for both dirs are pooled against a single `df` number so free space is not double-counted.
- **Overhead:** the byte requirement is inflated by `SPACE_OVERHEAD_PCT` (default 20%) to cover filesystem metadata, 7z temp files, and general slack.
- **Release:** `extract.sh`'s EXIT trap calls `space_release` on every exit (success, failure, SIGTERM). SIGKILL can't run the trap, but `space_init` truncates the ledger at the start of every run so inter-run stale entries never leak.
- **Phantom GC (intra-run):** every ledger entry stores the worker's `BASHPID` as a sixth field. Each call to `space_reserve` runs `_space_ledger_gc_phantoms` inside the lock, which uses `awk + system("kill -0 <pid>")` to evict any entry whose owner process is no longer alive. This prevents SIGKILL'd workers from blocking sibling workers for the remainder of the current run.
- **Retry loop:** if `space_reserve` returns non-zero (no fit right now), `extract.sh` exits 75 and `unzip_worker` re-queues the job and tries again later with exponential backoff. If the ledger is empty after a failed reservation (no siblings hold space), the job is declared fatally oversized and fails immediately rather than waiting forever.
- **Test hook:** `SPACE_AVAIL_OVERRIDE_BYTES` replaces the real `df` lookup so tests can simulate a small filesystem without root/tmpfs.

---

## Per-Run Scratch Spool (`COPY_SPOOL`)

`COPY_DIR` is shared across concurrent pipeline runs, so deleting files in it
would race with other instances. Each run therefore creates a dedicated subdir
`$COPY_DIR/$$` and exports it as `COPY_SPOOL`. All scratch copies for the run
go into that subdir.

At the top of every run, `_spool_sweep_and_claim` walks `$COPY_DIR/*`, and for
each subdir named after a PID that is no longer alive (`kill -0` fails), it
`rm -rf`'s that subdir. This reclaims litter left by previous runs that were
SIGKILL'd before their cleanup could run.

At the end of `workers_start`, `rm -rf "$COPY_SPOOL"` removes the whole
container. `extract.sh` normally deletes individual scratch copies in its EXIT
trap on clean exits; the final `rm -rf` is the safety net for SIGKILL'd jobs
inside the current run.

---

## Worker Registry & Intra-Run Recovery (`lib/worker_registry.sh`)

`queue_pop` atomically removes a job from the queue before work begins. If a
worker is SIGKILL'd mid-job, the job simply vanishes — nothing re-queues it.

The worker registry bridges that gap.

- Each extract worker calls `worker_job_begin "$BASHPID" "$job"` right after `queue_pop` and `worker_job_end "$BASHPID"` after the job resolves (success, failure, or space-retry re-queue).
- All mutations are guarded by `flock` on `$QUEUE_DIR/.worker_registry.lock`.
- After a worker pass finishes, `_recover_orphans` calls `worker_registry_recover`, which outputs any jobs still in the registry (owned by workers that never got to call `worker_job_end`) and truncates the registry.
- Orphaned jobs are re-queued and another full pass runs. The loop is capped at `MAX_RECOVERY_ATTEMPTS` (default 3); beyond that, remaining orphans are declared permanently abandoned and `workers_start` returns non-zero.
- **Re-run recovery:** even without intra-run recovery, re-running the pipeline naturally completes any skipped job because `workers_start` re-pushes every `JOBS[]` entry and precheck skips jobs already present at the destination.

---

## Precheck

`lib/precheck.sh` runs once per extract job and answers a single question: *is
the archive's extracted content already present at the destination?*

| Exit | Meaning                                                          |
|-----:|------------------------------------------------------------------|
|  `0` | Content already present → `extract.sh` logs `[skip]` and exits   |
|  `1` | Not present → proceed with reserve + copy + extract + dispatch    |
|  `2` | Fatal preflight failure (malformed archive, unknown adapter)      |

Space accounting has moved out of precheck and into `extract.sh` (under the
shared ledger) so concurrent workers coordinate reservations properly.

Per-adapter behaviour:

| Adapter  | Check                                                 | Status                                      |
|----------|-------------------------------------------------------|---------------------------------------------|
| `sd`     | `test -e "$SD_MOUNT_POINT/$dest/<contained>"`         | Real                                        |
| `ftp`    | TODO: `curl --list-only` / `lftp ls` against `$dest`  | Stub (always returns "not present")         |
| `hdl`    | TODO: `hdl_dump toc "$dest"` grep for title           | Stub (always returns "not present")         |
| `rclone` | TODO: `rclone ls $RCLONE_REMOTE$RCLONE_DEST_BASE/...` | Stub (always returns "not present")         |
| `rsync`  | TODO: `ssh` + stat or `rsync --dry-run`                | Stub (always returns "not present")         |

Stub checks are pessimistic by design: they always proceed with work rather
than risk a false skip.

---

## Configuration

All configuration is exported by `lib/config.sh` before any library code runs.
Override precedence (highest to lowest):

1. Env var set before the call: `MAX_UNZIP=4 bash bin/loadout-pipeline.sh`
2. `.env` file values
3. Hardcoded fallbacks in `lib/config.sh`

Key variables not visible in the pipeline core table:

| Variable                          | Default                  | Description                                                                        |
|-----------------------------------|--------------------------|------------------------------------------------------------------------------------|
| `EXTRACT_STRIP_LIST`              | `$ROOT_DIR/strip.list`   | File listing bare filenames to delete from every extracted archive before dispatch |
| `DISPATCH_POLL_INITIAL_MS`        | `50`                     | Starting poll interval (ms) for dispatch workers when the dispatch queue is empty  |
| `DISPATCH_POLL_MAX_MS`            | `500`                    | Maximum poll interval (ms) for the exponential dispatch backoff                    |
| `SPACE_RETRY_BACKOFF_INITIAL_SEC` | `5`                      | Initial sleep (s) for an extract worker after a space-reservation miss             |
| `SPACE_RETRY_BACKOFF_MAX_SEC`     | `60`                     | Maximum sleep (s) for the exponential space-retry backoff                          |

See `.env.example` for the full variable reference.

---

## Adapters

The SD card adapter (`adapters/sdcard.sh`) is **fully implemented**: it
validates `SD_MOUNT_POINT`, performs a `realpath -m` containment check to
prevent destination-escape via `..` segments, and copies using `rsync -a`
(with a `cp -r` fallback when rsync is unavailable).

All other adapters (`ftp`, `hdl`, `rclone`, `rsync`) are **stubs** — they log
what they would do but do not transfer any files. Each script contains a
`TODO` marker and implementation notes.

To add a new adapter:
1. Create `adapters/<name>.sh`
2. Add a `<name>)` case to `lib/dispatch.sh`
3. Add a `<name>)` case to `lib/precheck.sh` (or keep the default "not present" stub)
4. Add the adapter key to the regex in `lib/jobs.sh`
5. Add any required env vars to `.env.example` and `lib/config.sh`

---

## Testing

### Unit suite (`test/run_tests.sh`)

**27 test cases, 99 assertions.** Covers: default run, single worker, more
workers than jobs, custom `QUEUE_DIR`, idempotent re-runs, custom `EXTRACT_DIR`,
SD precheck skip, multi-file archive (.bin + .cue), partial-hit precheck,
mid-extract failure + cleanup, rerun after failure, concurrent space reservation
under scarcity, SIGKILL'd extract + spool cleanup + rerun, worker registry unit
test, rclone/rsync adapter smoke tests, intra-run orphan recovery via the worker
registry, phantom ledger GC after SIGKILL (H1 fix), mid-string `/../` rejection
in the job-line parser (M2 fix), a real 196 MB PS2 archive exercising spaces and
parentheses in the iso path (Test 21 — **hard-fails when the archive is absent**),
and regression pins for C1 (basename `.`), C2 (`_space_dev` loop), H1
(queue_pop rc), and M3 (worker_registry consecutive spaces).

Mutation validation (`test/validate_tests.sh`) provides **57 V-checks** — one
per meaningful assertion — to confirm every assertion would catch a real defect.

### Integration suite (`test/integration/`)

Exercises the same scenarios on a **real kernel substrate**: loop-mounted vfat
(via losetup + mkfs.vfat), a 6 MB tmpfs that produces real ENOSPC, real SIGKILL
via an in-process watcher (no shims), real dead PIDs from reaped children, and
real sshd/pure-ftpd/rclone services. All substrate provisioning is containerised:

```bash
bash test/integration/launch.sh   # builds + runs inside --privileged Docker
```

Key files:

| Path | Purpose |
|------|---------|
| `test/integration/Dockerfile` | Privileged test image (debian-slim + p7zip, dosfstools, pure-ftpd, openssh, rclone, rsync) |
| `test/integration/launch.sh` | Host-side: `docker build` + `docker run --privileged` |
| `test/integration/run_integration.sh` | Orchestrator inside the container |
| `test/integration/helpers/bootstrap.sh` | Provisions 7 substrates; single EXIT/INT/TERM teardown trap |
| `test/integration/helpers/verify.sh` | `tree_hash`, `assert_tree_eq`, byte-exact assertions |
| `test/integration/helpers/inject.sh` | `inject_sigkill_after`, `inject_dead_pid`, `inject_enospc` |
| `test/integration/fixtures/generate_int_archives.sh` | Synthetic urandom archives (cached by presence) |
| `test/integration/suites/01–10` | Mirror unit-suite numbering; stub-adapter scenarios hard-fail |

Stub adapter scenarios (ftp, hdl_dump, rclone, rsync) intentionally produce
`FAIL` until real implementations land. Their failure messages are stable and
greppable so CI output makes the gap visible without hiding it.
