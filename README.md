# loadout-pipeline

A lightweight shell-based pipeline for **unpacking ISO/game files** and dispatching them to multiple destinations (FTP, HDL dump, SD card).  

It supports **parallel extraction**, **bounded queues**, and **pluggable adapters**, designed for fast scratch storage and large archival pools.

## Features

- Multithreaded ISO extraction using shell + `xargs` or background jobs
- Dispatch to multiple destinations (FTP, HDL dump, SD card)
- File-based queue for controlling in-progress jobs
- Modular, pluggable adapters
- AI worker support for metadata or analysis (optional)

## Installation

```bash
git clone <repo_url>
cd iso-pipeline
chmod +x bin/iso-pipeline.sh lib/*.sh adapters/*.sh ai/*.sh

Usage
# Run with default job file
./bin/iso-pipeline.sh

# Run with custom job file
./bin/iso-pipeline.sh config/my_jobs.txt
Job File Format
/path/to/iso~destination_type|destination_path

Example:

/isos/game1.iso~ftp|/remote/path/game1
/isos/game2.iso~hdl|/dev/hdd0
/isos/game3.iso~sd|/mnt/sdcard/games
Destinations
ftp → sends via FTP (adapter: adapters/ftp.sh)
hdl → sends to HDL dump device (adapter: adapters/hdl_dump.sh)
sd → sends to mounted SD card (adapter: adapters/sdcard.sh)
Architecture

See docs/architecture.md for full pipeline diagram.

Contributing
Add new adapters in adapters/
Add new worker types in lib/
Ensure all jobs respect parallelism and scratch space limits