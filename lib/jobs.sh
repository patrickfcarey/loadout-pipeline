#!/usr/bin/env bash

JOBS=()

init_environment() {
    # mkdir -p is idempotent: safe to call on every run, never deletes existing content.
    # Queue cleanup is handled separately by queue_init at pipeline start.
    mkdir -p "/tmp/iso_pipeline"
    mkdir -p "$QUEUE_DIR"
}

load_jobs() {
    local file="$1"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        JOBS+=("$line")
    done < "$file"
}