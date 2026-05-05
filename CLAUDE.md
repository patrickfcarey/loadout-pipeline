# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Authoritative references — read these first

This repository has unusually rich agent-facing documentation. Before making non-trivial changes, read:

- **`ai_agent_entry_point.md`** — architecture overview and the **backwards-compatibility freeze policy** that binds every PR. Names every public env var, CLI shape, file format, and adapter contract that may not be renamed or removed without a major-version bump.
- **`CONTRIBUTING.md`** — the descriptive code-quality contract (file shape, naming, logging, error handling, concurrency, security, banned patterns). Rules are derived from existing patterns; if you find a divergence, treat the existing file as wrong.
- **`docs/architecture.md`** — pipeline flow, queue design, space ledger.
- **`docs/requirements/`** — per-function contracts. Functions with a `-Source:` citation here have pinned behaviour.

The above files are not boilerplate — they encode load-bearing constraints (e.g. exit-code semantics, log strings tooling greps for, the `~<src>|<adapter>|<dest>~` grammar). Skim them before editing `lib/`, `adapters/`, or `bin/`.

## Common commands

```bash
# Run the full unit suite (sourced into a single shell — counters live in parent scope).
# Assertion-count floor: ≥ 458 with 0 failures (see ai_agent_entry_point.md §Verification).
bash test/run_tests.sh

# Mutation validation — every assertion has a paired V-check that mutates code and
# expects the assertion to fail. Add a V-check in the same PR as a new assertion.
bash test/validate_tests.sh

# Integration tests inside a privileged Docker container (real losetup, mkfs.vfat,
# loopback mounts, real FTP/rclone/SSH daemons — not mocks).
bash test/integration/launch.sh

# Run a single suite during development by sourcing it directly after the framework:
bash -c 'source test/helpers/framework.sh && source test/suites/19_unit_concurrency.sh'

# Build the single-file bundle (BusyBox-style multi-call script).
bash build/bundle.sh   # produces dist/loadout-pipeline.sh

# Run the pipeline.
bash bin/loadout-pipeline.sh examples/example.jobs
bash bin/loadout-pipeline.sh <profile_directory>     # loads every *.jobs in the dir
MAX_UNZIP=4 DEBUG_IND=2 bash bin/loadout-pipeline.sh examples/lvol.jobs
```

`PIPELINE=<path>` overrides which entry point `run_tests.sh` exercises — useful for running the full suite against `dist/loadout-pipeline.sh` to verify the bundle behaves identically to the source tree.

## Big-picture architecture

The pipeline is a two-stage concurrent dataflow. Understanding the **shared-state coordination** is the bulk of the architectural complexity — naive implementations of each piece will corrupt state.

**Stage flow** (`bin/loadout-pipeline.sh` is a thin orchestrator):

1. `lib/config.sh` loads `.env`, applies caller-supplied env wins, validates numerics, exports everything.
2. `lib/logging.sh` installs a `RETURN` trap (under `set -o functrace`) that auto-logs every sourced-lib function exit at `DEBUG_IND≥1`, with `rc=` at level 2.
3. `load_jobs` parses the `~<iso>|<adapter>|<dest>~` grammar into `JOBS[]`.
4. `workers_start` claims a per-run scratch spool `COPY_SPOOL=$COPY_DIR/$$`, sweeps dead-PID siblings, initialises the space ledger and worker registry, pushes all jobs onto `EXTRACT_QUEUE_DIR`, and forks two pools that drain concurrently:
   - **Extract pool** (`MAX_UNZIP` workers): `precheck → space_reserve (under flock) → cp into COPY_SPOOL → 7z extract → strip-list filter → push to dispatch queue`. Exit 75 on space-miss → `unzip_worker` re-queues with exponential backoff (`SPACE_RETRY_BACKOFF_*`).
   - **Dispatch pool** (`MAX_DISPATCH` workers): `dispatch.sh` → routes to `adapters/<name>.sh` under `env -u` credential stripping. Backs off via `DISPATCH_POLL_INITIAL_MS` → `DISPATCH_POLL_MAX_MS`.
5. After both pools drain, `_recover_orphans` reads the worker registry; any in-flight job left behind by a SIGKILL'd worker is re-queued for another pass (capped by `MAX_RECOVERY_ATTEMPTS`, default 3).
6. `rm -rf "$COPY_SPOOL"` — guaranteed cleanup even if EXIT traps never fired.

**Coordination primitives** (each exists because a naive version corrupted state):

