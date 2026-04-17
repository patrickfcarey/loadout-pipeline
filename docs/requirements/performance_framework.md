# Subsystem: Performance Framework

**Compat status**: tools-tier. All contracts documented here are
allowed to churn until the first real production sweep. The function
signatures, rule-set thresholds, and CSV schema may all change without
a migration note, as long as the self-test suites are updated in sync.

The performance framework lives under `tools/perf/` and is deliberately
separated from `lib/` — production code never sources it. It provides:
- **Samplers** (`perf_metrics.sh`) — stateful readers of `/proc` and
  pipeline state that produce integer metrics.
- **Recommender** (`perf_recommender.sh`) — a pure function that maps
  metrics → new (MAX_UNZIP, MAX_DISPATCH) worker counts.
- **Harness** (`perf_harness.sh`) — a sweep driver that runs the
  pipeline across a grid of worker count combos.
- **Report** (`perf_report.sh`) — a Pareto-front aggregator that
  reads the harness CSV and writes markdown + JSON summaries.

### `perf_sample_cpu`

**Source**: `tools/perf/perf_metrics.sh:42`
**Visibility**: public
**Test coverage**: `_perf_metrics_self_test` inline self-test

**Signature**
```
perf_sample_cpu <state_file>
```

| Position | Name       | Type | Constraint                                   |
| -------: | ---------- | ---- | -------------------------------------------- |
|       $1 | state_file | path | Per-sampler state cookie. Any writable path. |

**Returns**: `0` always.
**Stdout**: `<cpu_pct> <iowait_pct>\n` — both 0..100 integers.
**Stderr**: silent.

**Preconditions**: none — degrades to `0 0` if `/proc/stat` is missing.

**Postconditions**

- `$state_file` has been overwritten with the current raw counters.
- On first call (empty or missing state file): `0 0` printed. The
  state file is seeded so the next call computes a real delta.

**Invariants**

- `cpu_pct` covers user + nice + system. `iowait_pct` is the iowait
  share. Both are computed as deltas since the previous call.
- Integer division truncates toward zero; no rounding.
- A missing `/proc/stat` (CI containers, WSL) prints `0 0` and
  returns 0. The harness needs to keep collecting samples for a
  sweep even on hosts where one data source is unavailable.
- Previous state is read with `|| true` so a corrupt state file
  degrades to a zeroed delta rather than aborting.

**Side effects**

- Reads `/proc/stat`.
- Writes `$state_file`.

**Error modes**: none surfaced.

**Example**
```bash
read cpu iowait < <(perf_sample_cpu /tmp/state_cpu)
```

### `perf_sample_disk`

**Source**: `tools/perf/perf_metrics.sh:89`
**Visibility**: public
**Test coverage**: `_perf_metrics_self_test` inline self-test

**Signature**
```
perf_sample_disk <state_file> <device>
```

| Position | Name       | Type   | Constraint                                                             |
| -------: | ---------- | ------ | ---------------------------------------------------------------------- |
|       $1 | state_file | path   | Per-sampler state cookie.                                              |
|       $2 | device     | string | Block device basename as in `/proc/diskstats` (e.g. `sda`, `nvme0n1`). |

**Returns**: `0` always.
**Stdout**: `<read_mbps> <write_mbps>\n` — integer MB/s.
**Stderr**: silent.

**Preconditions**: none — degrades to `0 0` on missing device or
missing `/proc/diskstats`.

**Postconditions**

- `$state_file` has been overwritten with
  `<sectors_read> <sectors_written> <epoch_s>`.

**Invariants**

- Linux sectors are 512 bytes. MB/s =
  `sectors * 512 / 1048576 / dt_seconds`.
- Empty device or missing `/proc/diskstats` → `0 0`, no error.
- Device lookup is exact: `awk '$3 == d'` matches the full device
  basename, not a prefix. A query for `sda` does not match `sda1`.
- State file uses epoch seconds for the time delta, not nanoseconds.
  At MB/s granularity, second-resolution is sufficient.

**Side effects**

- Reads `/proc/diskstats` via awk.
- Writes `$state_file`.

**Error modes**: none surfaced.

**Example**
```bash
read rmbps wmbps < <(perf_sample_disk /tmp/state_disk sda)
```

### `perf_sample_queue`

**Source**: `tools/perf/perf_metrics.sh:140`
**Visibility**: public
**Test coverage**: `_perf_metrics_self_test` inline self-test

