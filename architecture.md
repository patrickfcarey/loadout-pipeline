# loadout-pipeline Architecture

Complete architecture documentation for loadout-pipeline including queue management, worker modes, storage flows, and adapter system.

## Overview

**loadout-pipeline** is a space-aware, multithreaded ISO processing system that:
- Extracts ISO files from scratch storage
- Dispatches extracted contents to multiple destinations (FTP, HDL, SD)
- Manages concurrent operations without overwhelming scratch disk capacity
- Supports two processing modes: Classic (queue-based) and Xargs (parallel)

## Queue Architecture

The **file-based queue** is the central coordination point for space-aware processing. It:
- Stores pending jobs on scratch SSD (240GB)
- Maintains FIFO order for worker consumption
- Monitors disk space to prevent overflow
- Coordinates multiple unzip workers reading from the same queue
- Enables safe shutdown and job resumption

```mermaid
flowchart TD
    A["Job Input (example.jobs)"]
    B["File-Based Queue<br/>(tmp)"]
    C1["Unzip Worker 1"]
    C2["Unzip Worker 2"]
    C3["Unzip Worker N"]
    A --> B
    B --> C1
    B --> C2
    B --> C3
```

## Classic Worker Mode

Classic mode uses background workers that continuously process jobs from the queue:

1. **Unzip Workers** read from queue, extract ISOs to scratch SSD
2. **Dispatch Workers** move extracted files to configured destinations
3. **Queue Manager** tracks space and signals when new jobs can be processed

```mermaid
flowchart TD
    A["Job Input (example.jobs)"]
    B["Queue"]
    C1["Unzip Worker 1"]
    C2["Unzip Worker 2"]
    D1["Dispatch Worker"]
    D2["Dispatch Worker"]
    E1["FTP Adapter"]
    E2["HDL Adapter"]
    E3["SD Adapter"]
    A --> B
    B --> C1
    B --> C2
    C1 --> D1
    C2 --> D2
    D1 --> E1
    D1 --> E2
    D1 --> E3
    D2 --> E1
    D2 --> E2
    D2 --> E3
```

**Characteristics:**
- Stable throughput via space awareness
- Better for sustained, predictable workloads
- Complex shutdown/resume logic

## Xargs Multithreaded Mode

Xargs mode uses `xargs -P` for parallel job execution without an intermediate queue:

1. Job file is piped to `xargs`
2. Each parallel process unzips and dispatches immediately
3. No explicit queue or space awareness between jobs

```mermaid
flowchart TD
    A["Job Input (example.jobs)"]
    B["xargs -P MAX_JOBS"]
    C1["Job #1<br/>(Unzip + Dispatch)"]
    C2["Job #2<br/>(Unzip + Dispatch)"]
    C3["Job #N<br/>(Unzip + Dispatch)"]
    E1["FTP Adapter"]
    E2["HDL Adapter"]
    E3["SD Adapter"]
    A --> B
    B --> C1
    B --> C2
    B --> C3
    C1 --> E1
    C1 --> E2
    C1 --> E3
    C2 --> E1
    C2 --> E2
    C2 --> E3
```

**Characteristics:**
- Simpler implementation
- Fixed parallelism via `-P` flag
- Less sophisticated space management
- Better for ad-hoc or bursty workloads

## Adapter System

Dispatch workers send files to one of three destination adapters:

| Adapter | Method | Use Case |
|---------|--------|----------|
| **FTP** | Network transfer to remote FTP server | Remote backup / distribution |
| **HDL** | Local transfer via hdl_dump utility | Local HDD array / arcade systems |
| **SD** | Direct copy to mounted SD card | Portable storage / recovery media |

Each adapter handles:
- Connection validation
- Concurrent transfers (with per-adapter limits)
- Error handling and retry logic
- Space verification on destination

## Storage Architecture

```mermaid
flowchart TD
    SRC["ISO Source"]
    TMP["/tmp/iso_pipeline/"]
    SCRATCH["240GB Scratch SSD"]
    PERSISTENT["Tank / Turret Zpools"]
    DEST["Destinations<br/>(FTP/HDL/SD)"]
    SRC --> TMP
    TMP --> SCRATCH
    SCRATCH --> PERSISTENT
    PERSISTENT --> DEST
```

- **Scratch SSD (240GB):** temporary extraction location, preventing large ISOs from consuming main storage
- **Zpools (Tank/Turret):** persistent storage for staging or archival
- **Destinations:** final delivery points via adapters

## Configuration & Modes

### Entry Point
- **Script:** `bin/loadout-pipeline.sh`
- **Job File Format:** each line = `directory~filename|destination`
  - Example: `games/sonic~sonic.iso|ftp,hdl,sd`

### Mode Selection
- **Classic Mode:** queue-based workers (default, recommended for stability)
- **Xargs Mode:** parallel jobs via `xargs -P` (simpler, use for smaller workloads)
- **Optional AI Worker:** preprocessing or metadata tagging (experimental)

## Optional Features

- **AI Worker:** optional preprocessing or metadata analysis before dispatch
- **Space Awareness:** limits concurrent unzips to prevent scratch overflow
- **Logging:** per-job output with configurable verbosity
- **Safe Shutdown:** queue persistence allows job resumption after restart

## Notes

- Job processing is FIFO within each mode
- Scratch SSD capacity acts as a backpressure mechanism
- Multiple adapters can be chained per job (comma-separated)
- Adapters run sequentially per dispatch worker to ensure order
