# Subsystem: Job Parsing

Covers the `~iso_path|adapter|dest~` grammar and the strip-list file
format — the three functions that every pipeline stage uses to turn
text files on disk into structured job records.

The parser is the only place where the job grammar lives. No other
file (extract.sh, dispatch.sh, resume_planner.sh) may re-implement
`~iso|adapter|dest~` splitting inline; they source `job_format.sh`
and call `parse_job_line`. This lets the compat freeze anchor a
single canonical grammar.

### `parse_job_line`

**Source**: `lib/job_format.sh:60`
**Visibility**: public
**Test coverage**: `test/suites/14_unit_parsers.sh` U1

**Signature**
```
parse_job_line <raw_job_line>
```

| Position | Name         | Type   | Constraint                                                   |
| -------: | ------------ | ------ | ------------------------------------------------------------ |
|       $1 | raw_job_line | string | A full job token including the leading `~` and trailing `~`. |

**Returns**:

|  rc | Meaning                                                                                                                     |
| --: | --------------------------------------------------------------------------------------------------------------------------- |
| `0` | Valid. Three lines printed to stdout: `iso_path`, `adapter_name`, `destination_spec`.                                       |
| `1` | Malformed. Nothing printed. Causes include: missing leading/trailing `~`, wrong number of `\|` separators, any empty field. |

**Stdout**: on rc=0, three newline-separated fields (one trailing
newline after the third). On rc=1, nothing.
**Stderr**: silent. The parser never logs — callers decide how to
report failures.

**Preconditions**

- None beyond `$1` being set. The parser is pure text manipulation
  and has no dependency on pipeline globals.

**Postconditions (on rc=0)**

- `iso_path`, `adapter_name`, `destination_spec` all non-empty.
- `iso_path` and `adapter_name` do not contain a `|`. If the body
  contains more than two `|` separators, the excess is absorbed into
  `destination_spec` by the `read -r` three-variable contract.

**Invariants**

- The grammar is anchored: leading char must be `~`, trailing char
  must be `~`. A token like `~foo|bar|baz` (no trailing `~`) is
  rejected, as is `foo|bar|baz~` (no leading `~`).
- Splitting uses `IFS='|' read -r` on the stripped body. A body with
  two `|` produces three fields; a body with one `|` produces two
  fields (third is empty) and is rejected; a body with three or more
  `|` absorbs everything from the third separator onward into
  `destination_spec` (the `read -r a b c` three-variable contract).
  All three fields are non-empty so the parser accepts the line —
  this is the forward-compatibility mechanism for future fields.
- Pure. The parser has no side effects, opens no files, reads no
  env vars, and always returns the same output for the same input.
  Suite 14 U1 pins this by running it in isolation without any
  other pipeline state.

**Side effects**: none.

**Error modes**

| rc | Condition                                 | Notes                |
| --: | ----------------------------------------- | -------------------- |
|  1 | Missing `~` at start or end               | Silent; caller logs. |
|  1 | Any of the three fields empty after split | Silent; caller logs. |

**Example**

```bash
if parsed="$(parse_job_line "$raw")"; then
    { read -r iso_path; read -r adapter_name; read -r destination_spec; } \
        <<< "$parsed"
else
    log_error "malformed job: $raw"
fi
```

### `load_jobs`

**Source**: `lib/jobs.sh:48`
**Visibility**: public
**Test coverage**: `test/suites/14_unit_parsers.sh` U3 + U5, `test/suites/18_unit_config_jobs_edges.sh` C6/C7/C8, `test/suites/08_security.sh` (path-traversal), `test/suites/02_core_pipeline.sh` (end-to-end)

**Signature**
```
load_jobs <file_or_dir>
```

| Position | Name        | Type | Constraint                                                                                               |
| -------: | ----------- | ---- | -------------------------------------------------------------------------------------------------------- |
|       $1 | file_or_dir | path | Either a regular file containing one job per line, or a directory containing one or more `*.jobs` files. |

**Returns**:

|  rc | Meaning                                                                                                                                                                                                                |
| --: | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0` | Every non-blank, non-comment line was parsed, validated, and appended to the global `JOBS` array. `JOBS` may legally be empty (with a `log_warn` fired) if the file contained only blanks and comments.                |
| `1` | File/directory not found, any line failed the grammar regex, any field contained a path-traversal `..` segment, any archive basename was empty or began with a dot, or a directory profile had zero `*.jobs` children. |

**Stdout**: silent.
**Stderr**: `log_error` on every rejection, with the line number and
the offending line. On directory profile, no per-file progress log.

**Preconditions**

- The global `JOBS` array exists (declared at the top of `lib/jobs.sh`).
- `log_error`, `log_warn`, `parse_job_line` are all defined.
- `$ROOT_DIR` is set (the file sources `job_format.sh` from there).

**Postconditions (on rc=0)**

- Every accepted line has been appended to `JOBS`.
- For a directory profile, every `*.jobs` file in the directory was
  processed in sorted order; the final `JOBS` is the concatenation
  of each file's accepted lines.

**Invariants**

- Directory profile is recursive only one level: `find -maxdepth 1`.
  A `*.jobs` file inside a subdirectory of the profile directory is
  **not** picked up.
- `*.jobs` files in a directory profile are loaded in locale-sorted
  order (`sort -z`), so filesystems with non-deterministic
  `readdir` order still produce deterministic job ordering.
- CRLF line endings are tolerated: trailing `\r` is stripped before
  the regex match. Without this, every line loaded from a
  Windows-edited file would be rejected and the operator would see
  a cryptic "invalid job" with no obvious cause.
- The grammar regex allows `_ . / - space ( )` in `iso_path` (the
  common `Game Name (USA).7z` pattern) but only `_ . / -` in
  `destination` (adapter destinations get passed to external tools
  whose quoting behaviour varies).
- `..` path-traversal check runs on both `iso_path` and
  `destination` after the grammar regex, via
  `parse_job_line` + a post-split regex. Both fields are checked
  because `..` in `iso_path` would escape pipeline-internal
  scratch roots, and `..` in `destination` would escape adapter
  sandbox roots like `LVOL_MOUNT_POINT`.
- Archive basename guard: after stripping `.7z`, the basename must
  be non-empty and must not begin with a dot. This catches
  `/..7z`, which survives the traversal regex (because `..` is
  followed by `7`, not `/` or end-of-string) and would otherwise
  cause `extract.sh` to compute `out_dir` as `$EXTRACT_DIR/.` —
  i.e. `$EXTRACT_DIR` itself — mixing sibling workers' output.
- **Required header/footer**: every `.jobs` file must contain a
  `---JOBS---` header line. Only lines between `---JOBS---` and
  `---END---` are treated as body (job) lines. Lines before the
  header and after the footer are ignored. `---END---` is optional;
  an open body (no footer) loads all remaining lines. A file
  missing the `---JOBS---` header fails with rc=1.
- **Block comments**: `/* ... */` pairs suppress all enclosed lines.
  `/*` must be the first non-whitespace on its line to open a block;
  `*/` must be the first non-whitespace on its line to close it.
  Unterminated `/*` (no matching `*/`) silently swallows the rest of
  the file (C semantics). Nesting is not supported. Block comment
  handling runs before blank/comment/header checks, so `#` lines
  inside a block are swallowed with everything else.
- Blank lines and full-line comments (`^#`) are silently skipped,
  not counted as errors.
- **Future column extensibility**: the grammar regex allows zero or
  more additional `|field` groups after the destination field. Each
  extra field allows `[A-Za-z0-9_./ ()-]`. Existing three-field
  lines parse unchanged; consumers that need field 4+ use an
  adapter-specific second-stage parser. `parse_job_line`'s `read -r`
  absorbs extra pipes into `destination_spec` by the three-variable
  contract. The hdl adapter is the live consumer — see
  `parse_hdl_destination` below for its 4-field extension
  (`<cd|dvd>|<title>` riding in fields 3–4 of a 4-field hdl line).
