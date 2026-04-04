#!/usr/bin/env bash

QUEUE_DIR="/tmp/iso_pipeline_queue"
mkdir -p "$QUEUE_DIR"

queue_init() {
    rm -rf "$QUEUE_DIR"/*
}

queue_push() {
    local job="$1"
    local id
    id=$(date +%s%N)
    echo "$job" > "$QUEUE_DIR/$id.job"
}

queue_pop() {
    local file
    file=$(ls "$QUEUE_DIR" | head -n1) || return 1
    cat "$QUEUE_DIR/$file"
    rm -f "$QUEUE_DIR/$file"
}