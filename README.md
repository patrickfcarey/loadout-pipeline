# loadout-pipeline

A lightweight shell-based pipeline for **unpacking ISO/game files** and dispatching them to multiple destinations (FTP, HDL dump, SD card, rclone, rsync).

It supports **parallel extraction**, **bounded queues**, **pluggable adapters**, **flock-guarded space reservations**, and **intra-run recovery of SIGKILL'd workers** — designed for fast scratch storage and large archival pools.

---

## Features

- Two-stage pipeline: extract workers (`MAX_UNZIP`) and dispatch workers (`MAX_DISPATCH`) drain two file-based queues concurrently so dispatch of job N overlaps extraction of job N+1
- Dispatch to multiple destinations: FTP, HDL dump, SD card, rclone, rsync
- Precheck short-circuit: skips the whole copy → extract → dispatch sequence when the contents are already present at the destination (`[skip] ...`)
- **Shared space ledger** (`lib/space.sh`): concurrent extract workers coordinate scratch-space reservations through a `flock`-guarded check-and-commit, with pooling on same-filesystem setups and a configurable overhead margin (`SPACE_OVERHEAD_PCT`, default 20%)
- **Per-run scratch spool** (`COPY_SPOOL=$COPY_DIR/$$`): each run owns its own subdir; a startup sweep reclaims spools left by previous runs whose PID is no longer alive — safe against concurrent pipeline instances
- **Intra-run recovery**: a worker registry (`lib/worker_registry.sh`) tracks in-flight jobs so a SIGKILL'd extract can be detected, re-queued, and finished on the next pass, up to `MAX_RECOVERY_ATTEMPTS`
- Race-safe file-based job queues (atomic `mv` claiming — no double-processing)
- Modular, pluggable adapters
- `.env` file support for environment configuration

---

## Quickstart

A **profile** (also called a job file) is a plain text file with one job per line — it tells the pipeline which archives to process and where to send them. You can keep as many profiles as you like anywhere on disk and switch between them just by changing the argument.

```bash
# 1. One-time setup
git clone <repo_url> && cd loadout-pipeline
cp .env.example .env
chmod 600 .env          # keep credentials private
bash test/fixtures/create_fixtures.sh   # generate test archives

# 2. Run a built-in example profile
bash bin/loadout-pipeline.sh examples/sd_card.jobs

# 3. Run your own profile from anywhere on disk
bash bin/loadout-pipeline.sh ~/profiles/my_collection.jobs

# 4. Override the SD card destination at call time — no file editing needed
SD_MOUNT_POINT=/media/usbstick bash bin/loadout-pipeline.sh ~/profiles/my_collection.jobs

# 5. More workers + dedicated scratch dir for a fast NVMe drive
MAX_UNZIP=6 EXTRACT_DIR=/mnt/nvme/extract COPY_DIR=/mnt/nvme/scratch \
    bash bin/loadout-pipeline.sh ~/profiles/my_collection.jobs
```

The first argument to `loadout-pipeline.sh` is always the path to a profile file.
If no argument is given, `examples/example.jobs` is used as the default.

---

## Installation

```bash
git clone <repo_url>
cd loadout-pipeline
chmod +x bin/loadout-pipeline.sh lib/extract.sh lib/dispatch.sh lib/precheck.sh adapters/*.sh \
         test/run_tests.sh test/validate_tests.sh test/fixtures/create_fixtures.sh
# lib/*.sh files are sourced (not executed directly) and do not need chmod +x
cp .env.example .env
```

---

## Configuration

Configuration is loaded from `.env` at startup. Copy `.env.example` to get started:

```bash
cp .env.example .env
```

All available variables (see `.env.example` for the full annotated reference):

**Pipeline core**

| Variable                | Default                    | Description                                                           |
|-------------------------|----------------------------|-----------------------------------------------------------------------|
| `DEBUG_IND`             | `0`                        | Set to `1` for verbose function entry/exit logging to stderr          |
| `MAX_UNZIP`             | `2`                        | Number of parallel extract-stage workers                              |
| `MAX_DISPATCH`          | `2`                        | Number of parallel dispatch-stage workers                             |
| `QUEUE_DIR`             | `/tmp/iso_pipeline_queue`  | Parent directory that holds the two sub-queues                        |
| `EXTRACT_QUEUE_DIR`     | `$QUEUE_DIR/extract`       | Sub-queue of archives waiting to be copied and extracted              |
| `DISPATCH_QUEUE_DIR`    | `$QUEUE_DIR/dispatch`      | Sub-queue of extracted directories waiting to be handed to an adapter |
| `EXTRACT_DIR`           | `/tmp/iso_pipeline`        | Directory where archives are extracted during processing              |
| `COPY_DIR`              | `/tmp/iso_pipeline_copies` | Parent of the per-run scratch spool; each run claims `$COPY_DIR/$$`  |
| `SPACE_OVERHEAD_PCT`    | `20`                       | Percent overhead added to raw byte requirement in space reservations  |
| `MAX_RECOVERY_ATTEMPTS` | `3`                        | Max intra-run recovery passes after SIGKILL'd worker(s) are detected  |

