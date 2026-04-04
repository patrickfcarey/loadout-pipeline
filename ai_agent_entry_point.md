
# iso-pipeline AI Agent Entry Point

This document is intended for **AI agents** or future AI workers to understand the `loadout-pipeline` system. It describes the pipeline, queue, worker modes, storage architecture, adapters, and optional features.

---

## System Overview

**iso-pipeline** is a framework for unzipping video game ISO files and dispatching them to multiple destinations. It supports:

- **Multiple worker modes**:
  - Classic queue-based multithreaded workers
  - Xargs-based parallel processing
- **Storage management**:
  - Scratch SSD (240b) for temporary extraction
  - Tank/Turret zpools for persistent storage
- **Dispatch adapters**:
  - FTP
  - HDL (local HDDs via `hdl_dump`)
  - SD cards
- **Optional AI worker integration**:
  - Metadata tagging
  - Preprocessing
  - Validation

The system is designed to be **space-aware**, preventing the scratch SSD from overfilling, and **high-throughput**, always keeping a few files ready to dispatch.

---

## Job File Format

Jobs are defined in a text file (default: `example.jobs`) with the following format:
directory~filename|destination

- `directory` – path to source file
- `filename` – ISO archive name
- `destination` – target adapter(s)

Example:
/mnt/isos~zelda.iso|ftp
/mnt/isos~mario.iso|hdl


---

## Queue Architecture

The **queue** is central to iso-pipeline:

- FIFO-based job queue on scratch SSD
- Space-aware: prevents overfilling
- Supports multiple unzip workers
- Can persist pending jobs for recovery

```mermaid
flowchart TD
A["Job File Input (example.jobs)"] --> B["Queue (file-based tmp)"]
B --> C1["Unzip Worker 1"]
B --> C2["Unzip Worker 2"]
B --> C3["Unzip Worker N"]
```
    Classic Worker Mode
Multiple background unzip workers read from the queue
Dispatch workers send files to adapters (FTP/HDL/SD)
Space-aware queue ensures scratch SSD is never exceeded
```mermaid
flowchart TD
A["Job File Input"] --> B["Queue"]
B --> C1["Unzip Worker 1"]
B --> C2["Unzip Worker 2"]
B --> C3["Unzip Worker N"]
C1 --> D1["Dispatch Worker"]
C2 --> D2["Dispatch Worker"]
C3 --> D3["Dispatch Worker"]
D1 --> E1["FTP Adapter"]
D1 --> E2["HDL Adapter"]
D1 --> E3["SD Adapter"]
```
    Xargs Multithreaded Mode
Uses xargs -P to run multiple jobs concurrently
Each job handles unzip + dispatch
Optional space monitoring
```mermaid
flowchart TD
A["Job File Input"] --> B["xargs -P MAX_UNZIP"]
B --> C1["Job #1 (Unzip + Dispatch)"]
B --> C2["Job #2 (Unzip + Dispatch)"]
B --> C3["Job #3 (Unzip + Dispatch)"]
```


---

## AI Worker Integration

- Optional AI worker can preprocess files, tag metadata, or validate ISOs
- Can run in parallel with unzip/dispatch workers

```mermaid id="3svrx1"
flowchart TD
A["Job File Input"] --> B["Queue / xargs"]
B --> C["Unzip Worker(s)"]
C --> D["Dispatch Worker(s)"]
C --> F["AI Worker"]
F --> G["Metadata / Validation / Tagging"]
```
    Storage / Zpool Flow
Scratch SSD (240b) holds temporary unzipped files
Tank/Turret zpools store persistent data
Archives are dispatched to FTP or long-term storage
```mermaid
flowchart TD
TMP["/tmp/iso_pipeline"] --> SSD["240b Scratch SSD"]
SSD --> HDD["Tank / Turret zpools"]
HDD --> Archive["Long-term Storage / FTP"]
```
```mermaid
flowchart TD
A["Job File Input"] --> B["Queue / xargs"]
B --> C1["Unzip Worker 1"]
B --> C2["Unzip Worker 2"]
B --> X1["Job #1 (xargs)"]
B --> X2["Job #2 (xargs)"]
C1 --> D1["Dispatch Worker / Adapter"]
C2 --> D2["Dispatch Worker / Adapter"]
X1 --> D1
X2 --> D2
D1 --> F1["FTP Adapter"]
D1 --> F2["HDL Adapter"]
D1 --> F3["SD Adapter"]
D2 --> F1
D2 --> F2
D2 --> F3
C1 --> AI["AI Worker (optional)"]
C2 --> AI
X1 --> AI
X2 --> AI
```
    


---

## Optional Features

- **Xargs toggle** between classic queue and xargs mode
- **AI preprocessing** and tagging
- **Space awareness** to limit scratch SSD usage
- **Concurrent multithreading** for unzip + dispatch

---

## Pipeline Comparison Table

| Feature | Classic Worker Mode | Xargs Mode |
|---------|------------------|------------|
| Parallelism control | Background workers + wait | `xargs -P` |
| Queue / space awareness | Yes | Limited (manual checks) |
| Complexity | Medium | Low |
| Logging per job | Yes | Yes (stdout/stderr) |
| Ease of extension | High (workers + adapters) | Medium (single job wrapper) |

---

## Notes for AI Agents

- Read the **diagrams** to understand the flow of jobs and adapters
- Inspect **scratch SSD queue** to determine space and pending jobs
- AI workers can suggest:
  - Switching modes
  - Rebalancing workers
  - Optimizing dispatch
- Job file parsing and adapter logic are the primary integration points for AI modifications

---

**End of AI Agent Entry Point**


