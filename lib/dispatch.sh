#!/usr/bin/env bash
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
adapter="$1"
src="$2"
dest="$3"

case "$adapter" in
    ftp)    bash "$ROOT_DIR/adapters/ftp.sh" "$src" "$dest" ;;
    hdl)    bash "$ROOT_DIR/adapters/hdl_dump.sh" "$src" "$dest" ;;
    sd)     bash "$ROOT_DIR/adapters/sdcard.sh" "$src" "$dest" ;;
    *)      echo "[dispatch] Unknown adapter: $adapter" ;;
esac