**Signature**
```
perf_sample_queue <qdir>
```

| Position | Name | Type          | Constraint                |
| -------: | ---- | ------------- | ------------------------- |
|       $1 | qdir | absolute path | Queue directory to probe. |

**Returns**: `0` always.
**Stdout**: `<depth>\n` — integer count of `.job` files.
**Stderr**: silent.

**Preconditions**: none — degrades to `0` on missing or unreadable dir.

**Postconditions**: pure probe — no state file, no mutation.

**Invariants**

- This is a **gauge**, not a counter. No state file; the returned
  value is the current absolute depth.
- Uses `find -maxdepth 1 -name '*.job'`, matching the queue's own
  file naming convention (`<nanosec>.<pid>.job`).
- Missing or unreadable directory → `0`, not an error.

**Side effects**

- Runs `find` on `$qdir`.

**Error modes**: none surfaced.

**Example**
```bash
q=$(perf_sample_queue "$DISPATCH_QUEUE_DIR")
```

### `perf_sample_space_retries`

**Source**: `tools/perf/perf_metrics.sh:170`
**Visibility**: public
**Test coverage**: `_perf_metrics_self_test` inline self-test

**Signature**
```
perf_sample_space_retries <state_file> <log_file>
```

| Position | Name       | Type | Constraint                 |
| -------: | ---------- | ---- | -------------------------- |
|       $1 | state_file | path | Per-sampler state cookie.  |
|       $2 | log_file   | path | Pipeline log file to scan. |

**Returns**: `0` always.
**Stdout**: `<delta_lines>\n` — integer new "space reservation"
lines since the last call.
**Stderr**: silent.

**Preconditions**: none — degrades to `0` on missing or unreadable log.

**Postconditions**

- `$state_file` has been overwritten with the current byte size of
  `$log_file`.

**Invariants**

- Uses a byte-offset cookie: `stat -c %s` captures the file size,
  then `tail -c "+$((prev + 1))"` reads only the new bytes.
  This makes the sampler O(delta) rather than O(total log size).
- The pattern matched is the literal string `"space reservation"`.
  This is coupled to the `log_trace` line in `lib/extract.sh:174`.
  Changing that log line without updating this sampler would break
  retry detection.
- `grep -c ... || true` prevents the `set -e` abort that `grep`
  triggers when zero matches produce rc=1.

**Side effects**

- Reads `$log_file` from the previous offset.
- Writes `$state_file`.

**Error modes**: none surfaced.

**Example**
```bash
retries=$(perf_sample_space_retries /tmp/state_ret run.log)
```

### `_perf_metrics_self_test`

**Source**: `tools/perf/perf_metrics.sh:201`
**Visibility**: private (invoked via `--self-test` CLI)
**Test coverage**: self-contained

**Signature**
```
_perf_metrics_self_test
```

Takes no arguments.

**Returns**: `0` if all assertions pass, `1` on any failure.
**Stdout**: summary line `"perf_metrics self-test OK (N assertions)"`.
**Stderr**: `FAIL <label>` lines for each failed assertion.

**Preconditions**: all `perf_sample_*` functions defined.

**Postconditions**: temp directory created and cleaned up via a
RETURN trap.

**Invariants**

- Assertions are intentionally **weak** — we cannot mock `/proc`.
  They prove the samplers don't abort and that state-file
  persistence works. Tight assertions live in the perf harness's
  own preflight pass.
- CPU: first call seeds, second call returns an integer pair.
- Queue: empty dir → 0, three `.job` files → 3, missing dir → 0.
- Disk: bogus device → `0 0`.
- Space retries: no log → 0, one match → 1, no new lines → 0,
  one new appended match → 1.

**Side effects**: creates and removes a temp directory.

**Error modes**: rc=1 on any failed assertion.

**Example**
```bash
bash tools/perf/perf_metrics.sh --self-test
```

### `perf_recommend_workers`

**Source**: `tools/perf/perf_recommender.sh:80`
**Visibility**: public
**Test coverage**: `_perf_recommender_self_test` inline self-test

**Signature**
```
perf_recommend_workers <cur_u> <cur_d> <cpu_pct> <iowait_pct> <idle_pct> <retry_pct> <q_depth> <cap_u> <cap_d>
```

