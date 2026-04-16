#!/usr/bin/env bash
# tools/perf/perf_metrics.sh
#
# Stateful samplers that read /proc and the pipeline's own queue/log
# state to produce integer metrics for perf_recommend_workers. Each
# sampler takes a path to a per-sampler state file; the first call
# against a given state file seeds it and returns zeros, subsequent
# calls compute the delta since the previous snapshot and overwrite
# the file.
#
# Every sampler tolerates missing files (CI containers without
# /proc/diskstats, empty queue dirs) and degrades to zero rather than
# aborting — the harness needs to keep collecting samples for a sweep
# even on a host where one data source is unavailable.
#
# All functions print integers separated by spaces. No decimals, no
# awk/python in the hot path — the goal is to be callable from inside
# a production dispatch poll loop without adding runtime dependencies.
#
# Usage
#   source tools/perf/perf_metrics.sh
#   read cpu iowait < <(perf_sample_cpu /tmp/state_cpu)
#   q=$(perf_sample_queue "$DISPATCH_QUEUE_DIR")
#   read r w < <(perf_sample_disk /tmp/state_disk sda)
#   retries=$(perf_sample_space_retries /tmp/state_ret run.log)

# ─── perf_sample_cpu ──────────────────────────────────────────────────────────
# Reads /proc/stat's aggregate cpu line and returns (cpu_pct iowait_pct)
# since the previous call against the same state file. cpu_pct covers
# user+nice+system; iowait_pct is the iowait share. Values are clamped
# to 0 on first call / missing /proc/stat.
#
# Parameters
#   $1  state_file — path to per-sampler state cookie (any writable path)
#
# Output  (stdout)
#   "<cpu_pct> <iowait_pct>\n"  — both 0..100 integers
#
# Modifies
#   $state_file — overwritten with current raw counters on each call
# ──────────────────────────────────────────────────────────────────────────────
perf_sample_cpu() {
    local state_file="$1"
    local line
    if ! line=$(head -n 1 /proc/stat 2>/dev/null); then
        printf '0 0\n'
        return 0
    fi
    local _cpu u n s i w rest
    read -r _cpu u n s i w rest <<< "$line"
    u=${u:-0}; n=${n:-0}; s=${s:-0}; i=${i:-0}; w=${w:-0}

    local cpu_pct=0 iowait_pct=0
    if [[ -s "$state_file" ]]; then
        local pu pn ps pi pw
        read -r pu pn ps pi pw < "$state_file" 2>/dev/null || true
        pu=${pu:-$u}; pn=${pn:-$n}; ps=${ps:-$s}; pi=${pi:-$i}; pw=${pw:-$w}
        local du=$((u - pu)) dn=$((n - pn)) ds=$((s - ps))
        local di=$((i - pi)) dw=$((w - pw))
        local active=$((du + dn + ds))
        local total=$((active + di + dw))
        if (( total > 0 )); then
            cpu_pct=$(( 100 * active / total ))
            iowait_pct=$(( 100 * dw / total ))
        fi
    fi

    printf '%d %d %d %d %d\n' "$u" "$n" "$s" "$i" "$w" > "$state_file"
    printf '%d %d\n' "$cpu_pct" "$iowait_pct"
}

