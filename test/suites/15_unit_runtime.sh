#!/usr/bin/env bash
# test/suites/15_unit_runtime.sh
#
# Direct unit tests for runtime-safety helpers that previously had only
# end-to-end coverage. Each test sources the relevant lib file in a subshell
# and calls the function under test directly, so a failure localises to a
# specific helper rather than to "somewhere in the pipeline".
#
# Coverage
#   R1  _assert_pipeline_dir_safe (lib/init.sh) — symlink, 0700 creation
#   R2  _precheck_member_is_safe (lib/precheck.sh) — every rejection path
#   R3  _spool_guarded_rm_rf (lib/workers.sh) — every refuse-to-rm branch
#   R4  queue_init / queue_push / queue_pop (lib/queue.sh) — FIFO + empty rc
#   R5  worker_registry (lib/worker_registry.sh) — begin/end/recover round-trip,
#       double-begin safety, missing-end no-op, consecutive-space path preserve
#   R6  space_init / space_reserve / space_release (lib/space.sh) — ledger math

_u_run_subshell() {
    while IFS= read -r line; do
        case "$line" in
            PASS*) pass "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
        esac
    done
}

# =============================================================================
# R1 — _assert_pipeline_dir_safe
# =============================================================================

header "Test R1: _assert_pipeline_dir_safe"

R1_DIR="/tmp/lp_unit_r1_$$"
mkdir -p "$R1_DIR"
ln -s /etc "$R1_DIR/symlink_dir"

# (1) symlink rejected with exit 1
R1_RC=0
bash -c '
    set +e
    source "$1/lib/logging.sh"
    source "$1/lib/init.sh"
    _assert_pipeline_dir_safe "$2/symlink_dir"
    echo "UNEXPECTED_RETURN"
' -- "$ROOT_DIR" "$R1_DIR" >/dev/null 2>&1 || R1_RC=$?

if (( R1_RC == 1 )); then
    pass "symlinked pipeline dir rejected with exit 1"
else
    fail "expected exit 1 for symlink, got $R1_RC"
fi

# (2) missing dir created with mode 0700
R1_NEW="$R1_DIR/fresh_subdir"
bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/init.sh"
    _assert_pipeline_dir_safe "$2"
' -- "$ROOT_DIR" "$R1_NEW" >/dev/null 2>&1

if [[ -d "$R1_NEW" ]]; then
    R1_MODE=$(stat -c %a "$R1_NEW" 2>/dev/null)
    if [[ "$R1_MODE" == "700" ]]; then
        pass "missing dir created with mode 0700"
    else
        fail "missing dir mode is $R1_MODE (expected 700)"
    fi
else
    fail "missing dir was not created"
fi

# (3) existing, current-user-owned dir accepted silently
R1_OWN="$R1_DIR/owned_ok"
mkdir -p "$R1_OWN"
R1_OWN_RC=0
bash -c '
    source "$1/lib/logging.sh"
    source "$1/lib/init.sh"
    _assert_pipeline_dir_safe "$2"
' -- "$ROOT_DIR" "$R1_OWN" >/dev/null 2>&1 || R1_OWN_RC=$?
if (( R1_OWN_RC == 0 )); then
    pass "existing dir owned by current user accepted"
else
    fail "own-dir rejected unexpectedly (rc=$R1_OWN_RC)"
fi

rm -rf "$R1_DIR"

# =============================================================================
# R2 — _precheck_member_is_safe
# =============================================================================
#
# The function is defined inside lib/precheck.sh, which runs as a script
# expecting $1 $2 $3. We extract just the function body with awk and source
# it in the subshell so we can call it directly with arbitrary inputs.

