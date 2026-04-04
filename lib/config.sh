#!/usr/bin/env bash

JOBS=()

load_jobs() {
    local file="$1"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        JOBS+=("$line")
    done < "$file"
}