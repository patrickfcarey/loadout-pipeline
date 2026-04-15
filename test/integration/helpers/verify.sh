#!/usr/bin/env bash
# test/integration/helpers/verify.sh
#
# Real-filesystem assertions for the integration suite. Every helper here
# operates on bytes in the filesystem — not log lines — so regressions
# that corrupt content without corrupting logs still surface loudly.

# ─── tree_hash ───────────────────────────────────────────────────────────────
# Deterministic, order-stable sha256 of a directory tree. The hash is taken
# over a sorted list of (relative_path, size, sha256) tuples for every
# regular file. Directories, symlinks and special files are ignored — the
# pipeline only produces regular files, so this keeps the invariant tight.
#
# NOTE: file mode is intentionally excluded. vfat normalises Unix permissions
# for all files it stores (e.g. all files get 555 regardless of what was
# written). Including mode would cause spurious mismatches whenever the
# expected tree lives on ext4/tmpfs and the actual tree lives on the vfat
# SD card loopback. Content identity (path + size + sha256) is sufficient.
#
# Two directories compare equal iff every file is present in both AND the
# bytes and size match exactly. Using `LC_ALL=C sort` locks the ordering so
# locale drift cannot cause spurious diffs.
tree_hash() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "TREE_HASH_MISSING_DIR:$dir"
        return 1
    fi
    (
        cd "$dir" || exit 1
        # find -print0 + while IFS= read -r -d '' file handles paths with
        # spaces, newlines, and all the pathological characters our iso_path
        # regex explicitly allows (parens, brackets, etc).
        find . -type f -print0 \
          | LC_ALL=C sort -z \
          | while IFS= read -r -d '' f; do
                # Strip the leading "./" so canonical relative paths match
                # across tree copies taken from different roots.
                local rel="${f#./}"
                local size hash
                size=$(stat -c '%s' "$f")
                hash=$(sha256sum "$f" | awk '{print $1}')
                printf '%s\t%s\t%s\n' "$rel" "$size" "$hash"
            done
    ) | sha256sum | awk '{print $1}'
}

# ─── assert_tree_eq ──────────────────────────────────────────────────────────
# Fail-loud tree comparison using tree_hash (path + size + sha256, no mode).
# On mismatch, prints the first diverging file so the operator can jump
# straight to the defect instead of staring at a hash.
assert_tree_eq() {
    local expected_dir="$1" actual_dir="$2" label="${3:-tree}"
    local exp_hash act_hash
    exp_hash=$(tree_hash "$expected_dir") || { fail "$label: expected tree missing: $expected_dir"; return; }
    act_hash=$(tree_hash "$actual_dir")   || { fail "$label: actual tree missing: $actual_dir"; return; }
    if [[ "$exp_hash" == "$act_hash" ]]; then
        pass "$label: trees match ($exp_hash)"
        return
    fi
    fail "$label: tree hash mismatch"
    echo "      expected: $exp_hash  ($expected_dir)"
    echo "      actual:   $act_hash  ($actual_dir)"
    # Show the first byte-level divergence. diff exits non-zero when files
    # differ; suppress that so set -e doesn't kill the caller's subshell.
    diff -r "$expected_dir" "$actual_dir" 2>&1 | sed 's/^/      /' | head -20 || true
}

# ─── assert_file_eq ──────────────────────────────────────────────────────────
assert_file_eq() {
    local a="$1" b="$2" label="${3:-file}"
    if [[ ! -f "$a" ]]; then fail "$label: missing $a"; return; fi
    if [[ ! -f "$b" ]]; then fail "$label: missing $b"; return; fi
    local ha hb
    ha=$(sha256sum "$a" | awk '{print $1}')
    hb=$(sha256sum "$b" | awk '{print $1}')
    if [[ "$ha" == "$hb" ]]; then
        pass "$label: $a == $b ($ha)"
    else
        fail "$label: sha256 mismatch between $a ($ha) and $b ($hb)"
    fi
}

# ─── assert_file_present / assert_file_absent ───────────────────────────────
assert_file_present() {
    local path="$1" label="${2:-file}"
    if [[ -f "$path" ]]; then
        pass "$label present: $path"
    else
        fail "$label missing: $path"
    fi
}
assert_file_absent() {
    local path="$1" label="${2:-file}"
    if [[ ! -e "$path" ]]; then
        pass "$label absent: $path"
    else
        fail "$label unexpectedly present: $path"
    fi
}

# ─── assert_dir_present ──────────────────────────────────────────────────────
assert_dir_present() {
    local path="$1" label="${2:-dir}"
    if [[ -d "$path" ]]; then
        pass "$label present: $path"
    else
        fail "$label missing: $path"
    fi
}

