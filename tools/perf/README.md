# loadout-pipeline perf framework

Worker-count tuning for `bin/loadout-pipeline.sh`. Given a fixture set
and a grid of `(MAX_UNZIP, MAX_DISPATCH)` combinations, this framework
runs the real pipeline against each combination, records wall-clock
throughput + retries + exit status, and emits a Pareto-ranked
recommendation. The recommendation logic is isolated in a pure function
(`perf_recommend_workers`) so a future production hook can call it
from inside a running dispatch loop without adding any runtime
dependencies.

**Nothing in this directory is linked into the production bundle.**
`build/bundle.sh` only inlines files under `lib/`, `adapters/`, and
`bin/loadout-pipeline.sh`, so `tools/perf/` is structurally invisible
to `dist/loadout-pipeline.sh`. You can add, delete, or rewrite any file
in here without changing the shipped artifact one byte.

## Files

| File | Purpose |
|---|---|
| `perf_recommender.sh` | Pure function `perf_recommend_workers` — metrics in, `(unzip, dispatch)` out. No I/O, no state. Self-tested via `--self-test`. |
| `perf_metrics.sh`     | Stateful samplers for `/proc/stat`, `/proc/diskstats`, the dispatch queue, and the "space reservation" log signal. Self-tested via `--self-test`. |
| `perf_harness.sh`     | Sweep driver. Runs the real pipeline for each combo, writes `results.csv`, calls `perf_report.sh`. |
| `perf_report.sh`      | Aggregator. CSV in, `report.md` + `report.json` out. Computes the Pareto front and cross-checks the recommender on the winner. |
| `fixtures/archive_set_smoke.txt` | Three-archive smoke fixture list, one path per line (relative to repo root). |

## Quick start

From the repo root:

```bash
# Smoke sweep (3 fixtures × 3 combos, well under 2 minutes on CI).
bash tools/perf/perf_harness.sh --smoke --out /tmp/perf_out

# View the markdown summary.
cat /tmp/perf_out/report.md

# Inspect raw rows for ad-hoc plotting.
column -s, -t < /tmp/perf_out/results.csv
```

`report.md` contains a throughput table with a Pareto-front marker
column and a "Pareto Winner" block. `report.json` has the same data
in machine-readable form for downstream tools.

### Custom sweeps

```bash
# Sweep a user-provided fixture set with a different combo grid.
bash tools/perf/perf_harness.sh \
    --archives /path/to/my/iso_set \
    --combos "2x2,4x2,4x4,8x4,8x8" \
    --out /tmp/perf_myset
```

`--combos` entries must match `UxD` (two positive integers separated
by `x`). `--archives` takes a directory whose non-recursive `*.7z`
children become the job set, one job per archive. Each combo runs
with its own isolated scratch directories so runs do not pollute
each other.

### Self-tests

Every file that declares functions ships with a `--self-test` mode.
Run them whenever you change the rule set or the samplers:

```bash
bash tools/perf/perf_recommender.sh --self-test   # 12 assertions
bash tools/perf/perf_metrics.sh     --self-test   # 9  assertions
```

## Recommender algorithm

`perf_recommend_workers` takes nine integer arguments and prints two
integers (`new_unzip new_dispatch`):

```
perf_recommend_workers \
    cur_unzip cur_dispatch \
    cpu_pct iowait_pct idle_pct \
    retry_pct q_depth \
    cap_unzip cap_dispatch
```

Rules (Pareto, evaluated top-down; see `perf_recommender.sh:38-61` for
the rationale):

1. **Space-bound.** `retry_pct > 10` → `unzip -1`. Space reservation
   thrash is the single most expensive waste mode, so it outranks
   every other rule for the unzip pool.
2. **CPU+IO headroom, hungry workers.** `cpu < 60 && iowait < 20 &&
   idle < 30` → `unzip +1`. The host has spare cycles and the pool
   is saturated.
3. **Unzip over-provisioned.** `idle_pct >= 60` → `unzip -1`.
4. **Dispatch bottleneck.** `q_depth > 2 * cur_dispatch && iowait <
   40` → `dispatch +1`. Queue growing faster than dispatch can drain
   it, and the host is not IO-saturated.
