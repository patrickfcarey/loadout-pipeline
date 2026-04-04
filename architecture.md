# iso-pipeline Architecture

Complete architecture documentation for iso-pipeline including queue, worker modes, AI integration, storage flows, and optional features.

## Queue Architecture

The **iso-pipeline queue** is the central component that controls **space-aware, multithreaded processing**. It sits between job input and unzip workers.

Key features:
- File-based queue on scratch SSD (240b) to avoid overfilling RAM
- FIFO processing for workers
- Space awareness: ensures scratch SSD does not exceed capacity
- Supports Classic Mode workers
- Optional AI Worker preprocessing
- Safe shutdown and resume for pending jobs

```mermaid
flowchart TD
    A["Job File Input (example.jobs)"]
    B["Queue (file-based tmp)"]
    C1["Unzip Worker 1"]
    C2["Unzip Worker 2"]
    C3["Unzip Worker N"]
    A --> B
    B --> C1
    B --> C2
    B --> C3
```


## Classic Worker Mode

Classic worker mode uses a file-based queue with multiple background unzip workers. Dispatch workers send files to FTP, HDL, or SD adapters. Queue ensures space-aware processing.

```mermaid
flowchart TD
    A["Job File Input (example.jobs)"]
    B["Queue (file-based tmp)"]
    C1["Unzip Worker 1"]
    C2["Unzip Worker 2"]
    C3["Unzip Worker N"]
    D1["Dispatch Worker (per destination)"]
    D2["Dispatch Worker (per destination)"]
    D3["Dispatch Worker (per destination)"]
    E1["FTP Adapter"]
    E2["HDL Adapter"]
    E3["SD Adapter"]
    F1["FTP Adapter"]
    F2["HDL Adapter"]
    F3["SD Adapter"]
    G1["FTP Adapter"]
    G2["HDL Adapter"]
    G3["SD Adapter"]
    A --> B
    B --> C1
    B --> C2
    B --> C3
    C1 --> D1
    C2 --> D2
    C3 --> D3
    D1 --> E1
    D1 --> E2
    D1 --> E3
    D2 --> F1
    D2 --> F2
    D2 --> F3
    D3 --> G1
    D3 --> G2
    D3 --> G3
```


## Xargs Multithreaded Mode

Xargs mode uses `xargs -P` for parallel processing. Each job unzips and dispatches immediately without an intermediate queue.

```mermaid
flowchart TD
    A["Job File Input (example.jobs)"]
    B["xargs Parallel (-P MAX_UNZIP)"]
    C1["Job #1 (Unzip + Dispatch)"]
    C2["Job #2 (Unzip + Dispatch)"]
    C3["Job #3 (Unzip + Dispatch)"]
    C4["Job #4 (Unzip + Dispatch)"]
    D1["FTP Adapter"]
    D2["HDL Adapter"]
    D3["SD Adapter"]
    E1["FTP Adapter"]
    E2["HDL Adapter"]
    E3["SD Adapter"]
    F1["FTP Adapter"]
    F2["HDL Adapter"]
    F3["SD Adapter"]
    G1["FTP Adapter"]
    G2["HDL Adapter"]
    G3["SD Adapter"]
    A --> B
    B --> C1
    B --> C2
    B --> C3
    B --> C4
    C1 --> D1
    C1 --> D2
    C1 --> D3
    C2 --> E1
    C2 --> E2
    C2 --> E3
    C3 --> F1
    C3 --> F2
    C3 --> F3
    C4 --> G1
    C4 --> G2
    C4 --> G3
```


## AI Worker Integration

AI Worker can preprocess or analyze files before dispatch, running in parallel or sequentially.

```mermaid
flowchart TD
    A["Job File Input"]
    B["Queue / xargs"]
    C["Unzip Worker(s)"]
    D["Dispatch Worker(s)"]
    E["Adapters: FTP/HDL/SD"]
    F["AI Worker"]
    G["Metadata / Validation / Tagging"]
    A --> B
    B --> C
    C --> D
    D --> E
    C --> F
    F --> G
```


## Scratch Storage / ZPool Flow

ISOs are extracted on the 240b scratch SSD. Large or slow-moving storage resides in tank/turret zpools. Prevents overfilling scratch.

```mermaid
flowchart TD
    TMP["/tmp/iso_pipeline/"]
    SSD["240b Scratch SSD"]
    HDD["Tank / Turret Zpools"]
    Archive["Long-term Storage / FTP"]
    TMP --> SSD
    SSD --> HDD
    HDD --> Archive
```


## Full Pipeline Overview

Full pipeline shows classic and xargs mode combined, with optional AI worker and all adapters.

```mermaid
flowchart TD
    A["Job File Input (example.jobs)"]
    B["Queue (Classic) or xargs Parallel"]
    C1["Unzip Worker 1"]
    C2["Unzip Worker 2"]
    X1["Job #1 (xargs)"]
    X2["Job #2 (xargs)"]
    D1["Dispatch Worker / Adapter"]
    D2["Dispatch Worker / Adapter"]
    F1["FTP Adapter"]
    F2["HDL Adapter"]
    F3["SD Adapter"]
    AI["AI Worker (optional)"]
    A --> B
    B --> C1
    B --> C2
    B --> X1
    B --> X2
    C1 --> D1
    C2 --> D2
    X1 --> D1
    X2 --> D2
    D1 --> F1
    D1 --> F2
    D1 --> F3
    D2 --> F1
    D2 --> F2
    D2 --> F3
    C1 --> AI
    C2 --> AI
    X1 --> AI
    X2 --> AI
```


## Workflow & Adapter Overview

The pipeline dispatch workers send unzipped ISOs to one of three adapters:
- **FTP Adapter:** sends files to remote FTP servers
- **HDL Adapter:** uses hdl_dump to move files to local HDD arrays
- **SD Adapter:** copies files to connected SD cards
Dispatch workers ensure that each destination receives files safely, respecting concurrency and disk space.

## Optional Features

- **Xargs Mode Toggle:** switch between classic queue workers and xargs multithreaded mode
- **AI Worker:** optional preprocessing or metadata tagging
- **Space Awareness:** limits number of unzipped files to avoid filling scratch SSD
- **Multithreading:** background workers or xargs jobs run concurrently to maximize throughput

## Notes / References

- Job file format: each line `directory~filename|destination`
- Scratch SSD (240b) is used for temporary extraction
- Tank / Turret Zpools store persistent or high-speed data
- Use the pipeline comparison table to choose the correct mode for your use case

## Pipeline Comparison Table

| Feature | Classic Worker Mode | Xargs Mode |
|---------|------------------|------------|
| Parallelism control | Background workers + wait | `xargs -P` |
| Queue / space awareness | Yes | Limited (manual checks possible) |
| Complexity | Medium | Low |
| Logging per job | Yes | Yes (stdout/stderr) |
| Ease of extension | High (workers + adapters) | Medium (single job wrapper) |