- **Adapter-specific load-time validation**: `load_jobs` runs any
  adapter-specific destination validator after grammar + basename
  checks succeed, so malformed extended-field rows surface with a
  clear line-number error at load time rather than silently passing
  through to a dispatch-time failure. Today the only validator is
  `parse_hdl_destination` for `hdl` rows.
- `load_jobs` **does not** validate that the iso_path exists on
  disk. A non-existent path is caught later when the worker tries
  to `du`/extract the archive; keeping the file check out of
  `load_jobs` lets the parser stay pure and fast.

**Side effects**

- Appends to the global `JOBS` array.
- Reads the jobs file (or every `*.jobs` file under a directory
  profile).
- Recursive self-call for each file in a directory profile.
- Writes `log_error` / `log_warn` lines to stderr.

**Error modes**

|               rc | Condition                                  | Characteristic stderr                                |
| ---------------: | ------------------------------------------ | ---------------------------------------------------- |
|                1 | Path not found                             | `job file or directory not found: <path>`            |
|                1 | Directory profile with zero `*.jobs` files | `no .jobs files found in directory: <path>`          |
|                1 | Missing `---JOBS---` header                | `missing ---JOBS--- header in <file>`                |
|                1 | Grammar regex mismatch                     | `invalid job at line <n>: '<line>'` + hint           |
|                1 | Path-traversal `..`                        | `path traversal attempt (..) at line <n>: '<line>'`  |
|                1 | Empty / dot-prefixed archive basename      | `invalid archive basename at line <n>: '<iso_path>'` |
| 0 (with warning) | Zero accepted lines                        | `no jobs found in <file>` via `log_warn`             |

**Example**

```bash
JOBS=()
if ! load_jobs "$JOBS_FILE"; then
    log_error "failed to load jobs"
    exit 1
fi
printf 'loaded %d jobs\n' "${#JOBS[@]}"
```

### `parse_hdl_destination`

**Source**: `lib/job_format.sh`
**Visibility**: public (adapter-specific second-stage parser)
**Test coverage**: `test/suites/14_unit_parsers.sh` U6

**Signature**
```
parse_hdl_destination <destination_spec>
```

| Position | Name             | Type   | Constraint                                                                                                                                |
| -------: | ---------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
|       $1 | destination_spec | string | The `destination_spec` returned by `parse_job_line` for a `hdl` row. Expected shape: `<format>\|<title>` with exactly one `\|` separator. |

**Returns**:

|  rc | Meaning                                                                                                                     |
| --: | --------------------------------------------------------------------------------------------------------------------------- |
| `0` | Valid. Two newline-separated fields printed to stdout: `format`, `title`.                                                   |
| `1` | Malformed. Nothing printed. Causes: wrong field count (missing or extra), `format` not literal `cd`/`dvd`, any field empty. |

**Stdout**: on rc=0, two newline-separated fields (one trailing
newline after the second). On rc=1, nothing.
**Stderr**: silent. Callers decide how to report failures — the hdl
adapter and precheck log and exit; `load_jobs` logs a line-number
error and returns 1.

**Preconditions**

- None beyond `$1` being set. The parser is pure text manipulation
  and has no dependency on pipeline globals.

**Postconditions (on rc=0)**

- Both output fields non-empty.
- `format ∈ {cd, dvd}`.

**Invariants**

- Splitting uses `IFS='|' read -r format title extra`. The `extra`
  slot must be empty on success — a 3rd field (or more) is rejected.
  This prevents silent acceptance of stale 6-field rows that were
  valid under the pre-refactor shape.
- `format` is validated against the literal allowlist `{cd, dvd}`.
  The allowlist is narrow because `hdl_dump` only understands
  `inject_cd` vs `inject_dvd`.
- `title` is a free-form string (constrained only by the outer
  grammar-regex allowlist `[A-Za-z0-9_./ ()-]`), so common PS2 title
  strings like `Shadow of the Colossus` and `Ratchet & Clank (USA)`
  — minus unsupported chars like `&` — work without escaping. The
  title slot necessarily rides last because the grammar regex's
  destination field does not allow spaces or parens, only the
  trailing slot does.
