#!/usr/bin/env bash
# tools/perf/perf_harness.sh
#
# Sweep driver. Runs bin/loadout-pipeline.sh against a fixture set across
# a grid of (MAX_UNZIP, MAX_DISPATCH) combinations and records wall-clock
# time, exit code, total retries, and jobs processed per combo. Emits
# one CSV row per combo and then invokes perf_report.sh to produce the
# markdown + JSON summary.
#
# Design constraints
#
#   1. Production code is NOT touched. This script only spawns
#      bin/loadout-pipeline.sh as a black box subprocess and inspects
#      its log file afterwards.
#   2. Every combo gets its own isolated EXTRACT_DIR / COPY_DIR /
#      QUEUE_DIR / LVOL_MOUNT_POINT under the out_dir so one combo's
#      scratch state cannot leak into the next.
#   3. Pure integer math — wall clock comes from `date +%s`, retries
#      come from `grep -c "space reservation miss"` on the per-run log.
#      No awk/python in the hot loop.
#
# Usage
#   tools/perf/perf_harness.sh [--smoke] [--combos "UxD,UxD,..."] \
#                              [--archives <dir>] [--out <dir>]
#
# Flags
#   --smoke          Use the built-in smoke fixture set (the three
#                    tiny .7z files under test/fixtures/isos) and cap
#                    combos to "1x1,2x2,4x2" so a CI run completes in
#                    well under two minutes. Default when no --archives
#                    is given.
#   --combos "..."   Comma-separated list of UxD pairs to sweep. Each
#                    entry must match ^[0-9]+x[0-9]+$. If --smoke is
#                    also given, --combos overrides the smoke defaults.
#   --archives <dir> Directory containing .7z archives to use as the
#                    fixture set. Every *.7z under this dir (non-recursive)
#                    becomes one job. Overrides --smoke's fixture list
#                    but not its combo defaults.
#   --out <dir>      Output directory. Created if missing. CSV + report
#                    files land here. Default: /tmp/perf_out_<pid>.
#
# Output files (inside --out)
#   results.csv      header: unzip,dispatch,wall_s,rc,retries,total_jobs
#   report.md        human-readable Pareto table (written by perf_report.sh)
#   report.json      machine-readable summary (written by perf_report.sh)
#   run_<U>x<D>.log  stdout+stderr for that combo's pipeline run
#
# Exit codes
#   0  every combo ran, CSV + report produced
#   2  CLI usage error
#   3  pre-flight failure (missing fixtures, missing pipeline entry point)
#   4  one or more combo runs failed with a non-zero rc (CSV + report
#      are still written; the caller can still inspect the rows)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERF_DIR="$ROOT_DIR/tools/perf"
PIPELINE="$ROOT_DIR/bin/loadout-pipeline.sh"

# ─── defaults ────────────────────────────────────────────────────────────────
SMOKE=0
COMBOS=""
ARCHIVES=""
OUT=""

# ─── argv parse ──────────────────────────────────────────────────────────────
while (( $# > 0 )); do
    case "$1" in
        --smoke)     SMOKE=1; shift ;;
        --combos)    COMBOS="${2:-}"; shift 2 ;;
        --archives)  ARCHIVES="${2:-}"; shift 2 ;;
        --out)       OUT="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '3,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'harness: unknown flag: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

# If neither --smoke nor --archives was given, default to smoke so the
# harness is "runnable out of the box" from a fresh clone.
if (( SMOKE == 0 )) && [[ -z "$ARCHIVES" ]]; then
    SMOKE=1
fi

if [[ -z "$COMBOS" ]]; then
    if (( SMOKE == 1 )); then
        COMBOS="1x1,2x2,4x2"
    else
        COMBOS="1x1,2x2,4x2,4x4,8x4"
    fi
fi

if [[ -z "$OUT" ]]; then
    OUT="/tmp/perf_out_$$"
fi
mkdir -p "$OUT"

# ─── pre-flight ──────────────────────────────────────────────────────────────
if [[ ! -x "$PIPELINE" ]] && [[ ! -f "$PIPELINE" ]]; then
    printf 'harness: pipeline entry point missing: %s\n' "$PIPELINE" >&2
    exit 3
fi

# Figure out the fixture set: either --archives or the smoke list under
# tools/perf/fixtures/archive_set_smoke.txt. The smoke list is data-driven
# so a future operator can tweak the sweep set without touching this
# script. Missing paths in the list are skipped silently — we only care
# that at least one listed archive resolves on disk.
SMOKE_LIST="$PERF_DIR/fixtures/archive_set_smoke.txt"
declare -a FIXTURES=()
if [[ -n "$ARCHIVES" ]]; then
    if [[ ! -d "$ARCHIVES" ]]; then
        printf 'harness: --archives dir does not exist: %s\n' "$ARCHIVES" >&2
        exit 3
    fi
    while IFS= read -r -d '' f; do
        FIXTURES+=("$f")
    done < <(find "$ARCHIVES" -maxdepth 1 -type f -name '*.7z' -print0 | sort -z)
