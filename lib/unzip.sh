#!/usr/bin/env bash
job="$1"

IFS='~' read -r iso rest <<< "$job"
IFS='|' read -r dest_type dest_path <<< "$rest"

out_dir="/tmp/iso_pipeline/$(basename "$iso" .iso)"
mkdir -p "$out_dir"

echo "[unzip] Extracting $iso to $out_dir..."
7z x "$iso" -o"$out_dir" >/dev/null

bash "$ROOT_DIR/lib/dispatch.sh" "$dest_type" "$out_dir" "$dest_path"