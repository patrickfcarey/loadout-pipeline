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