- Device targeting is **not** a parser concern. `HDL_HOST_DEVICE`
  and `HDL_INSTALL_TARGET` are operator-wide env vars read by
  `bin/loadout-pipeline.sh` (startup probe) and `adapters/hdl_dump.sh`
  (per-inject target) respectively. They do not appear in the job
  line.
- Pure. The parser has no side effects, opens no files, reads no
  env vars, and always returns the same output for the same input.
- **Rationale for a separate parser**: `parse_job_line` is frozen at
  three output fields so every non-hdl adapter keeps its existing
  contract. The hdl-specific fields live inside `destination_spec`
  and are only unpacked by consumers that care
  (`adapters/hdl_dump.sh`, `lib/precheck.sh`, and `load_jobs`'s
  load-time validator). This keeps the forward-compat mechanism
  (grammar regex allowing `(\|field)*`) clean for future extensions
  from any adapter.

**Side effects**: none.

**Error modes**

| rc | Condition                          | Notes                |
| --: | ---------------------------------- | -------------------- |
|  1 | Fewer than 2 `\|`-separated fields | Silent; caller logs. |
|  1 | More than 2 fields                 | Silent; caller logs. |
|  1 | `format` not `cd` or `dvd`         | Silent; caller logs. |
|  1 | Any field empty                    | Silent; caller logs. |

**Example**

```bash
if parsed="$(parse_hdl_destination "$destination_spec")"; then
    { read -r format; read -r title; } <<< "$parsed"
else
    log_error "malformed hdl destination: $destination_spec"
    exit 2
fi
```

### `strip_list_contains`

**Source**: `lib/strip_list.sh:45`
**Visibility**: public
**Test coverage**: `test/suites/14_unit_parsers.sh` U2

**Signature**
```
strip_list_contains <filename>
```

| Position | Name     | Type          | Constraint                                                                                           |
| -------: | -------- | ------------- | ---------------------------------------------------------------------------------------------------- |
|       $1 | filename | bare filename | No slash. If `$1` contains a slash, the helper still runs but will always return 1 (see invariants). |

**Returns**:

|  rc | Meaning                                                                                                                |
| --: | ---------------------------------------------------------------------------------------------------------------------- |
| `0` | `filename` matches a non-comment entry in the strip list file.                                                         |
| `1` | No match, OR the strip list file does not exist. A missing strip list is treated as "nothing to strip" — not an error. |

**Stdout**: silent.
**Stderr**: silent.

**Preconditions**

- `$EXTRACT_STRIP_LIST` is either set to a file path, or unset (in
  which case the helper falls back to `$ROOT_DIR/strip.list`).
- `$ROOT_DIR` is set (for the fallback).

**Postconditions**: pure lookup, no state change.

**Invariants**

- File format is line-based: one bare filename per line.
- Blank lines and lines whose first non-whitespace character is `#`
  are ignored. A comment on the same line as an entry is **not**
  supported; only full-line comments.
- Trailing whitespace on each entry is trimmed before comparison.
- An entry containing `/` is silently skipped rather than matched.
  The strip list is a bare-filename list; slash entries would need
  different semantics (path vs. filename) and the helper refuses
  to guess. Precheck and extract emit their own warnings for
  slash entries; this helper stays silent so the jobs scan does
  not produce a flood of duplicate warnings.
- A missing strip list file is **not** an error. It is equivalent
  to an empty list.
- Comparison is byte-exact, case-sensitive. `Strip.txt` is not the
  same as `strip.txt`.
- This is the **single source of truth** for "is this bare filename
  stripped?" — shared by `lib/precheck.sh` and
  `lib/resume_planner.sh`. If they disagreed, the planner might
  preserve a job the precheck would drop, defeating the cold-restart
  fast-path.

**Side effects**

- Reads the strip list file on every call. The file is small (~tens
  of entries) and this helper is called infrequently, so caching
  is not worthwhile.

**Error modes**: none. Any filesystem error on the `read` loop
surfaces as a non-zero from the `[[ -f ]]` guard.

**Example**

```bash
if strip_list_contains "Thumbs.db"; then
    log_debug "Thumbs.db is strip-listed — skipping"
fi
```