**SD card adapter** (`adapters/sdcard.sh`) — **implemented**

| Variable         | Default       | Description                                                  |
|------------------|---------------|--------------------------------------------------------------|
| `SD_MOUNT_POINT` | `/mnt/sdcard` | Root destination directory (any writable local path)         |

**FTP adapter** (`adapters/ftp.sh`) — stub

| Variable   | Default | Description         |
|------------|---------|---------------------|
| `FTP_HOST` |         | FTP server hostname |
| `FTP_USER` |         | FTP username        |
| `FTP_PASS` |         | FTP password        |
| `FTP_PORT` | `21`    | FTP port            |

**HDL dump adapter** (`adapters/hdl_dump.sh`) — stub

| Variable       | Default    | Description                   |
|----------------|------------|-------------------------------|
| `HDL_DUMP_BIN` | `hdl_dump` | Path to the `hdl_dump` binary |

**rclone adapter** (`adapters/rclone.sh`) — stub

| Variable           | Default | Description                                                          |
|--------------------|---------|----------------------------------------------------------------------|
| `RCLONE_REMOTE`    |         | Remote name as configured in `rclone config` (e.g. `gdrive:`)        |
| `RCLONE_DEST_BASE` |         | Base path on the remote, prepended to the job's destination          |
| `RCLONE_FLAGS`     |         | Extra flags passed through to `rclone copy`                          |

**rsync adapter** (`adapters/rsync.sh`) — stub

| Variable         | Default | Description                           |
|------------------|---------|---------------------------------------|
| `RSYNC_DEST_BASE`|         | Base path prepended to the destination |
| `RSYNC_HOST`     |         | Remote host; empty = local target     |
| `RSYNC_USER`     |         | SSH user for remote transfers         |
| `RSYNC_SSH_PORT` | `22`    | SSH port for remote transfers         |
| `RSYNC_FLAGS`    |         | Extra flags passed through to `rsync` |

Environment variables set before the call always override `.env`:

```bash
MAX_UNZIP=4 bash bin/loadout-pipeline.sh examples/sd_card.jobs
```

---

## Usage

The first argument to `loadout-pipeline.sh` is a **job file** (also called a profile) — a plain text file listing which archives to process and where to send them. You can maintain as many profiles as you like and swap between them at run time.

```bash
# Run the default profile
bash bin/loadout-pipeline.sh

# Run a named profile
bash bin/loadout-pipeline.sh examples/sd_card.jobs
bash bin/loadout-pipeline.sh examples/ftp_server.jobs
bash bin/loadout-pipeline.sh examples/mixed.jobs

# Run a profile from a custom profiles directory
bash bin/loadout-pipeline.sh ~/profiles/ps1_collection.jobs
```

### SD card — changing the destination at run time

`SD_MOUNT_POINT` is the only variable you need to change when targeting a different card or folder. The job file stays the same; the destination changes.

```bash
# Default mount point from .env
bash bin/loadout-pipeline.sh examples/sd_card.jobs

# Override the mount point at call time
SD_MOUNT_POINT=/media/mycard    bash bin/loadout-pipeline.sh examples/sd_card.jobs
SD_MOUNT_POINT=/media/backupcard bash bin/loadout-pipeline.sh examples/sd_card.jobs

# Target a plain folder on disk (no actual SD card required)
SD_MOUNT_POINT=/mnt/nas/games    bash bin/loadout-pipeline.sh examples/sd_card.jobs
SD_MOUNT_POINT=~/staging/sd_test bash bin/loadout-pipeline.sh examples/sd_card.jobs
```

### Parallelism and scratch space

```bash
# More extract workers for a fast NVMe scratch disk
MAX_UNZIP=6 bash bin/loadout-pipeline.sh examples/sd_card.jobs

# Move scratch/extraction off the system drive
EXTRACT_DIR=/mnt/nvme/extract COPY_DIR=/mnt/nvme/scratch bash bin/loadout-pipeline.sh examples/sd_card.jobs

# All three combined
MAX_UNZIP=6 EXTRACT_DIR=/mnt/nvme/extract COPY_DIR=/mnt/nvme/scratch \
    bash bin/loadout-pipeline.sh examples/sd_card.jobs
```