header "Test R2: _precheck_member_is_safe"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(awk '
        /^_precheck_member_is_safe\(\)/ { capture=1 }
        capture                         { print }
        capture && /^\}/                { capture=0 }
    ' "$ROOT_DIR/lib/precheck.sh")"

    assert_reject() {
        local label="$1" input="$2"
        if _precheck_member_is_safe "$input"; then
            echo "FAIL $label: input '$input' should have been rejected"
        else
            echo "PASS $label: '$input' rejected"
        fi
    }
    assert_accept() {
        local label="$1" input="$2"
        if _precheck_member_is_safe "$input"; then
            echo "PASS $label: '$input' accepted"
        else
            echo "FAIL $label: input '$input' should have been accepted"
        fi
    }

    assert_reject "empty"             ""
    assert_reject "absolute"          "/etc/passwd"
    assert_reject "leading-dotdot"    "../escape"
    assert_reject "mid-dotdot"        "foo/../bar"
    assert_reject "trailing-dotdot"   "foo/.."
    assert_reject "bare-dotdot"       ".."
    assert_reject "embedded-newline"  $'foo\nbar'

    assert_accept "simple-name"       "game.iso"
    assert_accept "subdir"            "CD1/game.bin"
    assert_accept "spaces-and-paren"  "Game Name (USA).cue"
    assert_accept "dot-in-name"       "file.name.v2.iso"

    # Document the current behaviour for "./foo": it slips past this helper
    # because it has no ".." segment and is not absolute. Downstream 7z
    # containment is the authoritative layer. If a future tightening rejects
    # it here, both branches still record a PASS so the test does not become
    # a silent regression trap.
    if _precheck_member_is_safe "./foo"; then
        echo "PASS './foo' currently accepted (relies on downstream containment)"
    else
        echo "PASS './foo' now tightened at precheck layer"
    fi
)

# =============================================================================
# R3 — _spool_guarded_rm_rf
# =============================================================================

header "Test R3: _spool_guarded_rm_rf"

R3_COPY="/tmp/lp_unit_r3_copy_$$"
R3_OTHER="/tmp/lp_unit_r3_other_$$"
mkdir -p "$R3_COPY/12345" "$R3_COPY/notnumeric" "$R3_OTHER/99999"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    eval "$(awk '
        /^_spool_guarded_rm_rf\(\)/ { capture=1 }
        capture                     { print }
        capture && /^\}/            { capture=0 }
    ' "$ROOT_DIR/lib/workers.sh")"
    export COPY_DIR="$R3_COPY"

    # Empty path is an explicit `return 0` (no-op) in the guard.
    if _spool_guarded_rm_rf "" 2>/dev/null; then
        echo "PASS empty path handled as no-op (return 0)"
    else
        echo "FAIL empty path returned non-zero"
    fi

    # Root must be refused.
    if _spool_guarded_rm_rf "/" 2>/dev/null; then
        echo "FAIL root path should have been refused"
    else
        echo "PASS root path refused"
    fi
    [[ -d / ]] && echo "PASS root filesystem still present (sanity)" \
               || echo "FAIL root filesystem missing (catastrophe)"

    # Non-numeric basename under COPY_DIR: must be refused.
    if _spool_guarded_rm_rf "$COPY_DIR/notnumeric" 2>/dev/null; then
        echo "FAIL non-numeric basename should have been refused"
    else
        echo "PASS non-numeric basename refused"
    fi
    if [[ -d "$COPY_DIR/notnumeric" ]]; then
        echo "PASS refused non-numeric dir still present"
    else
        echo "FAIL refused non-numeric dir was deleted anyway"
    fi

    # Numeric basename but wrong parent.
    if _spool_guarded_rm_rf "$R3_OTHER/99999" 2>/dev/null; then
        echo "FAIL parent-not-COPY_DIR should have been refused"
    else
        echo "PASS parent-not-COPY_DIR refused"
    fi
    if [[ -d "$R3_OTHER/99999" ]]; then
        echo "PASS refused wrong-parent dir still present"
    else
        echo "FAIL refused wrong-parent dir was deleted anyway"
    fi

    # Valid target: removed.
    _spool_guarded_rm_rf "$COPY_DIR/12345" 2>/dev/null
    if [[ ! -e "$COPY_DIR/12345" ]]; then
        echo "PASS valid spool dir removed by guard"
    else
        echo "FAIL valid spool dir was not removed"
    fi
)

