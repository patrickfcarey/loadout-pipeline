#!/usr/bin/env bash

start_pipeline() {
    queue_init
    for job in "${JOBS[@]}"; do
        queue_push "$job"
    done

    echo "[pipeline] Running in classic background worker mode..."
    for i in $(seq 1 $MAX_UNZIP); do
        unzip_worker &
    done
    wait
}

unzip_worker() {
    while job=$(queue_pop); do
        bash "$ROOT_DIR/lib/unzip.sh" "$job"
    done
}