### Isolated runs (CI, parallel instances, one-offs)

Giving each run its own `QUEUE_DIR` prevents any cross-contamination between concurrent pipeline invocations.

```bash
# Fully isolated run — nothing touches the default /tmp dirs
QUEUE_DIR=/tmp/run_ps1 EXTRACT_DIR=/tmp/extract_ps1 COPY_DIR=/tmp/copy_ps1 \
    bash bin/loadout-pipeline.sh examples/sd_card.jobs

# Run two profiles in parallel, fully isolated from each other
QUEUE_DIR=/tmp/q_ps1 EXTRACT_DIR=/tmp/ex_ps1 \
    bash bin/loadout-pipeline.sh ~/profiles/ps1.jobs &

QUEUE_DIR=/tmp/q_ps2 EXTRACT_DIR=/tmp/ex_ps2 \
    bash bin/loadout-pipeline.sh ~/profiles/ps2.jobs &

wait
```

### Chaining profiles back-to-back

```bash
# Deliver to card first, then push the same archives to an FTP backup
bash bin/loadout-pipeline.sh ~/profiles/ps1_collection.jobs
bash bin/loadout-pipeline.sh ~/profiles/ps1_ftp_backup.jobs
```

Both runs benefit from the precheck: anything already at its destination is skipped, so re-running either profile is always safe.

### Debug output

```bash
# Print every function entry/exit and job decision to stderr
DEBUG_IND=1 bash bin/loadout-pipeline.sh examples/sd_card.jobs

# Capture debug output to a log file
DEBUG_IND=1 bash bin/loadout-pipeline.sh examples/sd_card.jobs 2>pipeline.log

# Mix debug with a custom mount point
DEBUG_IND=1 SD_MOUNT_POINT=/media/mycard bash bin/loadout-pipeline.sh examples/sd_card.jobs
```

### Combining profile + adapter override + performance tuning

```bash
# Full example: custom card, more workers, dedicated scratch, debug log
DEBUG_IND=1 \
MAX_UNZIP=4 \
SD_MOUNT_POINT=/media/mycard \
EXTRACT_DIR=/mnt/nvme/extract \
COPY_DIR=/mnt/nvme/scratch \
    bash bin/loadout-pipeline.sh ~/profiles/ps2_collection.jobs 2>ps2_run.log
```

> **Credentials belong in `.env`, not on the command line.**
> Values passed inline appear in shell history (`history`) and process listings (`ps aux`),
> making them visible to other users on the system and easy to accidentally commit.
> The examples below use `<placeholder>` notation — they are illustrative only.

```bash
# FTP adapter — put credentials in .env, not here
bash bin/loadout-pipeline.sh examples/ftp_server.jobs

# HDL dump — override binary path only if it's not on PATH
HDL_DUMP_BIN=/opt/hdl_dump/hdl_dump bash bin/loadout-pipeline.sh examples/mixed.jobs
```

---

## Job File Format

Each line must start and end with `~`, with the three fields separated by `|`:

```
~iso_path|adapter_type|adapter_destination~
```

| Field                 | Description                                              |
|-----------------------|----------------------------------------------------------|
| `iso_path`            | Absolute path to the `.7z` archive                       |
| `adapter_type`        | One of: `ftp`, `hdl`, `sd`, `rclone`, `rsync`            |
| `adapter_destination` | Adapter-specific path (see below)                        |

**Destination field by adapter:**

| Adapter  | Destination meaning                                                        |
|----------|----------------------------------------------------------------------------|
| `sd`     | Subdirectory under `SD_MOUNT_POINT` — e.g. `ps1/crash` → copies to `$SD_MOUNT_POINT/ps1/crash/` |
| `ftp`    | Remote path on the FTP server                                              |
| `hdl`    | Block device path for the PS2 HDD (e.g. `/dev/sdb`)                        |
| `rclone` | Path relative to `RCLONE_DEST_BASE` on the configured remote               |
| `rsync`  | Path relative to `RSYNC_DEST_BASE` on the local or remote host             |

Example — all five adapters in one file:

```
~/isos/ps1/crash.7z|sd|ps1/crash~
~/isos/ps1/spyro.7z|ftp|/games/ps1/spyro~
~/isos/ps2/ico.7z|hdl|/dev/sdb~
~/isos/pc/quake.7z|rclone|pc/quake~
~/isos/pc/doom.7z|rsync|games/pc/doom~
```

Blank lines and lines starting with `#` are ignored, so you can annotate profiles freely:

```
# PS1 titles — SD card slot 1
~/isos/ps1/crash.7z|sd|ps1/crash~
~/isos/ps1/spyro.7z|sd|ps1/spyro~

# PS2 titles — internal HDD
~/isos/ps2/ico.7z|hdl|/dev/sdb~
```

