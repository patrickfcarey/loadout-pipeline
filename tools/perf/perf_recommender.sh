#!/usr/bin/env bash
# tools/perf/perf_recommender.sh
#
# Pure recommendation function: given current worker counts and sampled
# runtime metrics, return a new (unzip, dispatch) pair. No side effects,
# no I/O beyond printing the result to stdout. Bash integer math only —
# no awk, no python, no external deps, so a future production hook can
# source this file and call the function from inside a dispatch loop
# without adding any runtime requirements.
#
# Hysteresis (wait for N consecutive identical recommendations before
# acting) is deliberately the caller's responsibility. Keeping the
# function stateless lets the harness test it with synthesized metrics
# and keeps the rule set auditable in one place. A production hook would
# wrap this call in a small "N consecutive agreements" check before
# spawning/retiring a worker.
#
# All metrics are integers. Percentages are 0..100. Counts are ≥0.
#
# Usage
#   source tools/perf/perf_recommender.sh
#   read new_u new_d < <(perf_recommend_workers $cur_u $cur_d \
#       $cpu_pct $iowait_pct $idle_pct \
#       $retry_pct $q_depth \
#       $cap_u $cap_d)
#
# CLI
#   bash tools/perf/perf_recommender.sh --self-test
#       Runs a built-in assertion suite; exits 0 on success, non-zero
#       on any failure. Keep this GREEN before hooking the function into
#       production — it is the only regression guard for the rule set.
#
#   bash tools/perf/perf_recommender.sh <9 args>
#       Calls perf_recommend_workers with the given arguments and prints
#       the result. Useful for ad-hoc sanity checks.

# ─── perf_recommend_workers ───────────────────────────────────────────────────
# Rule set (Pareto, evaluated top-down):
#
#   1. Space-bound:    retry_pct > 10       → unzip -1
#   2. CPU+headroom, hot workers:
#                       cpu_pct < 60
#                       AND iowait_pct < 20
#                       AND idle_pct < 30    → unzip +1
#   3. Unzip over-provisioned: idle_pct >= 60 → unzip -1
#
#   4. Dispatch bottleneck: q_depth > cur_d*2 AND iowait_pct < 40
#                                                → dispatch +1
#   5. Dispatch over-provisioned: idle_pct >= 60 AND q_depth < cur_d
#                                                → dispatch -1
#
# idle_pct bands used by rules 2/3/5 are deliberately non-overlapping so
# the rule set is monotone in idle_pct: under 30 = grow (if cpu/io allow),
# 30..59 = steady, 60+ = shrink. Baseline runs in the steady band report
# no change.
#
# Both pools are clamped to [1, cap_*]. Rule 1 beats rule 2 and 3 because
# space retries are the single most expensive waste mode (spool bloat +
# retries burn both IO and time). Rule 4 beats rule 5 because a growing
# queue under-dispatched costs throughput directly, while over-provision
# only wastes idle workers.
#
# Parameters (all integers)
#   $1  cur_u       — current MAX_UNZIP
#   $2  cur_d       — current MAX_DISPATCH
#   $3  cpu_pct     — 0..100, user+nice+system CPU share
#   $4  iowait_pct  — 0..100, iowait CPU share
#   $5  idle_pct    — 0..100, fraction of workers observed idle
#   $6  retry_pct   — 0..100, space-reservation retry rate
#   $7  q_depth     — dispatch queue depth (pending jobs)
#   $8  cap_u       — hard maximum for MAX_UNZIP
#   $9  cap_d       — hard maximum for MAX_DISPATCH
#
# Returns     : 0 always. Caller must always accept the recommendation
#               (the function can never refuse — a "no change" outcome
#               simply returns the current values unchanged).
# Output
#   "<new_u> <new_d>\n" on stdout
# ──────────────────────────────────────────────────────────────────────────────
perf_recommend_workers() {
    local cur_u=$1 cur_d=$2
    local cpu_pct=$3 iowait_pct=$4 idle_pct=$5
    local retry_pct=$6 q_depth=$7
    local cap_u=$8 cap_d=$9

    local new_u=$cur_u new_d=$cur_d

    if (( retry_pct > 10 )); then
        new_u=$((cur_u - 1))
    elif (( cpu_pct < 60 && iowait_pct < 20 && idle_pct < 30 )); then
        new_u=$((cur_u + 1))
    elif (( idle_pct >= 60 )); then
        new_u=$((cur_u - 1))
    fi

    if (( q_depth > cur_d * 2 && iowait_pct < 40 )); then
        new_d=$((cur_d + 1))
    elif (( idle_pct >= 60 && q_depth < cur_d )); then
        new_d=$((cur_d - 1))
    fi

    if (( new_u < 1 )); then new_u=1; fi
    if (( new_u > cap_u )); then new_u=$cap_u; fi
    if (( new_d < 1 )); then new_d=1; fi
    if (( new_d > cap_d )); then new_d=$cap_d; fi

    printf '%d %d\n' "$new_u" "$new_d"
}

