#!/usr/bin/env bash

MAX_UNZIP=2
MAX_DISPATCH=3

# Feature flag: use xargs-based multithreading
USE_XARGS="${USE_XARGS:-false}"

start_pipeline() {
    queue_init
    for job in "${JOBS[@]}"; do
        queue_push "$job"
    done

    if [[ "$USE_XARGS" == "true" ]]; then
        echo "[pipeline] Running in xargs-based parallel mode..."
        run_xargs_pipeline
    else
        echo "[pipeline] Running in classic background worker mode..."
        # Start unzip workers
        for i in $(seq 1 $MAX_UNZIP); do
            unzip_worker &
        done
        wait
    fi
}

# Classic worker loop
unzip_worker() {
    while job=$(queue_pop); do
        bash -c "$ROOT_DIR/lib/unzip.sh '$job'"
    done
}

# =======================
# Xargs-based multithreaded pipeline
# =======================
run_xargs_pipeline() {
    # Use temp file for job lines
    JOB_FILE=$(mktemp)
    printf "%s\n" "${JOBS[@]}" > "$JOB_FILE"

    # Unzip + dispatch combined
    # -P controls number of parallel jobs
    cat "$JOB_FILE" | xargs -P "$MAX_UNZIP" -I {} bash -c '
        iso="{}"
        IFS="~" read -r iso_path rest <<< "$iso"
        IFS="|" read -r dest_type dest_path <<< "$rest"

        out_dir="/tmp/iso_pipeline/$(basename "$iso_path" .iso)"
        mkdir -p "$out_dir"

        echo "[xargs] Extracting $iso_path → $out_dir..."
        7z x "$iso_path" -o"$out_dir" >/dev/null

        bash "$ROOT_DIR/lib/dispatch.sh" "$dest_type" "$out_dir" "$dest_path"
    '

    rm -f "$JOB_FILE"
}