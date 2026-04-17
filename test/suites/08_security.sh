#!/usr/bin/env bash
# test/suites/08_security.sh
#
# Security regression tests: path traversal rejection in the job-line parser.
# These tests directly source lib/jobs.sh and call load_jobs() to verify that
# the validation layer rejects malicious input before any pipeline work starts.

# ── test 20: mid-string /../ rejection in load_jobs (M2 regression) ──────────
#
# The traversal defense in jobs.sh must reject '..' path segments anywhere,
# not only at path boundaries. Prior to the M2 fix, the right anchor was
# '(/$|$)' which only matched when '..' was the last segment — so crafted
# destinations like 'games/../../../etc/passwd' slipped past validation and
# only got caught later by the sd adapter's runtime containment check (and
# not at all for other adapters, which leak to their remote).

header "Test 20: mid-string /../ rejection in load_jobs (M2 regression)"

TRAV_JOBS="/tmp/iso_pipeline_test_trav_$$.jobs"
TRAV_LOG="/tmp/iso_pipeline_test_trav_$$.log"

while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < <(
    export ROOT_DIR
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/jobs.sh"

    # Case A: mid-string traversal in the destination field.
    { echo '---JOBS---'; echo "~/abs/path/game.7z|lvol|games/../../../etc/passwd~"; echo '---END---'; } > "$TRAV_JOBS"
    JOBS=()
    if load_jobs "$TRAV_JOBS" 2>"$TRAV_LOG"; then
        echo "FAIL mid-string traversal in destination was NOT rejected"
    else
        echo "PASS mid-string traversal in destination rejected"
    fi

    # Case B: mid-string traversal in the ISO path.
    { echo '---JOBS---'; echo "~/abs/../etc/passwd.7z|lvol|games/game1~"; echo '---END---'; } > "$TRAV_JOBS"
    JOBS=()
    if load_jobs "$TRAV_JOBS" 2>"$TRAV_LOG"; then
        echo "FAIL mid-string traversal in iso path was NOT rejected"
    else
        echo "PASS mid-string traversal in iso path rejected"
    fi

    # Case C: legitimate paths with '.' in filenames (not as segments) still pass.
    { echo '---JOBS---'; echo "~/abs/path/game.v1.7z|lvol|games/game.v1~"; echo '---END---'; } > "$TRAV_JOBS"
    JOBS=()
    if load_jobs "$TRAV_JOBS" 2>"$TRAV_LOG"; then
        echo "PASS legitimate path with '.' in names still accepted"
    else
        echo "FAIL legitimate path with '.' in names wrongly rejected"
    fi
)

rm -f "$TRAV_JOBS" "$TRAV_LOG"
