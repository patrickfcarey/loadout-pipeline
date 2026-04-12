#!/usr/bin/env bash

queue_init() {
    mkdir -p "$QUEUE_DIR"
    rm -rf "$QUEUE_DIR"/*
}

queue_push() {
    local job="$1"
    local id
    id=$(date +%s%N)
    echo "$job" > "$QUEUE_DIR/$id.job"
}

queue_pop() {
    local file claimed
    for file in "$QUEUE_DIR"/*.job; do
        # Glob yields the literal pattern string when no files match
        [[ -e "$file" ]] || return 1
        claimed="${file}.claimed.$$"
        # mv is atomic on the same filesystem: only one worker wins the race
        mv "$file" "$claimed" 2>/dev/null || continue
        cat "$claimed"
        rm -f "$claimed"
        return 0
    done
    return 1
}