| Position | Name       | Type    | Constraint                                 |
| -------: | ---------- | ------- | ------------------------------------------ |
|       $1 | cur_u      | integer | Current MAX_UNZIP.                         |
|       $2 | cur_d      | integer | Current MAX_DISPATCH.                      |
|       $3 | cpu_pct    | integer | 0..100, user+nice+system CPU share.        |
|       $4 | iowait_pct | integer | 0..100, iowait CPU share.                  |
|       $5 | idle_pct   | integer | 0..100, fraction of workers observed idle. |
|       $6 | retry_pct  | integer | 0..100, space-reservation retry rate.      |
|       $7 | q_depth    | integer | Dispatch queue depth (pending jobs).       |
|       $8 | cap_u      | integer | Hard maximum for MAX_UNZIP.                |
|       $9 | cap_d      | integer | Hard maximum for MAX_DISPATCH.             |

**Returns**: `0` always.
**Stdout**: `<new_u> <new_d>\n` — recommended worker counts.
**Stderr**: silent.

**Preconditions**: all 9 arguments are integers.

**Postconditions**: pure — no state change.

**Invariants**

- **Rule set** (Pareto, evaluated top-down via `elif` chain):

| # | Condition                                            | Effect      |
| --: | ---------------------------------------------------- | ----------- |
| 1 | `retry_pct > 10`                                     | unzip −1    |
| 2 | `cpu_pct < 60 AND iowait_pct < 20 AND idle_pct < 30` | unzip +1    |
| 3 | `idle_pct >= 60`                                     | unzip −1    |
| 4 | `q_depth > cur_d*2 AND iowait_pct < 40`              | dispatch +1 |
| 5 | `idle_pct >= 60 AND q_depth < cur_d`                 | dispatch −1 |

- **Priority**: rule 1 beats rule 2 in the `elif` chain. Space
  retries are the single most expensive waste mode (spool bloat +
  retries burn both IO and time). Rule 4 beats rule 5 because a
  growing under-dispatched queue costs throughput directly.
- **idle_pct bands are non-overlapping**: <30 = grow (if cpu/io
  allow), 30..59 = steady (no change), ≥60 = shrink. Baseline runs
  in the steady band report no change.
- Both pools clamped to `[1, cap_*]` after the rules fire.
- Hysteresis (N consecutive agreements before acting) is
  **deliberately the caller's responsibility**. The function is
  stateless so the harness can test it with synthesized metrics.
- No external dependencies. Bash integer math only.

**Side effects**: none.

**Error modes**: none — the function always produces a valid
(new_u, new_d) pair.

**Example**
```bash
read new_u new_d < <(perf_recommend_workers 4 2  50 10 40  0 1  16 8)
# → "4 2" (steady state, no change)
```

### `_perf_recommender_self_test`

**Source**: `tools/perf/perf_recommender.sh:115`
**Visibility**: private (invoked via `--self-test` CLI)
**Test coverage**: self-contained

**Signature**
```
_perf_recommender_self_test
```

Takes no arguments.

**Returns**: `0` if all assertions pass, `1` on any failure.
**Stdout**: summary line `"perf_recommender self-test OK (N assertions)"`.
**Stderr**: `FAIL <label> — expected [X], got [Y]` for each failure.

**Preconditions**: `perf_recommend_workers` defined.

**Postconditions**: no state change.

**Invariants**

- Covers every rule branch plus floor/ceiling clamping:
  - Baseline steady → no change
  - Rule 1: retries → unzip shrinks, clamp at floor=1
  - Rule 2: CPU cool + workers hot → unzip grows, clamp at cap
  - Rule 3 + 5: idle ≥ 60 → both pools shrink
  - Rule 4: queue deep + IO calm → dispatch grows, clamp at cap
  - Rule 4 suppressed under IO saturation
  - Rule 1 beats rule 2 in priority
- Each assertion is `_assert "label" "expected" "actual"` — the
  label names the rule being tested, the expected value is the
  rule-set output, and the actual value is `$(perf_recommend_workers ...)`.

**Side effects**: none.

**Error modes**: rc=1 on any failed assertion.

**Example**
```bash
bash tools/perf/perf_recommender.sh --self-test
```

### Script contract: `tools/perf/perf_harness.sh`

**Source**: `tools/perf/perf_harness.sh:1`
**Visibility**: script (invoked as `bash tools/perf/perf_harness.sh [flags]`)
**Test coverage**: none — manual verification by running `--smoke`

**Invocation**
```
bash tools/perf/perf_harness.sh [--smoke] [--combos "UxD,UxD,..."] \
                                [--archives <dir>] [--out <dir>]
```