5. **Dispatch over-provisioned.** `idle_pct >= 60 && q_depth <
   cur_dispatch` → `dispatch -1`.

The `idle_pct` bands are deliberately non-overlapping: `< 30` = grow,
`30..59` = steady, `>= 60` = shrink. Baseline runs in the steady band
report no change. Both pools clamp to `[1, cap_*]`.

## Future production hook (not applied by this PR)

The recommender is stateless and allocation-free, so a production hook
can `source` it directly from inside `lib/workers.sh` and call it from
the dispatch poll loop. The hook below is **not applied today** — it
is documented here so the shape of the future change is visible.

```bash
# hypothetical diff against lib/workers.sh, near dispatch_worker's poll loop
#
#   source "$ROOT_DIR/tools/perf/perf_recommender.sh"
#   source "$ROOT_DIR/tools/perf/perf_metrics.sh"
#
#   _perf_state_cpu="$QUEUE_DIR/.perf_cpu"
#   _perf_state_ret="$QUEUE_DIR/.perf_ret"
#   _last_adjust_epoch=0
#   _adjust_interval_sec=30
#
#   while dispatch_worker_should_keep_polling; do
#       # ... existing poll body ...
#
#       now=$(date +%s)
#       if (( now - _last_adjust_epoch >= _adjust_interval_sec )); then
#           read cpu iow < <(perf_sample_cpu "$_perf_state_cpu")
#           q=$(perf_sample_queue "$DISPATCH_QUEUE_DIR")
#           retries=$(perf_sample_space_retries "$_perf_state_ret" "$LOG_FILE")
#           # idle_pct and retry_pct would be computed from worker
#           # registry counts + retries-over-window; caps come from
#           # config. The recommender itself stays the same.
#           read new_u new_d < <(perf_recommend_workers \
#               "$MAX_UNZIP" "$MAX_DISPATCH" \
#               "$cpu" "$iow" "$idle_pct" \
#               "$retry_pct" "$q" \
#               "$MAX_UNZIP_CAP" "$MAX_DISPATCH_CAP")
#           if (( new_u != MAX_UNZIP || new_d != MAX_DISPATCH )); then
#               # Production hook would spawn/retire workers here.
#               # A hysteresis wrapper (N consecutive identical
#               # recommendations before acting) should live in the
#               # caller, NOT in perf_recommend_workers itself.
#               :
#           fi
#           _last_adjust_epoch=$now
#       fi
#   done
```

Two design notes for whoever writes that hook later:

- **Hysteresis belongs to the caller.** `perf_recommend_workers` is
  stateless on purpose — a production hook that wants to avoid
  flapping should require N consecutive identical recommendations
  before spawning or retiring a worker. Keeping that state out of
  the function lets the harness test the rule set with synthesized
  metrics and keeps the auditable rule list in one file.
- **`tools/perf/` is not in the bundle.** Sourcing it from `lib/` is
  fine during development, but before shipping, the hook will need
  to either (a) move the two files into `lib/` so `build/bundle.sh`
  inlines them, or (b) teach `build/bundle.sh` about `tools/perf/`.
  Option (a) is smaller and keeps the bundle contract unchanged.

## Limits and gotchas

- **Wall clock is measured in whole seconds.** `date +%s` resolution
  is fine for real fixtures (tens to hundreds of seconds per combo),
  but a smoke run on 150-byte archives can report `wall_s=0` for
  the fastest combos. The report handles that by treating zero-wall
  rows as zero throughput rather than dividing by zero.
- **`/proc/diskstats` is optional.** CI containers and some WSL
  setups do not expose it, and the disk sampler degrades to `0 0`
  instead of aborting. Treat disk MB/s as advisory.
- **The pipeline's own logs are the retry source of truth.** The
  harness greps `"space reservation miss"` out of the per-run log
  to count retries, matching the production log line in
  `lib/workers.sh`. If that string is ever renamed, update the
  harness and `perf_sample_space_retries` in lockstep.
- **`ALLOW_STUB_ADAPTERS=1` is forced** for every harness run so
  the default-refuse guard added in suite 20 does not short-circuit
  the sweep. The sweep only uses the `sd` adapter today anyway; the
  flag is belt-and-braces for future multi-adapter sweeps.