# ─── assert_mtime_unchanged ──────────────────────────────────────────────────
# Catches silent rewrites: tests that want to prove the pipeline did NOT
# touch an existing file can snapshot mtime before and assert_mtime_unchanged
# after. mtime granularity on vfat is 2 seconds, so callers using vfat paths
# must not sleep under that resolution between the snapshot and the assert.
assert_mtime_unchanged() {
    local path="$1" expected_epoch="$2" label="${3:-mtime}"
    if [[ ! -e "$path" ]]; then
        fail "$label: path missing: $path"
        return
    fi
    local actual
    actual=$(stat -c '%Y' "$path")
    if [[ "$actual" == "$expected_epoch" ]]; then
        pass "$label unchanged: $path (@$actual)"
    else
        fail "$label changed: $path (expected @$expected_epoch, got @$actual)"
    fi
}

# ─── assert_fs_bytes_below ───────────────────────────────────────────────────
# Sanity check: verify the filesystem under $path holds at most N bytes of
# used data. Used to confirm a scarce tmpfs really is scarce.
assert_fs_bytes_below() {
    local path="$1" limit_bytes="$2" label="${3:-fs-used}"
    local used
    used=$(df --output=used -B1 "$path" | tail -n1 | tr -d ' ')
    if (( used <= limit_bytes )); then
        pass "$label: $path used=$used bytes (≤ $limit_bytes)"
    else
        fail "$label: $path used=$used bytes (> $limit_bytes)"
    fi
}

# ─── assert_queue_empty ──────────────────────────────────────────────────────
# Passes iff the given queue directory contains no *.job or *.claimed.* files.
# A leftover entry means the pipeline did not fully drain its queue, which is
# a hard requirement after every successful run.
assert_queue_empty() {
    local queue_dir="$1" label="${2:-queue}"
    if [[ ! -d "$queue_dir" ]]; then
        pass "$label empty (dir absent): $queue_dir"
        return
    fi
    local leftover
    leftover=$(find "$queue_dir" -maxdepth 3 \( -name "*.job" -o -name "*.claimed.*" \) 2>/dev/null | wc -l)
    if (( leftover == 0 )); then
        pass "$label empty: $queue_dir"
    else
        fail "$label has $leftover leftover entries: $queue_dir"
        find "$queue_dir" -maxdepth 3 \( -name "*.job" -o -name "*.claimed.*" \) 2>/dev/null \
            | head -5 | sed 's/^/      /'
    fi
}

# ─── assert_rc ───────────────────────────────────────────────────────────────
assert_rc() {
    local actual="$1" expected="$2" label="${3:-rc}"
    if [[ "$actual" == "$expected" ]]; then
        pass "$label: exit $actual"
    else
        fail "$label: exit $actual (expected $expected)"
    fi
}

# ─── neg_check ───────────────────────────────────────────────────────────────
# Negative-assertion wrapper for suite 11 (and any future negative scenario).
# Runs an assertion helper in a subshell, capturing stdout+stderr. If the
# output contains the "[FAIL]" marker the assertion detected the injected
# error and this scenario PASSes. If "[FAIL]" is absent the assertion has a
# blind spot and this scenario FAILs.
#
# Usage:
#   neg_check "label describing the injected error" \
#       assert_function arg1 arg2 ...
#
# The assertion helper must be one of the assert_* functions defined in this
# file or in framework.sh — they write "[FAIL]" to stdout on failure.
neg_check() {
    local label="$1"; shift
    local captured
    # Run the assertion in a subshell with PASS/FAIL as local copies so the
    # global counters are not incremented by the inner (deliberate) failure.
    # The || true suppresses any non-zero exit from the subshell (e.g. diff
    # returning 1 for differing trees) so set -e in the outer shell does not
    # terminate the suite after a correctly-detected negative result.
    captured=$(
        PASS=0
        FAIL=0
        "$@" 2>&1
    ) || true
    if echo "$captured" | grep -qF '[FAIL]'; then
        pass "neg_check: assertion correctly detected: $label"
    else
        fail "neg_check: assertion MISSED injected error: $label"
        echo "$captured" | head -5 | sed 's/^/      /'
    fi
}

# ─── fail_stub_adapter ───────────────────────────────────────────────────────
# Intentional hard-fail for scenarios whose adapter is still a stub. The
# failure message is stable and greppable so operators can diff CI logs
# across runs and see exactly which stubs still need real implementations.
fail_stub_adapter() {
    local adapter="$1"
    fail "adapter '$adapter' is a stub — integration scenario cannot pass until real implementation lands"
}