# ─── self-test ────────────────────────────────────────────────────────────────
# Runs in-process assertions covering every rule branch plus clamping.
# Intended to be called from CI and from perf_harness.sh's preflight check.
# Exits 0 on success; any failure prints FAIL lines and exits 1.
# ──────────────────────────────────────────────────────────────────────────────
_perf_recommender_self_test() {
    local pass=0 fail=0
    _assert() {
        local label="$1" expected="$2" actual="$3"
        if [[ "$expected" == "$actual" ]]; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            printf 'FAIL %s — expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
        fi
    }

    # Baseline: steady state (idle in 30..59 band) → no change.
    _assert "baseline-steady" "4 2" \
        "$(perf_recommend_workers 4 2   50 10 40   0 1   16 8)"

    # Rule 1: high retry rate → unzip decreases. Dispatch unchanged
    # because idle=40 keeps rule 5 off and q=1 keeps rule 4 off.
    _assert "rule1-retries" "3 2" \
        "$(perf_recommend_workers 4 2   50 10 40   25 1   16 8)"

    # Rule 1 clamps unzip at floor=1.
    _assert "rule1-clamp-floor" "1 2" \
        "$(perf_recommend_workers 1 2   50 10 40   25 1   16 8)"

    # Rule 2: CPU+IO cool, workers hot (idle<30) → unzip increases.
    _assert "rule2-grow" "5 2" \
        "$(perf_recommend_workers 4 2   40 5 10   0 1   16 8)"

    # Rule 2 clamps unzip at cap_u.
    _assert "rule2-clamp-ceiling" "16 2" \
        "$(perf_recommend_workers 16 2   40 5 10   0 1   16 8)"

    # Rule 3: idle_pct>=60 → unzip shrinks. Rule 5 also fires on
    # dispatch because idle>=60 AND q_depth<cur_d, so both pools
    # shrink in one tick. This is intentional: high idle on a
    # single shared metric means both pools are over-provisioned.
    _assert "rule3-plus-rule5-shrink-both" "3 1" \
        "$(perf_recommend_workers 4 2   80 5 70   0 1   16 8)"

    # Rule 4: queue > 2× dispatch, IO calm → dispatch grows. idle=40
    # keeps unzip rules off so dispatch changes in isolation.
    _assert "rule4-grow-dispatch" "4 3" \
        "$(perf_recommend_workers 4 2   50 10 40   0 10   16 8)"

    # Rule 4 clamps dispatch at cap_d.
    _assert "rule4-clamp-ceiling" "4 8" \
        "$(perf_recommend_workers 4 8   50 10 40   0 100   16 8)"

    # Rule 4 suppressed under IO saturation (iowait>=40).
    _assert "rule4-suppress-iowait" "4 2" \
        "$(perf_recommend_workers 4 2   50 50 40   0 10   16 8)"

    # Rules 3 + 5: very idle pool, queue empty → both shrink.
    _assert "rule5-shrink-both-cold" "3 1" \
        "$(perf_recommend_workers 4 2   50 10 70   0 0   16 8)"

    # Dispatch floor clamp: cur_d=1 already, rule 5 tries to shrink
    # to 0, clamp returns 1. Rule 3 still shrinks unzip.
    _assert "rule5-clamp-floor" "3 1" \
        "$(perf_recommend_workers 4 1   50 10 70   0 0   16 8)"

    # Rule 1 beats rule 2 in the elif chain: retry pressure wins even
    # when idle_pct<30 would have triggered growth. Dispatch
    # unchanged because idle=10 keeps rule 5 off.
    _assert "rule1-beats-rule2" "3 2" \
        "$(perf_recommend_workers 4 2   50 10 10   25 1   16 8)"

    if (( fail == 0 )); then
        printf 'perf_recommender self-test OK (%d assertions)\n' "$pass"
        return 0
    else
        printf 'perf_recommender self-test FAILED: %d passed, %d failed\n' "$pass" "$fail" >&2
        return 1
    fi
}

# ─── CLI dispatcher ───────────────────────────────────────────────────────────
# Only runs when the file is executed directly (not when sourced).
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --self-test)
            _perf_recommender_self_test
            ;;
        "")
            printf 'usage: %s --self-test | <9 integer args>\n' "$0" >&2
            exit 2
            ;;
        *)
            if (( $# != 9 )); then
                printf 'error: perf_recommend_workers needs 9 args, got %d\n' "$#" >&2
                exit 2
            fi
            perf_recommend_workers "$@"
            ;;
    esac
fi
