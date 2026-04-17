#!/usr/bin/env bash
# tools/perf/perf_report.sh
#
# Aggregator. Reads the CSV produced by perf_harness.sh and writes two
# sibling files:
#
#   report.md   — human-readable table + Pareto winner + recommender
#                 sanity check
#   report.json — machine-readable summary the future production hook
#                 could ingest directly
#
# Pareto front logic: a combo is dominated when some other combo in the
# sweep has BOTH higher throughput AND lower retries. The "winner" is
# the non-dominated combo with the highest throughput (ties broken by
# lower retries). Retries are integer counters; throughput is computed
# as total_jobs × 1000 / wall_s so we can keep integer math and still
# display 3 decimals in the markdown table.
#
# Usage
#   bash tools/perf/perf_report.sh <results.csv> <out_dir>
#
# Arguments
#   $1  csv_path  — CSV written by perf_harness.sh
#   $2  out_dir   — existing directory to write report.md + report.json into

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERF_DIR="$ROOT_DIR/tools/perf"

source "$PERF_DIR/perf_recommender.sh"

if (( $# != 2 )); then
    printf 'usage: %s <results.csv> <out_dir>\n' "$0" >&2
    exit 2
fi

CSV="$1"
OUT="$2"

if [[ ! -f "$CSV" ]]; then
    printf 'report: missing CSV: %s\n' "$CSV" >&2
    exit 1
fi
if [[ ! -d "$OUT" ]]; then
    printf 'report: out_dir does not exist: %s\n' "$OUT" >&2
    exit 1
fi

MD="$OUT/report.md"
JSON="$OUT/report.json"

# Read all rows into parallel arrays. The CSV is small (handful of
# rows at most for smoke), so per-row awk vs single array pass does
# not matter — we favor clarity over pipeline chaining here.
us=()
ds=()
walls=()
rcs=()
retries_arr=()
tp_arr=()        # throughput × 1000 so we stay in integer math
totals=()

exec 3< "$CSV"
read -r _hdr <&3
while IFS=, read -r u d wall rc retries total <&3; do
    us+=("$u")
    ds+=("$d")
    walls+=("$wall")
    rcs+=("$rc")
    retries_arr+=("$retries")
    totals+=("$total")
    if (( wall > 0 )); then
        tp_arr+=("$(( total * 1000 / wall ))")
    else
        tp_arr+=("0")
    fi
done
exec 3<&-

num_rows=${#us[@]}
if (( num_rows == 0 )); then
    printf 'report: CSV has no data rows\n' >&2
    exit 1
fi

# ── Pareto front ─────────────────────────────────────────────────────────────
# For each row, check whether any OTHER row dominates it (strictly
# higher throughput AND strictly lower retries). Non-dominated rows
# form the front. The single "winner" is the front row with the
# highest throughput (ties → lower retries).

pareto=()
for i in "${!us[@]}"; do
    dominated=0
    for j in "${!us[@]}"; do
        (( i == j )) && continue
        if (( tp_arr[j] > tp_arr[i] && retries_arr[j] < retries_arr[i] )); then
            dominated=1
            break
        fi
    done
    pareto+=("$dominated")  # 0 = on the front, 1 = dominated
done

best_idx=-1
for i in "${!us[@]}"; do
    (( pareto[i] == 1 )) && continue
    if (( best_idx == -1 )); then
        best_idx=$i
        continue
    fi
    if (( tp_arr[i] > tp_arr[best_idx] )); then
        best_idx=$i
    elif (( tp_arr[i] == tp_arr[best_idx] && retries_arr[i] < retries_arr[best_idx] )); then
        best_idx=$i
    fi
done

best_combo="${us[best_idx]}x${ds[best_idx]}"
best_tp=${tp_arr[best_idx]}
best_retries=${retries_arr[best_idx]}

# Recommender sanity check: feed it the winner's current counts with
# synthesized "steady state" metrics (moderate CPU, quiet IO, no
# retries, short queue). The recommender's rule 1/2/3/4/5 bands are
# designed so this input produces no change — if it does not, the
# rule set has drifted from what the harness considers "steady".
sanity_line=""
if (( best_retries == 0 )); then
    recommended=$(perf_recommend_workers \
        "${us[best_idx]}" "${ds[best_idx]}" \
        50 10 40 0 1 \
        16 8)
    expected="${us[best_idx]} ${ds[best_idx]}"
    if [[ "$recommended" == "$expected" ]]; then
        sanity_line="recommender agrees (no change for steady-state inputs)"
    else
        sanity_line="recommender DISAGREES: suggested '$recommended' for winner '$expected'"
    fi
else
    sanity_line="recommender not consulted: winner has $best_retries retries (non-steady)"
fi

# ── report.md ────────────────────────────────────────────────────────────────
{
    printf '# Loadout-Pipeline Perf Sweep Report\n\n'
    printf 'Source CSV: `%s`\n\n' "$CSV"
    printf '## Results\n\n'
    printf '| Combo (U×D) | Wall (s) | RC | Retries | Jobs/s | Pareto |\n'
    printf '|---|---|---|---|---|---|\n'
    for i in "${!us[@]}"; do
        marker="-"
        (( pareto[i] == 0 )) && marker="✓"
        printf '| %dx%d | %d | %d | %d | %d.%03d | %s |\n' \
            "${us[i]}" "${ds[i]}" "${walls[i]}" "${rcs[i]}" \
            "${retries_arr[i]}" \
            "$(( tp_arr[i] / 1000 ))" "$(( tp_arr[i] % 1000 ))" \
            "$marker"
    done
    printf '\n## Pareto Winner\n\n'
    printf -- '- Combo: **%s**\n' "$best_combo"
    printf -- '- Throughput: **%d.%03d jobs/s**\n' \
        "$(( best_tp / 1000 ))" "$(( best_tp % 1000 ))"
    printf -- '- Retries: **%d**\n' "$best_retries"
    printf -- '- Wall: **%ds**\n' "${walls[best_idx]}"
    printf '\n## Recommender Sanity\n\n'
    printf '%s\n' "$sanity_line"
} > "$MD"

# ── report.json ──────────────────────────────────────────────────────────────
{
    printf '{\n'
    printf '  "best": {\n'
    printf '    "combo": "%s",\n' "$best_combo"
    printf '    "unzip": %d,\n' "${us[best_idx]}"
    printf '    "dispatch": %d,\n' "${ds[best_idx]}"
    printf '    "wall_s": %d,\n' "${walls[best_idx]}"
    printf '    "rc": %d,\n' "${rcs[best_idx]}"
    printf '    "retries": %d,\n' "$best_retries"
    printf '    "throughput_milli_jps": %d\n' "$best_tp"
    printf '  },\n'
    printf '  "results": [\n'
    first=1
    for i in "${!us[@]}"; do
        if (( first == 0 )); then printf ',\n'; fi
        first=0
        printf '    {"unzip": %d, "dispatch": %d, "wall_s": %d, "rc": %d, "retries": %d, "throughput_milli_jps": %d, "pareto_front": %s}' \
            "${us[i]}" "${ds[i]}" "${walls[i]}" "${rcs[i]}" \
            "${retries_arr[i]}" "${tp_arr[i]}" \
            "$( (( pareto[i] == 0 )) && echo true || echo false )"
    done
    printf '\n  ]\n'
    printf '}\n'
} > "$JSON"

printf '[report] wrote %s\n' "$MD"
printf '[report] wrote %s\n' "$JSON"
printf '[report] winner: %s\n' "$best_combo"