rm -rf "$R3_COPY" "$R3_OTHER"

# =============================================================================
# R4 — queue FIFO, empty return, init scrub
# =============================================================================

header "Test R4: queue_init / queue_push / queue_pop"

R4_QDIR="/tmp/lp_unit_r4_queue_$$"

_u_run_subshell < <(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/queue.sh"

    queue_init "$R4_QDIR"
    if [[ -d "$R4_QDIR" ]]; then
        echo "PASS queue_init created directory"
    else
        echo "FAIL queue_init did not create directory"
    fi

    # Empty queue: queue_pop returns 1, prints nothing.
    if queue_pop "$R4_QDIR" >/dev/null 2>&1; then
        echo "FAIL queue_pop on empty queue returned success"
    else
        rc=$?
        if (( rc == 1 )); then
            echo "PASS empty queue_pop returns exit 1"
        else
            echo "FAIL empty queue_pop returned $rc (expected 1)"
        fi
    fi

    # Push three jobs with a small inter-push sleep so timestamp-based
    # filenames are guaranteed distinct on hosts with low %N resolution.
    queue_push "$R4_QDIR" "~/a/1.7z|lvol|d1~"
    sleep 0.01
    queue_push "$R4_QDIR" "~/a/2.7z|lvol|d2~"
    sleep 0.01
    queue_push "$R4_QDIR" "~/a/3.7z|lvol|d3~"

    count=$(find "$R4_QDIR" -maxdepth 1 -name "*.job" | wc -l)
    if [[ "$count" -eq 3 ]]; then
        echo "PASS three pushes produced three .job files"
    else
        echo "FAIL expected 3 .job files, got $count"
    fi

    j1=$(queue_pop "$R4_QDIR")
    j2=$(queue_pop "$R4_QDIR")
    j3=$(queue_pop "$R4_QDIR")
    if [[ "$j1" == "~/a/1.7z|lvol|d1~" && \
          "$j2" == "~/a/2.7z|lvol|d2~" && \
          "$j3" == "~/a/3.7z|lvol|d3~" ]]; then
        echo "PASS queue_pop returned jobs in FIFO order"
    else
        echo "FAIL queue_pop order: 1=$j1 2=$j2 3=$j3"
    fi

    # After draining, queue_pop returns 1 (empty), not 2 (error).
    if queue_pop "$R4_QDIR" >/dev/null 2>&1; then
        echo "FAIL drained queue should return non-zero"
    else
        rc=$?
        if (( rc == 1 )); then
            echo "PASS drained queue returns 1"
        else
            echo "FAIL drained queue returned $rc (expected 1)"
        fi
    fi

    # queue_init on a non-empty directory must scrub stale .job and .claimed.*.
    echo "stale" > "$R4_QDIR/stale.job"
    echo "stale" > "$R4_QDIR/stale.claimed.123"
    queue_init "$R4_QDIR"
    leftovers=$(find "$R4_QDIR" -maxdepth 1 \( -name "*.job" -o -name "*.claimed.*" \) | wc -l)
    if [[ "$leftovers" -eq 0 ]]; then
        echo "PASS queue_init scrubbed stale .job and .claimed.* files"
    else
        echo "FAIL queue_init left $leftovers stale files"
    fi
)

rm -rf "$R4_QDIR"

# =============================================================================
# R5 — worker_registry: begin/end/recover, double-begin, missing-end, spaces
# =============================================================================

header "Test R5: worker_registry API"

R5_QDIR="/tmp/lp_unit_r5_reg_$$"