else
    if [[ ! -f "$SMOKE_LIST" ]]; then
        printf 'harness: smoke fixture list missing: %s\n' "$SMOKE_LIST" >&2
        exit 3
    fi
    while IFS= read -r line; do
        # Strip trailing whitespace and ignore blanks + comments.
        line="${line%%#*}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        # Relative paths resolve under the repo root.
        if [[ "$line" != /* ]]; then
            line="$ROOT_DIR/$line"
        fi
        if [[ -f "$line" ]]; then
            FIXTURES+=("$line")
        fi
    done < "$SMOKE_LIST"
fi

if (( ${#FIXTURES[@]} == 0 )); then
    printf 'harness: no .7z fixtures found\n' >&2
    exit 3
fi

# ─── plan the sweep ──────────────────────────────────────────────────────────
# COMBOS is a comma-separated list; split it into parallel arrays of
# integers. Reject malformed entries eagerly so a typo in --combos does
# not surface as a cryptic pipeline failure halfway through the sweep.
declare -a UZ=() DP=()
IFS=',' read -r -a _combo_list <<< "$COMBOS"
for pair in "${_combo_list[@]}"; do
    if [[ ! "$pair" =~ ^[0-9]+x[0-9]+$ ]]; then
        printf 'harness: bad combo spec (want UxD): %s\n' "$pair" >&2
        exit 2
    fi
    UZ+=("${pair%x*}")
    DP+=("${pair#*x}")
done

printf '[harness] sweep: %d combos × %d fixtures → %s\n' \
    "${#UZ[@]}" "${#FIXTURES[@]}" "$OUT"

# ─── build the jobs file ─────────────────────────────────────────────────────
# One job per fixture, all using the sd adapter pointed at a per-combo
# scratch dir. Using sd keeps the harness self-contained: no network,
# no external processes, no test doubles beyond what already lives in
# adapters/lvol.sh. Dest paths are unique per fixture so two concurrent
# dispatchers cannot collide.
JOBS_FILE="$OUT/harness.jobs"
{
    printf '# Auto-generated by perf_harness.sh — do not edit manually.\n'
    idx=0
    for f in "${FIXTURES[@]}"; do
        idx=$((idx + 1))
        printf '~%s|lvol|games/perf_%d~\n' "$f" "$idx"
    done
} > "$JOBS_FILE"
TOTAL_JOBS=${#FIXTURES[@]}

# ─── CSV header ──────────────────────────────────────────────────────────────
CSV="$OUT/results.csv"
printf 'unzip,dispatch,wall_s,rc,retries,total_jobs\n' > "$CSV"

# ─── run each combo ──────────────────────────────────────────────────────────
any_failed=0
for i in "${!UZ[@]}"; do
    u=${UZ[i]} d=${DP[i]}
    label="${u}x${d}"
    log_file="$OUT/run_${label}.log"

    # Per-combo scratch so state never leaks between runs.
    combo_root="$OUT/scratch_${label}"
    rm -rf "$combo_root"
    mkdir -p "$combo_root/sd" "$combo_root/extract" "$combo_root/copy" \
             "$combo_root/queue"

    printf '[harness] run %s (%d/%d)…\n' "$label" "$((i + 1))" "${#UZ[@]}"

    rc=0
    start_s=$(date +%s)
    env \
        MAX_UNZIP="$u" \
        MAX_DISPATCH="$d" \
        LVOL_MOUNT_POINT="$combo_root/sd" \
        EXTRACT_DIR="$combo_root/extract" \
        COPY_DIR="$combo_root/copy" \
        QUEUE_DIR="$combo_root/queue" \
        ALLOW_STUB_ADAPTERS=1 \
        RESUME_PLANNER_IND=0 \
        bash "$PIPELINE" "$JOBS_FILE" \
        > "$log_file" 2>&1 || rc=$?
    end_s=$(date +%s)
    wall=$((end_s - start_s))
    (( wall < 0 )) && wall=0

    # Retries are counted from the dispatch worker's own log line.
    # grep -c prints its count AND returns rc=1 when zero matches, so
    # `|| printf 0` would concatenate "0\n0". Use `|| true` to swallow
    # the non-zero rc without appending anything to stdout.
    retries=0
    if [[ -s "$log_file" ]]; then
        retries=$(grep -c "space reservation miss" "$log_file" 2>/dev/null || true)
        retries=${retries:-0}
    fi

    printf '%d,%d,%d,%d,%d,%d\n' \
        "$u" "$d" "$wall" "$rc" "$retries" "$TOTAL_JOBS" >> "$CSV"

    if (( rc != 0 )); then
        any_failed=1
        printf '[harness]   rc=%d wall=%ds retries=%d (FAILED, see %s)\n' \
            "$rc" "$wall" "$retries" "$log_file"
    else
        printf '[harness]   rc=%d wall=%ds retries=%d\n' "$rc" "$wall" "$retries"
    fi

    # Tidy up scratch dir — keep the log file, drop everything else.
    rm -rf "$combo_root"
done

# ─── aggregate ───────────────────────────────────────────────────────────────
printf '[harness] aggregating → %s/report.md\n' "$OUT"
bash "$PERF_DIR/perf_report.sh" "$CSV" "$OUT"

if (( any_failed == 1 )); then
    printf '[harness] sweep finished with at least one failed combo (rc=4)\n' >&2
    exit 4
fi

printf '[harness] done\n'
