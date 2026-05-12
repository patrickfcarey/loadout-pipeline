# HDL Auto-Naming & Auto-Media Research

Research date: 2026-05-11
Status: Research only. No code changes. Not a v1.0 blocker — a candidate for v1.1+.

## 1. Why this document exists

Today our `~iso|hdl|<cd|dvd>|<title>~` job-line grammar requires the operator to
spell the PS2 game title themselves in field 4. The upstream tool
[israpps/HDL-Batch-installer](https://github.com/israpps/HDL-Batch-installer)
(a Windows wxWidgets GUI over the same `hdl_dump` binary we wrap) ships two
quality-of-life features on top of bare `hdl_dump`:

1. **Auto-naming** — derives the correct PS2 game title from the ISO so the
   operator does not type it.
2. **Auto-media** — attaches accompanying media (HDD-OSD icon and/or OPL
   artwork files) so the injected game shows correctly in the PS2 browser
   and in Open PS2 Loader (OPL).

This document captures how upstream implements each, the licensing of the
data assets, and what a port into our `adapters/hdl_dump.sh` would look like
while preserving the frozen job-line grammar.

## 2. Upstream architecture (verified)

### 2.1 Disc-code extraction

HDL-Batch-installer does **not** parse the ISO 9660 filesystem itself. It
shells out to `hdl_dump cdvd_info2 <iso>` and parses its first stdout line.

Verified at
[`HDL-Batch-installer-SRC/HDL_Batch_installerMain.cpp:932-949`](https://github.com/israpps/HDL-Batch-installer/blob/main/HDL-Batch-installer-SRC/HDL_Batch_installerMain.cpp):

```cpp
command0.Printf("HDL.EXE cdvd_info2 \"%s\"", strr);
wxExecute(command0, result);
resultt = result.Item(0);                              // first line
inject_mode = (resultt.StartsWith("CD")) ? "inject_cd " : "inject_dvd ";
// ELF code is the 4th quoted field on that line
z = resultt.find_first_of("\"");
z = resultt.find_first_of("\"", z + 1);
z = resultt.find_first_of("\"", z + 1);
ELF = resultt.Mid(z+1);
ELF = ELF.substr(0, ELF.find_last_of("\""));
```

Result: a string like `SLUS_205.92` (US), `SCES_512.04` (PAL), `SLPM_650.71`
(JP), etc. This is the disc code that PS2 boot uses (`BOOT2 = cdrom0:\<ELF>;1`
in the ISO's `SYSTEM.CNF`).

The same call decides `inject_cd` vs `inject_dvd` — meaning we could also
derive field 3 of our job-line automatically if we wanted to.

### 2.2 Disc-code → title lookup

Looked up in a `std::map<std::string,std::string>` compiled in from
[`Database/gamename.csv`](https://github.com/israpps/HDL-Batch-installer/blob/main/Database/gamename.csv)
(~636 KB, semicolon-delimited):

```
AEIA_000.01;Yoake mae yori ruriiro na - brighter than dawning blue [limited edition]
ALCH_000.01;Katakamuna - Ushinawareta Ingaritsu [DX Pack]
...
SLUS_205.92;<title for that disc>
```

Parser at
[`HDL-Batch-installer-SRC/gamename/parser.cpp`](https://github.com/israpps/HDL-Batch-installer/blob/main/HDL-Batch-installer-SRC/gamename/parser.cpp):
exact match on disc code, returns the title or a `NO_MATCH` sentinel. On
miss, upstream falls back to the ISO filename (sans `.iso` extension) as
the title.

### 2.3 Auto-media: two distinct mechanisms

Upstream actually attaches media in **two unrelated places** — important
because they target different runtime consumers on the PS2:

#### A) HDD-OSD partition icon (PS2 native browser)

Embedded **into the HDLoader partition header** via
`hdl_dump modify_header <hdd_dev> "<title>"`.

`modify_header` reads these files from the current working directory:
`system.cnf`, `icon.sys`, `list.ico`, `logo.raw`, `boot.kirx`.

The per-game `<ELF>.ico` file is copied into `list.ico` before invoking
`modify_header`, via
[`Load_custom_icon()` at HDL_Batch_installerMain.cpp:1785`](https://github.com/israpps/HDL-Batch-installer/blob/main/HDL-Batch-installer-SRC/HDL_Batch_installerMain.cpp):

```cpp
wxString icon_from_database = "\\" + ELF + ".ico";
if (wxFileExists(ICONS_FOLDER+icon_from_database))
    wxCopyFile(ICONS_FOLDER+icon_from_database, "list.ico");
```

Icons come from the separate repo
[`CosmicScale/HDD-OSD-Icon-Database`](https://github.com/CosmicScale/HDD-OSD-Icon-Database)
(~125 MB), downloaded as a password-protected ZIP and extracted with 7z. The
extraction password is hardcoded as `PDPA`.

This icon is what the **PS2's own HDD browser** displays.

#### B) OPL artwork (Open PS2 Loader on a separate partition)

Downloaded with `wget` from a configurable `CFG_ARTURL` (defaults to an
archive.org mirror), one file per art type per game. From
[`ArtMan.cpp`](https://github.com/israpps/HDL-Batch-installer/blob/main/HDL-Batch-installer-SRC/ArtMan.cpp):

| Suffix | Type |
|---|---|
| `_BG_00.jpg` | Background |
| `_COV.jpg` | Front cover |
| `_COV2.jpg` | Back cover |
| `_ICO.png` | Icon |
| `_LAB.jpg` | Disc label |
| `_LGO.png` | Logo |
| `_SCR_00.jpg` / `_SCR_01.jpg` | Screenshots |

Sibling repos for non-image media:

- OPL configs: `https://raw.githubusercontent.com/israpps/PS2-OPL-CFG-Database/master/CFG_en/<ELF>.cfg`
- Widescreen cheats: `https://raw.githubusercontent.com/PS2-Widescreen/OPL-Widescreen-Cheats/main/CHT/<ELF>.cht`

These files are saved into `Downloads/ART/`, `Downloads/CFG/`, `Downloads/CHT/`,
then transferred onto the **OPL data PFS partition** (a different partition
than the injected HDLoader one) via Dokan-mounted filesystem access. This is
what OPL displays when it scans the HDD.

## 3. Licensing & redistribution

| Asset | Source | License | Redistribute? |
|---|---|---|---|
| `hdl_dump cdvd_info2` subcommand | ps2homebrew/hdl-dump (already a runtime dep of ours) | GPL-2.0 / LGPL | Already used; nothing new |
| `gamename.csv` | HDL-Batch-installer (GPL-3.0) | GPL-3.0 by inclusion; upstream note says "built for public usage, not exclusively for this program" | Yes, with attribution; or rebuild from public sources (redump.org dat, OPL `art.bin` titles) |
| HDD-OSD icons | CosmicScale/HDD-OSD-Icon-Database | **No license file** — default "all rights reserved" | **No**. Operator must opt in and fetch themselves at install time. |
| OPL artwork (BG/COV/ICO/etc.) | Third-party archive.org mirror / OPL-Manager / community sources | Mixed; mostly copyrighted box art scraped from publishers | **No**. Same opt-in fetch model required. |
| OPL CFGs | israpps/PS2-OPL-CFG-Database | Public repo, no explicit license | Best practice: fetch on demand, do not redistribute |
| Widescreen cheats | PS2-Widescreen/OPL-Widescreen-Cheats | Public repo | Same |

Practical implication: **only the disc-code → title CSV is safely bundlable**.
Everything else needs operator-side opt-in fetch.

## 4. Feasibility for our adapter

We already shell out to `hdl_dump` for the inject step. Everything upstream
does is built on the same binary plus a few external data files. There is
no Windows-specific API and no GUI dependency in the core algorithm — the
Windows-specific parts (Dokan filesystem mount, wxWidgets GUI) are only
needed for the OPL-partition file transfer, which is the heaviest feature.

This decomposes cleanly into three implementation levels:

### Level 1 — Auto-name only

**Scope:** Eliminate the operator-typed title field for known discs.

What we add:

- A new lookup table file shipped at `data/ps2_gamename.csv` (or fetched on
  demand from a pinned commit of upstream).
- A helper in `lib/` — `lib/ps2_titles.sh` with one function:
  `ps2_resolve_title <iso_path>` → echoes the resolved title or empty.
  Internally it runs `hdl_dump cdvd_info2 "$iso"`, awks the disc code out
  of the first line, and grep-looks up the CSV.
- In `adapters/hdl_dump.sh`, when the job's `<title>` field is the sentinel
  `AUTO` (or empty in a future grammar revision — see §5), call
  `ps2_resolve_title`. On miss, fall back to the ISO basename without
  `.iso` extension (matches upstream behaviour).
- New env var (opt-in): `HDL_TITLE_DB` pointing at the CSV (default to the
  bundled file).

**Risk:** very low. No new binaries, no network at job time, no privileged
operations. Pure additive behaviour gated on a sentinel value.

**Operator UX win:** for a known disc, the job becomes
`~game.iso|hdl|AUTO|AUTO~` — auto-name and auto-format both derived from
`cdvd_info2`. (See §5 for whether we use `AUTO` in both fields.)

### Level 2 — Auto-name + HDD-OSD icon

**Scope:** Level 1 plus: after `inject_cd`/`inject_dvd`, run
`hdl_dump modify_header <hdd_dev> "<title>"` with a `list.ico` copied from
a per-disc icon directory.

What we add:

- New env var (opt-in): `HDL_ICON_DB_DIR` pointing at the operator's local
  copy of the CosmicScale icon database (or any directory with `<ELF>.ico`
  files matching disc codes).
- A second helper or extension in `adapters/hdl_dump.sh`: after a successful
  inject, look for `$HDL_ICON_DB_DIR/$ELF.ico`. If present, copy into a
  temp working dir as `list.ico`, then call
  `hdl_dump modify_header "$HDL_INSTALL_TARGET" "$title"` from that dir.
- New env var: `HDL_AUTO_ICON=0|1` (default 0).

**Risk:** medium. `modify_header` mutates the partition header on the
PS2 HDD — same blast radius as the inject step itself. CWD discipline
matters because `modify_header` reads `list.ico` from the current
directory, not a configurable path. We must use a per-job scratch dir
to avoid concurrent workers overwriting each other's `list.ico`.

**Open question:** does `modify_header` require the other files
(`system.cnf`, `icon.sys`, `logo.raw`, `boot.kirx`) to be present? Upstream
removes them before each call, suggesting they're optional or
auto-defaulted. Needs verification against `hdl_dump` source — see §7.

### Level 3 — Auto-name + icon + OPL artwork

**Scope:** Level 2 plus: download OPL-side art/cfg/cht files and place
them on the OPL data partition.

What we add (and why this is heavy):

- A way to write to the PS2 HDD's OPL data PFS partition from Linux. Options:
  1. `pfsshell` (CLI; ps2homebrew/pfsshell) — adds a new external dep.
  2. `fuse-pfs` — mounts as a regular filesystem, but Linux-only and
     somewhat unmaintained.
  3. Punt and only emit a tarball of the art assets for the operator to
     transfer themselves.
- Network egress at job time, with retries, cert handling, and partial-fetch
  cleanup (upstream's `cleanup()` script deletes zero-byte downloads —
  we'd need equivalent).
- Per-asset opt-in env vars (`HDL_ART_BG`, `HDL_ART_COV`, ...).
- Compatibility with our space ledger — art assets are small, but they're
  not free.

**Risk:** high. Net-new external dependency, new partition surface area,
licensing exposure if we recommend particular art sources.

**Recommendation:** explicitly defer Level 3 to a post-1.x release or
treat it as a separate companion tool. The Level 1/2 features deliver
most of the operator-facing value at a fraction of the surface area.

## 5. Preserving the frozen job-line grammar

Our public-interface freeze (see `ai_agent_entry_point.md`) allows
*additions* but forbids *removals or renames*. The current 4-field grammar
`~<iso>|hdl|<cd|dvd>|<title>~` stays intact. We extend by sentinels:

| Field | Today | Auto-name addition |
|---|---|---|
| 1 (iso) | required path | unchanged |
| 2 (adapter) | `hdl` | unchanged |
| 3 (format) | `cd` or `dvd` | accept `AUTO` to derive from `cdvd_info2` |
| 4 (title) | required string | accept `AUTO` (or empty) to derive via §4.1 lookup |

Existing jobs continue to work exactly as today. New jobs may use `AUTO`
in either or both fields. This is purely additive — passes the freeze
policy.

Mixed examples that all remain valid:

- `~game.iso|hdl|dvd|Final Fantasy X~` — today's form, unchanged
- `~game.iso|hdl|AUTO|Final Fantasy X~` — derive format, operator titles
- `~game.iso|hdl|dvd|AUTO~` — operator format, derive title
- `~game.iso|hdl|AUTO|AUTO~` — fully derived

## 6. Sketch of code touch points (Level 1 only)

No code in this PR — but for the implementing PR, the shape is:

- **New file** `data/ps2_gamename.csv` — bundled title DB (re-derived or
  imported with attribution from upstream's `gamename.csv`).
- **New file** `lib/ps2_titles.sh` — exposing:
  ```
  ps2_disc_code <iso>          # echoes SLUS_NNN.NN or empty
  ps2_disc_format <iso>        # echoes "cd" | "dvd" | empty
  ps2_resolve_title <iso>      # echoes title from DB or empty
  ```
  All three thin shells over `hdl_dump cdvd_info2` + a grep on the CSV.
- **Modified** `adapters/hdl_dump.sh` — replace the bare `title=$4`
  with a resolver that handles the `AUTO` sentinel and the format-field
  variant. The existing `image` selection and `inject_cd`/`inject_dvd`
  branching stays.
- **Modified** `lib/jobs.sh` — relax the 4-field hdl parse to accept
  `AUTO` in fields 3 and 4 without failing validation.
- **Modified** `README.md` and `ai_agent_entry_point.md` — document the
  sentinel and the new env vars.
- **New test suite** `test/suites/22_unit_hdl_auto_title.sh` — covers:
  matched lookup, missed lookup (filename fallback), `AUTO` in field 3,
  `AUTO` in both fields, mixed-case disc codes, and degraded mode when
  `hdl_dump cdvd_info2` is unavailable.

## 7. Open questions to verify before implementing

1. **Exact `cdvd_info2` output format across hdl_dump versions.** We know
   the upstream parser assumes line 1 is `CD|DVD ... "<volume>" "<creator>"
   "<ELF>"` but the field positions may have shifted in newer hdl_dump
   releases. Needs a quick test against our installed binary on a real ISO.
2. **`modify_header` companion-file requirements.** Whether `system.cnf`,
   `icon.sys`, `logo.raw`, `boot.kirx` are required or optional. If any
   are required, we need to ship sane defaults or skip the icon feature
   when they're missing.
3. **CSV redistribution stance.** Upstream's note ("built for public usage,
   not exclusively for this program") plus GPL-3.0 inclusion suggests we
   can redistribute with attribution. We should still keep our copy small
   — strip Japanese-only and limited-edition variants if we're tight on
   bundle size, or fetch on demand from a pinned upstream commit.
4. **Disc-code normalization.** Codes appear as `SLUS_205.92` in upstream
   but some tools use `SLUS-205.92` or `SLUS20592`. Need a canonicalizer
   so all three forms hit the same DB row.
5. **Concurrent inject + modify_header safety.** Multiple workers might
   try to inject + modify_header against the same `HDL_INSTALL_TARGET`
   at once. The existing flock-guarded ledger and queue claiming might
   already serialize enough — needs review of `lib/space.sh` /
   `lib/queue.sh` semantics in the modify_header path.
6. **What happens for non-Sony / homebrew ISOs.** No disc code →
   `cdvd_info2` returns something different or fails. We need to detect
   that and fall back to the filename without surfacing a hard error.

## 8. Recommendation

- **For v1.0:** do nothing. The frozen job-line grammar already supports
  operator-typed titles; auto-naming is a quality-of-life feature, not a
  correctness gap.
- **For v1.1:** ship Level 1 only (auto-name via `cdvd_info2` + bundled CSV,
  `AUTO` sentinel). This is small, contained, and additive.
- **For v1.2+:** consider Level 2 (icon embedding) once Level 1 ships
  cleanly and we have an opt-in pattern proven for `HDL_TITLE_DB`.
- **Defer indefinitely:** Level 3 (OPL data partition). Better suited
  to a separate companion tool than to the loadout pipeline itself.

## 9. References

Upstream files cited in this document (all under
`israpps/HDL-Batch-installer` unless noted):

- `README.md` — feature list
- `Database/gamename.csv` — disc-code → title mapping
- `Database/README.MD` — note on public-usage intent of the DB
- `HDL-Batch-installer-SRC/gamename/parser.cpp` — DB lookup implementation
- `HDL-Batch-installer-SRC/gamename/database.cpp` — compiled-in copy of the CSV
- `HDL-Batch-installer-SRC/HDL_Batch_installerMain.cpp` — install
  orchestration, around lines 925-1000 and 1785-1810
- `HDL-Batch-installer-SRC/ArtMan.cpp` — OPL artwork download logic

External repos referenced by upstream:

- `CosmicScale/HDD-OSD-Icon-Database` — partition icon database (no license)
- `israpps/PS2-OPL-CFG-Database` — OPL config files
- `PS2-Widescreen/OPL-Widescreen-Cheats` — widescreen cheats
