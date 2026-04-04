#!/usr/bin/env bash

MAX_UNZIP=2
MAX_DISPATCH=3

start_pipeline() {
    queue_init
    for job in "${JOBS[@]}"; do
        queue_push "$job"
    done

    # Start unzip workers
    for i in $(seq 1 $MAX_UNZIP); do
        unzip_worker &
    done

    wait
}

unzip_worker() {
    while job=$(queue_pop); do
        bash -c "$ROOT_DIR/lib/unzip.sh '$job'"
    done
}