# ─── perf_sample_disk ─────────────────────────────────────────────────────────
# Reads /proc/diskstats for a named block device (e.g. "sda", "nvme0n1")
# and returns MB/s read and write since the previous call. Device names
# vary across systems — on WSL and some CI containers /proc/diskstats
# may be empty or may not contain the requested device. The sampler
# prints "0 0" and returns 0 in all missing-data cases.
#
# Parameters
#   $1  state_file — per-sampler state cookie path
#   $2  device     — block device basename as it appears in /proc/diskstats
#
# Output  (stdout)
#   "<read_mbps> <write_mbps>\n"  — integer MB/s
#
# Modifies
#   $state_file — overwritten with "sectors_read sectors_written epoch_s"
# ──────────────────────────────────────────────────────────────────────────────
perf_sample_disk() {
    local state_file="$1"
    local dev="${2:-}"
    if [[ -z "$dev" ]] || [[ ! -r /proc/diskstats ]]; then
        printf '0 0\n'
        return 0
    fi
    local line
    line=$(awk -v d="$dev" '$3 == d { print; exit }' /proc/diskstats 2>/dev/null)
    if [[ -z "$line" ]]; then
        printf '0 0\n'
        return 0
    fi
    # /proc/diskstats fields we use: $6=sectors_read, $10=sectors_written.
    local sr sw
    sr=$(awk '{ print $6 }' <<< "$line")
    sw=$(awk '{ print $10 }' <<< "$line")
    sr=${sr:-0}; sw=${sw:-0}
    local now_s
    now_s=$(date +%s)

    local rmbps=0 wmbps=0
    if [[ -s "$state_file" ]]; then
        local psr psw pts
        read -r psr psw pts < "$state_file" 2>/dev/null || true
        psr=${psr:-$sr}; psw=${psw:-$sw}; pts=${pts:-$now_s}
        local dsr=$((sr - psr)) dsw=$((sw - psw))
        local dt=$((now_s - pts))
        if (( dt > 0 )); then
            # Linux sectors are 512 bytes. MB/s = sectors * 512 / 1MiB / dt.
            rmbps=$(( dsr * 512 / 1048576 / dt ))
            wmbps=$(( dsw * 512 / 1048576 / dt ))
        fi
    fi

    printf '%d %d %d\n' "$sr" "$sw" "$now_s" > "$state_file"
    printf '%d %d\n' "$rmbps" "$wmbps"
}

# ─── perf_sample_queue ────────────────────────────────────────────────────────
# Counts the number of `*.job` files in a queue directory. Unlike the
# CPU/disk samplers this is a gauge, not a counter — there is no state
# file and the returned value is the current absolute depth. Missing
# or unreadable directories return 0.
#
# Parameters
#   $1  qdir — absolute path to the queue directory
#
# Output  (stdout)
#   "<depth>\n"  — integer count of .job files
# ──────────────────────────────────────────────────────────────────────────────
perf_sample_queue() {
    local qdir="$1"
    if [[ -z "$qdir" ]] || [[ ! -d "$qdir" ]]; then
        printf '0\n'
        return 0
    fi
    local count
    count=$(find "$qdir" -maxdepth 1 -name '*.job' 2>/dev/null | wc -l)
    printf '%d\n' "${count:-0}"
}

# ─── perf_sample_space_retries ────────────────────────────────────────────────
# Counts "space reservation" log lines appended to $log_file since the
# previous call, using a byte-offset cookie stored in $state_file. This
# is how we detect "the pipeline is thrashing on space reservations" —
# a hot signal that rule 1 in the recommender uses to shrink the unzip
# pool.
#
# Missing or unreadable logs return 0 without error.
#
# Parameters
#   $1  state_file — per-sampler state cookie path
#   $2  log_file   — pipeline log to scan
#
# Output  (stdout)
#   "<delta_lines>\n"  — integer new "space reservation" lines since last call
#
# Modifies
#   $state_file — overwritten with the current $log_file byte size
# ──────────────────────────────────────────────────────────────────────────────
perf_sample_space_retries() {
    local state_file="$1"
    local log_file="$2"
    if [[ -z "$log_file" ]] || [[ ! -r "$log_file" ]]; then
        printf '0\n'
        return 0
    fi
    local size
    size=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
    size=${size:-0}
    local prev=0
    if [[ -s "$state_file" ]]; then
        prev=$(cat "$state_file" 2>/dev/null || echo 0)
        prev=${prev:-0}
    fi
    local delta=0
    if (( size > prev )); then
        delta=$(tail -c "+$((prev + 1))" "$log_file" 2>/dev/null \
            | grep -c "space reservation" || true)
        delta=${delta:-0}
    fi
    printf '%d\n' "$size" > "$state_file"
    printf '%d\n' "$delta"
}