---

## Adapters

| Adapter  | Key      | Script                 | Status          | Env vars required                                                            |
|----------|----------|------------------------|-----------------|------------------------------------------------------------------------------|
| SD card  | `sd`     | `adapters/sdcard.sh`   | **Implemented** | `SD_MOUNT_POINT`                                                              |
| FTP      | `ftp`    | `adapters/ftp.sh`      | Stub            | `FTP_HOST`, `FTP_USER`, `FTP_PASS`, `FTP_PORT`                               |
| HDL dump | `hdl`    | `adapters/hdl_dump.sh` | Stub            | `HDL_DUMP_BIN`                                                               |
| rclone   | `rclone` | `adapters/rclone.sh`   | Stub            | `RCLONE_REMOTE`, `RCLONE_DEST_BASE`, `RCLONE_FLAGS`                          |
| rsync    | `rsync`  | `adapters/rsync.sh`    | Stub            | `RSYNC_DEST_BASE`, `RSYNC_HOST`, `RSYNC_USER`, `RSYNC_SSH_PORT`, `RSYNC_FLAGS` |

Stub adapters log what they would do but do not transfer any files. Each script contains implementation notes and a `TODO` marker showing where to add real transfer logic.

The SD card adapter (`adapters/sdcard.sh`) is fully implemented: it validates `SD_MOUNT_POINT`, creates the destination directory, and uses `rsync -a` (falling back to `cp -r` if rsync is unavailable) to copy the extracted contents. `SD_MOUNT_POINT` can be any writable local directory — an actual SD card, a USB drive, a NAS mount, or a plain folder.

To add a new adapter: create `adapters/<name>.sh`, add a matching case to `lib/dispatch.sh` and `lib/precheck.sh`, and extend the regex in `lib/jobs.sh`.

---

## Security considerations

- **The pipeline trusts its `.env` and its job file — treat both as code.** Do not point the pipeline at profiles from untrusted sources. The job-line validator rejects shell metacharacters and `..` path traversal, but a job file is ultimately an instruction list and should be controlled by you.
- **Do not run as root.** The FTP and HDL adapters may require elevated access to block devices; in those cases, run as a dedicated service user with the minimum required permissions, not as the superuser.
- **Default scratch paths are under `/tmp`, which is world-writable.** For production use, override `QUEUE_DIR`, `EXTRACT_DIR`, and `COPY_DIR` to paths you own with mode `0700`:
  ```bash
  QUEUE_DIR=/var/lib/loadout-pipeline/queue \
  EXTRACT_DIR=/var/lib/loadout-pipeline/extract \
  COPY_DIR=/var/lib/loadout-pipeline/scratch \
      bash bin/loadout-pipeline.sh ~/profiles/my_collection.jobs
  ```
  The pipeline validates that these directories are not symlinks and are owned by the current user before writing to them.
- **Keep `.env` private.** It contains credentials in plaintext. `chmod 600 .env` and never commit it (it is already listed in `.gitignore`).
- **Credentials are inherited by all worker subprocesses.** Until adapter-level credential scoping is implemented, `FTP_PASS` and other secrets are visible in the environment of every forked subprocess. Audit any custom wrapper scripts that exec from inside the pipeline accordingly.

---

## Testing

Generate fixture archives and run the full test suite:

```bash
bash test/fixtures/create_fixtures.sh
bash test/run_tests.sh
```

The suite runs 21 test cases (94 assertions) covering: default run, single worker (`MAX_UNZIP=1`), more workers than jobs, custom `QUEUE_DIR`, idempotent re-runs, custom `EXTRACT_DIR`, SD precheck skip, multi-file archive (`.bin` + `.cue`), partial-hit precheck, mid-extract failure + cleanup, rerun after failure, concurrent space reservation under scarcity, SIGKILL'd extract + spool cleanup + rerun, worker registry unit test, rclone/rsync adapter smoke tests, intra-run orphan recovery via the worker registry, phantom ledger GC after SIGKILL, mid-string `/../` rejection in the job-line parser, and a real 196 MB PS2 game archive exercising spaces and parentheses in the iso path (Test 21 — skipped automatically if the archive is absent).

To validate that every assertion in the suite can actually detect a failure:

```bash
bash test/validate_tests.sh
```

---

## Architecture

See `docs/architecture.md` for the full pipeline diagram and `ai_agent_entry_point.md` for AI agent onboarding.

---

## Contributing

- Add new adapters in `adapters/`
- Add new worker logic in `lib/`
- All jobs must respect parallelism limits (`MAX_UNZIP`) and scratch space