- **Queues** (`lib/queue.sh`): directories of `.job` files named with nanosecond timestamps. `queue_pop` uses atomic `mv` to claim — only one `mv` wins per filename, no double-processing without locks. Two queues: `EXTRACT_QUEUE_DIR`, `DISPATCH_QUEUE_DIR`.
- **Space ledger** (`lib/space.sh`): exclusive `flock` on `$QUEUE_DIR/.space_ledger.lock` wraps the entire read-`df`-decide-append critical section. Pools `COPY_DIR` + `EXTRACT_DIR` against one `df` if they share a device (`stat -c %d`). `SPACE_OVERHEAD_PCT` (default 20) inflates the requirement. `SPACE_AVAIL_OVERRIDE_BYTES` is a test hook (not user-facing).
- **Worker registry** (`lib/worker_registry.sh`): flock-guarded `<pid> <job>` file written on `worker_job_begin`, removed on `worker_job_end`. Any leftover row after the pool exits = SIGKILL'd worker → orphan.
- **Per-run scratch isolation**: every concurrent pipeline instance gets its own `$COPY_DIR/$$` subdir; `_spool_sweep_and_claim` deletes sibling subdirs whose PID fails `kill -0`. After sweep, the worker unconditionally `rm -rf`s its own claimed dir before `mkdir -p` (PID-reuse guard).

**Source order is load-bearing.** `bin/loadout-pipeline.sh` sources `lib/config.sh` **first** (defaults + validation), `lib/logging.sh` **second** (RETURN trap must precede function defs). `lib/space.sh` and `lib/worker_registry.sh` are sourced lazily from inside `workers_start`. Adapter scripts are forked subprocesses — they do not inherit the RETURN trap; use `log_trace` / `log_xtrace` there instead of `log_debug`.

**Adapter contract is frozen.** Every `adapters/<name>.sh` accepts exactly `<src_dir> <dest_subpath>`, copies `$src`'s **contents** into `$dest` (not `$src` as a subdirectory), exits 0/1. Adding an adapter is a five-step change: create the script, add a case arm to `lib/dispatch.sh`, add a case arm to `lib/precheck.sh`, extend the regex in `lib/jobs.sh`, declare env vars in `lib/config.sh` + `.env.example`. Stub adapters (`ftp`, `rclone`) refuse with `exit 1` and a message containing the word `"stub"` unless `ALLOW_STUB_ADAPTERS=1`. The hdl adapter demonstrates the 4-field job-line extension pattern (`parse_hdl_destination` in `lib/job_format.sh`).

**Bundle build.** `build/bundle.sh` concatenates `lib/` + `adapters/` + `bin/loadout-pipeline.sh` into `dist/loadout-pipeline.sh` and uses `sed` to rewrite every `bash "$ROOT_DIR/lib/extract.sh"` (and similar) into `bash "$__LP_BUNDLE_PATH" __lp_mode <name>`. Forked sub-stages still create real PIDs, so the worker registry / SIGKILL recovery work bit-for-bit identically. The `env "${_strip_args[@]}" bash …` credential-stripping wrappers survive the rewrite untouched.

## Working rules that affect almost every change

- **Exit codes are a contract**: `0` success/skip, `1` runtime failure (re-runnable), `2` fatal preflight (config error), `75` space-reservation backpressure (re-queue). Tooling parses for `exit 2` + stderr to distinguish "your `.env` is broken" from "a transfer failed."
- **Two log strings are grep-anchored** by tooling and must not be reworded: `"space reservation miss"` (in `lib/workers.sh`) and `"stub"` (in stub adapters). Other log wording is cosmetic.
- **Backwards compat freeze**: env var names + defaults, CLI argument shape, `.env` parser edge cases, the `~<iso>|<adapter>|<dest>~` grammar, adapter 2-arg contract, exit codes, and every helper pinned by a test in `test/suites/14_…20_` are all frozen. Additions (new env vars with defaults, new flags, new adapters, new job-line trailing fields) are always allowed; renames and subtractions require a major-version bump.
- **Bash ≥ 4.2 + GNU coreutils assumed**. No POSIX downgrade. Macs install `coreutils`, `findutils`, `gnu-sed` via Homebrew; missing `realpath` is a fatal error, never a reason to skip a containment check.
- **No `eval` on user input.** Path traversal (`..`) is rejected in both `iso_path` and `destination`. Destination containment uses `realpath -m` — never degrade.
- **Concurrency tests are mandatory**: any new shared-state primitive needs a race test in `test/suites/19_unit_concurrency.sh` (fork N processes, race them, assert no double-claim). See existing `Q1`, `Q3`, `R7`.
- **Mutation validation pairing**: every new assertion in `run_tests.sh` gets a paired V-check in `validate_tests.sh` in the same PR. Unpaired assertions are dead weight — they cannot distinguish working code from broken code.