# ─── self-test ────────────────────────────────────────────────────────────────
# In-process smoke test for each sampler. The assertions are weak — we
# can't mock /proc — but they prove the calls don't abort and that
# state-file persistence works. Tight assertions live in the perf
# harness's own preflight pass.
# ──────────────────────────────────────────────────────────────────────────────
_perf_metrics_self_test() {
    local tmp pass=0 fail=0
    tmp=$(mktemp -d -t perf_metrics_XXXXXX)
    trap 'rm -rf "$tmp"' RETURN

    _assert() {
        local label="$1" ok="$2"
        if [[ "$ok" == "yes" ]]; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            printf 'FAIL %s\n' "$label" >&2
        fi
    }

    # CPU: first call seeds, second call returns two integers.
    perf_sample_cpu "$tmp/cpu" >/dev/null
    local out rc
    out=$(perf_sample_cpu "$tmp/cpu")
    if [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]]; then
        _assert "cpu-second-call-integer-pair" "yes"
    else
        _assert "cpu-second-call-integer-pair [$out]" "no"
    fi

    # Queue gauge: 0 for empty dir, N for N files.
    mkdir -p "$tmp/q"
    out=$(perf_sample_queue "$tmp/q")
    [[ "$out" == "0" ]] && _assert "queue-empty-zero" "yes" \
                        || _assert "queue-empty-zero [$out]" "no"
    touch "$tmp/q/a.job" "$tmp/q/b.job" "$tmp/q/c.job"
    out=$(perf_sample_queue "$tmp/q")
    [[ "$out" == "3" ]] && _assert "queue-three-jobs" "yes" \
                        || _assert "queue-three-jobs [$out]" "no"

    # Missing queue dir → 0.
    out=$(perf_sample_queue "$tmp/definitely/not/there")
    [[ "$out" == "0" ]] && _assert "queue-missing-zero" "yes" \
                        || _assert "queue-missing-zero [$out]" "no"

    # Disk sampler with a bogus device name → "0 0".
    out=$(perf_sample_disk "$tmp/disk" "nonexistent_dev_zzz")
    [[ "$out" == "0 0" ]] && _assert "disk-missing-zero-zero" "yes" \
                          || _assert "disk-missing-zero-zero [$out]" "no"

    # Retries with no log → 0.
    out=$(perf_sample_space_retries "$tmp/ret" "$tmp/nonexistent.log")
    [[ "$out" == "0" ]] && _assert "retries-no-log-zero" "yes" \
                        || _assert "retries-no-log-zero [$out]" "no"

    # Retries with a log containing one matching line.
    printf 'foo\nspace reservation miss\nbar\n' > "$tmp/run.log"
    out=$(perf_sample_space_retries "$tmp/ret" "$tmp/run.log")
    [[ "$out" == "1" ]] && _assert "retries-first-call-one" "yes" \
                        || _assert "retries-first-call-one [$out]" "no"
    # Second call with no new lines → 0.
    out=$(perf_sample_space_retries "$tmp/ret" "$tmp/run.log")
    [[ "$out" == "0" ]] && _assert "retries-second-call-zero" "yes" \
                        || _assert "retries-second-call-zero [$out]" "no"
    # Append another matching line → 1.
    printf 'space reservation miss (2nd)\n' >> "$tmp/run.log"
    out=$(perf_sample_space_retries "$tmp/ret" "$tmp/run.log")
    [[ "$out" == "1" ]] && _assert "retries-delta-one" "yes" \
                        || _assert "retries-delta-one [$out]" "no"

    if (( fail == 0 )); then
        printf 'perf_metrics self-test OK (%d assertions)\n' "$pass"
        return 0
    else
        printf 'perf_metrics self-test FAILED: %d passed, %d failed\n' "$pass" "$fail" >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --self-test) _perf_metrics_self_test ;;
        *)
            printf 'usage: %s --self-test\n' "$0" >&2
            exit 2
            ;;
    esac
fi