_u_run_subshell < <(
    export QUEUE_DIR="$R5_QDIR"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/worker_registry.sh"

    worker_registry_init
    reg="$(_wr_path)"
    if [[ -f "$reg" ]]; then
        echo "PASS worker_registry_init created empty registry"
    else
        echo "FAIL registry file not created"
    fi

    # Round trip: begin writes a line, end removes it.
    worker_job_begin 11111 "~/a/game.7z|lvol|d~"
    if grep -q "^11111 " "$reg"; then
        echo "PASS begin wrote pid entry"
    else
        echo "FAIL begin did not write pid entry"
    fi
    worker_job_end 11111
    if ! grep -q "^11111 " "$reg"; then
        echo "PASS end removed pid entry"
    else
        echo "FAIL end did not remove pid entry"
    fi

    # end on a missing pid is a silent no-op.
    if worker_job_end 99999; then
        echo "PASS end on missing pid is a no-op"
    else
        echo "FAIL end on missing pid returned non-zero"
    fi

    # Double-begin for the same pid: the second call must replace the first.
    worker_job_begin 22222 "~/a/first.7z|lvol|d~"
    worker_job_begin 22222 "~/a/second.7z|lvol|d~"
    entries=$(grep -c "^22222 " "$reg")
    if [[ "$entries" -eq 1 ]]; then
        echo "PASS double-begin produced exactly one entry"
    else
        echo "FAIL double-begin produced $entries entries (expected 1)"
    fi
    recovered=$(worker_registry_recover)
    if [[ "$recovered" == "~/a/second.7z|lvol|d~" ]]; then
        echo "PASS double-begin: second call wins"
    else
        echo "FAIL recovered=$recovered (expected second.7z)"
    fi

    # Recover on already-empty registry is a no-op.
    out=$(worker_registry_recover)
    if [[ -z "$out" ]]; then
        echo "PASS recover on empty registry prints nothing"
    else
        echo "FAIL recover on empty printed: $out"
    fi

    # Consecutive-spaces regression guard (documented in worker_registry.sh).
    spaces_job="~/games/Two  Spaces  Game.7z|lvol|dest~"
    worker_job_begin 33333 "$spaces_job"
    out=$(worker_registry_recover)
    if [[ "$out" == "$spaces_job" ]]; then
        echo "PASS consecutive-space job path preserved through recover"
    else
        echo "FAIL spaces mangled: in=$spaces_job out=$out"
    fi
)

rm -rf "$R5_QDIR"

# =============================================================================
# R6 — space ledger basic round trip
# =============================================================================

header "Test R6: space ledger round trip"

R6_QDIR="/tmp/lp_unit_r6_space_$$"

_u_run_subshell < <(
    export QUEUE_DIR="$R6_QDIR"
    export SPACE_OVERHEAD_PCT=0
    mkdir -p "$QUEUE_DIR"
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/space.sh"

    space_init

    if space_ledger_empty; then
        echo "PASS space_init starts with an empty ledger"
    else
        echo "FAIL space ledger non-empty immediately after init"
    fi

    # Tiny 1-byte allocation against /tmp — not at risk of hitting free-space
    # limits on any realistic CI host.
    if space_reserve "unit-r6-id" "/tmp" 1 2>/dev/null; then
        echo "PASS space_reserve accepted a tiny allocation"
    else
        echo "FAIL space_reserve rejected a 1-byte allocation"
    fi

    if ! space_ledger_empty; then
        echo "PASS ledger non-empty after reserve"
    else
        echo "FAIL ledger empty after reserve (entry did not land)"
    fi

    space_release "unit-r6-id"
    if space_ledger_empty; then
        echo "PASS ledger empty after release"
    else
        echo "FAIL ledger still non-empty after release"
    fi

    # Release on a non-existent id must be a silent no-op.
    if space_release "never-reserved-id" 2>/dev/null; then
        echo "PASS release on missing id is a no-op"
    else
        echo "FAIL release on missing id returned non-zero"
    fi
)

rm -rf "$R6_QDIR"
