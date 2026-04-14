#!/usr/bin/env bash
# test/integration/helpers/inject.sh
#
# Real failure injection for the integration suite. Every helper here
# produces the actual kernel/filesystem/process-table state the bug
# conditions would hit in production, rather than mocking them.

# ─── inject_sigkill_after ────────────────────────────────────────────────────
# Forks a watcher subshell that polls the process table for a process whose
# argv matches $pattern, waits $delay seconds, then sends SIGKILL. Used by
# the worker-crash scenarios to trigger the real recovery path without any
# trap or signal hooks inside the pipeline itself.
#
# Returns the PID of the watcher subshell so the caller can wait on or kill
# it if the test finishes before the watcher has fired.
#
# $1 pattern — argv substring to match with pgrep -f
# $2 delay   — seconds to wait after the first match (float ok)
inject_sigkill_after() {
    local pattern="$1" delay="$2"
    (
        # Poll up to 30s for the target to appear.
        local target i=0
        while (( i < 300 )); do
            target=$(pgrep -f "$pattern" 2>/dev/null | head -1)
            [[ -n "$target" ]] && break
            sleep 0.1
            i=$(( i + 1 ))
        done
        [[ -z "$target" ]] && exit 0
        sleep "$delay"
        kill -9 "$target" 2>/dev/null || true
    ) &
    printf '%s' "$!"
}

# ─── inject_dead_pid ─────────────────────────────────────────────────────────
# Forks a no-op child, reaps it, and echoes its PID. The PID is guaranteed
# dead (reaped already) by the time this function returns. Useful for
# planting fake ledger or worker-registry entries that should be treated
# as phantoms.
#
# There is a theoretical race where the kernel reuses the PID before the
# test reads it, but in practice that window is tens of milliseconds on a
# box whose PID-max is 32768+. Tests that must defend against reuse call
# `kill -0` on the returned PID and retry if it unexpectedly exists.
inject_dead_pid() {
    local pid
    ( exit 0 ) &
    pid=$!
    wait "$pid" 2>/dev/null || true
    printf '%s' "$pid"
}

# ─── inject_enospc ───────────────────────────────────────────────────────────
# No-op: there is nothing to "inject" because $INT_SCARCE is a real 6 MB
# tmpfs and writes to it produce real ENOSPC from the kernel. This helper
# exists purely for symmetry with the other injectors and to make scenario
# code self-documenting:
#
#     inject_enospc "$INT_SCARCE"
#     bash "$PIPELINE" "$jobs"   # will hit real ENOSPC
#
# The function returns 0 unconditionally and takes no action on the path.
inject_enospc() {
    local target="$1"
    if [[ ! -d "$target" ]]; then
        echo "[inject_enospc] WARN: $target does not exist" >&2
        return 1
    fi
    return 0
}
