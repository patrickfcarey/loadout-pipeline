#!/usr/bin/env bash
type="$1"
src="$2"
dest="$3"

case "$type" in
    ftp)    bash "$ROOT_DIR/adapters/ftp.sh" "$src" "$dest" ;;
    hdl)    bash "$ROOT_DIR/adapters/hdl_dump.sh" "$src" "$dest" ;;
    sd)     bash "$ROOT_DIR/adapters/sdcard.sh" "$src" "$dest" ;;
    *)      echo "[dispatch] Unknown destination type: $type" ;;
esac