| Flag               | Purpose                                                                                                        |
| ------------------ | -------------------------------------------------------------------------------------------------------------- |
| `--smoke`          | Use built-in smoke fixtures (3 tiny .7z files under `test/fixtures/isos`). Default when no `--archives` given. |
| `--combos "..."`   | Comma-separated `UxD` pairs. Overrides smoke defaults if both given.                                           |
| `--archives <dir>` | Directory of `.7z` archives as the fixture set.                                                                |
| `--out <dir>`      | Output directory. Default: `/tmp/perf_out_<pid>`.                                                              |

**Env dependencies**: none — all pipeline env vars are set per-combo
via `env` before each subprocess. `ALLOW_STUB_ADAPTERS=1` and
`RESUME_PLANNER_IND=0` are always set.

**Returns**:

|  rc | Meaning                                                                 |
| --: | ----------------------------------------------------------------------- |
| `0` | Every combo ran; CSV + report produced.                                 |
| `2` | CLI usage error.                                                        |
| `3` | Preflight failure (missing fixtures, missing pipeline entry point).     |
| `4` | One or more combos failed with non-zero rc; CSV + report still written. |

**Output files** (inside `--out`):
- `results.csv` — header: `unzip,dispatch,wall_s,rc,retries,total_jobs`
- `report.md` — Pareto table (written by `perf_report.sh`)
- `report.json` — machine-readable summary
- `run_<U>x<D>.log` — per-combo pipeline stdout + stderr

**Invariants**

- Production code is **not touched**. The harness spawns
  `bin/loadout-pipeline.sh` as a black-box subprocess.
- Every combo gets its own isolated scratch dirs (EXTRACT_DIR,
  COPY_DIR, QUEUE_DIR, LVOL_MOUNT_POINT) so one combo's state cannot
  leak into the next.
- Scratch dirs are cleaned up after each combo; only the log file
  survives.
- `grep -c "space reservation miss" ... || true` counts retries
  without aborting on zero matches.
- `wall_s` is wall-clock via `date +%s` (second-resolution).
- Negative wall time (clock skew) is clamped to 0.

**Side effects**

- Creates and populates `$OUT`.
- Spawns one full pipeline run per combo.
- Invokes `perf_report.sh` at the end.

**Error modes**: see return codes above.

**Example**
```bash
bash tools/perf/perf_harness.sh --smoke --out /tmp/perf
cat /tmp/perf/report.md
```

### Script contract: `tools/perf/perf_report.sh`

**Source**: `tools/perf/perf_report.sh:1`
**Visibility**: script (invoked as `bash tools/perf/perf_report.sh <csv> <out_dir>`)
**Test coverage**: none — exercised indirectly by `perf_harness.sh`

**Invocation**
```
bash tools/perf/perf_report.sh <results.csv> <out_dir>
```

| Position | Name     | Type | Constraint                           |
| -------: | -------- | ---- | ------------------------------------ |
|       $1 | csv_path | path | CSV written by `perf_harness.sh`.    |
|       $2 | out_dir  | path | Existing directory for report files. |

**Returns**: `0` on success, `1` on missing CSV or empty data, `2` on usage error.
**Stdout**: `[report] wrote ...` lines.
**Stderr**: error messages on failure.

**Preconditions**

- CSV exists and has at least one data row.
- `$out_dir` exists.
- `perf_recommender.sh` is sourceable (same directory).

**Postconditions**

- `$out_dir/report.md` and `$out_dir/report.json` exist.

**Invariants**

- Pareto front: a combo is dominated when some other combo has BOTH
  higher throughput AND lower retries. The "winner" is the
  non-dominated combo with the highest throughput (ties broken by
  lower retries).
- Throughput is `total_jobs × 1000 / wall_s` — integer math with
  3-decimal display in markdown (`$((tp / 1000)).$(printf '%03d' $((tp % 1000)))`)`.
- Recommender sanity check: the winner's counts are fed to
  `perf_recommend_workers` with synthesized steady-state metrics.
  If the recommender disagrees (suggests a change for inputs that
  should produce no change), the report flags it. This catches
  rule-set drift.
- JSON output uses no external tools — just `printf` formatting.

**Side effects**

- Sources `perf_recommender.sh`.
- Writes `report.md` and `report.json` into `$out_dir`.

**Error modes**: rc=1 on missing CSV or empty data.

**Example**
```bash
bash tools/perf/perf_report.sh /tmp/perf/results.csv /tmp/perf
```
