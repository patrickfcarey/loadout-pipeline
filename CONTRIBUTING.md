# Contributing to loadout-pipeline

This document is the code-quality contract for this repository. Every rule
below is derived from an existing pattern in the codebase — they are
descriptive of what already works, not aspirational. New code is expected
to match these patterns so a future reader picking up any file finds the
same shape, the same idioms, and the same level of defence they expect
from the rest of the project.

If a rule here conflicts with something you see in an existing file, the
existing file is wrong — open a small fix PR for that file rather than
propagating the divergence.

**Companion documents (read first):**

- `ai_agent_entry_point.md` — architecture overview + **backwards-compat
  freeze policy** (binding for every PR)
- `docs/architecture.md` — pipeline flow, queue design, space ledger
- `docs/requirements/` — per-function contracts (the authoritative spec
  for any function with a `-Source:` citation)

---

## 1. Language and toolchain

- **Bash ≥ 4.2 only.** No `sh`, no `zsh`, no `fish`. Bash-specific
  features (`readarray`/`mapfile`, `BASH_SOURCE`, `FUNCNAME`, `[[ ]]`,
  associative arrays, `set -o functrace`, RETURN traps) are used
  throughout; do not downgrade to POSIX.
- **GNU coreutils assumed.** `realpath -m`, `stat -c %a`, `date +%s%3N`,
  `find -print0 | sort -z`, `flock`, `mktemp -d` are all load-bearing.
  macOS contributors install coreutils via Homebrew; see
  `adapters/lvol.sh:74-78` for how a missing `realpath` is handled
  (fail loud, don't degrade to no check).
- **No external runtimes.** Pure shell + the utilities listed in
  `lib/prereq.sh`. No Python, Node, Go, awk-heavy DSLs. If you reach for
  a new binary dependency, add it to `check_prerequisites` and justify
  it in the PR.

---

## 2. File shape

### 2.1 Entry-point scripts (`bin/*.sh`, `adapters/*.sh`, tests)

Every executable file starts with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

`-e` catches silent failures, `-u` catches typo'd variable names, and
`-o pipefail` catches failures in the middle of a `|` pipeline. All
three are mandatory. If you need to narrow `-e` for a specific command,
narrow it to exactly that command (`set +e; cmd; rc=$?; set -e`) rather
than disabling it for the whole script — see `lib/precheck.sh` for the
pattern.

Adapter scripts additionally discover `ROOT_DIR` and source the logging
library:

```bash
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/lib/logging.sh"
```

The `${ROOT_DIR:-...}` default expansion lets tests pre-export
`ROOT_DIR` to redirect at a fixture, while direct invocations still
self-discover.

### 2.2 Sourced libraries (`lib/*.sh`)

Libraries use the same first line but no `set -euo pipefail` (they
inherit the caller's shell options). They declare themselves sourced-only
with a comment at the top:

```bash
#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly
```

If a library sources another library, use the same `ROOT_DIR` discovery
pattern — see `lib/jobs.sh:7-8`.

**Source order matters.** `bin/loadout-pipeline.sh` sources
`lib/config.sh` first (defines + validates every env var) and
`lib/logging.sh` second (installs the RETURN trap before any function
is defined). New libraries go at the end of the source list unless
they have a dependency reason to move up.

### 2.3 File layout rules

| Directory           | Purpose                                        | Rule                                                          |
| ------------------- | ---------------------------------------------- | ------------------------------------------------------------- |
| `bin/`              | Pipeline entry points                          | Thin orchestrators only. No business logic.                   |
| `lib/`              | Sourced libraries                              | Pure functions + validated state. No top-level I/O.           |
| `adapters/`         | Subprocess scripts (2-arg contract)            | `<src> <dest>` invocation — frozen. See §8.                   |
| `tools/`            | Operator tooling (smart wrapper, perf harness) | Compat-exempt until stabilised; see `ai_agent_entry_point.md` |
| `test/suites/`      | Unit tests (numbered `01_` … `21_`)            | Run inside parent shell.                                      |
| `test/integration/` | Integration tests (mirror unit numbering)      | Run inside privileged Docker.                                 |
| `docs/`             | Prose docs                                     | Architecture + per-function contracts.                        |
| `examples/`         | Sample `.jobs` files                           | Must parse under the current grammar.                         |

---

## 3. Naming

- **Exported env vars**: `SCREAMING_SNAKE_CASE`. Every one declared in
  `lib/config.sh` with a `${VAR:-default}` fallback.
- **Public functions**: `snake_case` verb phrases (`load_jobs`,
  `space_reserve`, `worker_job_begin`). Discoverable from the spec.
- **Private helpers**: `_snake_case` with leading underscore
  (`_spool_sweep_and_claim`, `_precheck_member_is_safe`,
  `_build_strip_args`). Not part of the public contract — rename freely
  unless a unit test pins them.
- **Loop variables inside functions**: short single-letter or underscore-prefixed
  (`_j`, `_cfg_var`, `_dotenv_line`). Always `local` or `unset` at end
  to avoid leaking into caller scope.
- **Globals**: `UPPER_CASE`, declared at the top of their owning library
  (`JOBS=()` in `lib/jobs.sh:10`). Prefer passing state through
  function arguments; globals exist only for cross-stage communication
  (`JOBS`, `COPY_SPOOL`).

---

## 4. Comments and documentation

### 4.1 File headers

Every non-trivial file gets a header block that describes **what** and
**why**:

```bash
# =============================================================================
# ADAPTER: LOCAL VOLUME  (local directory copy)
# =============================================================================
# Copies an extracted directory to a local path under LVOL_MOUNT_POINT.
# LVOL_MOUNT_POINT can be any writable local directory: an SD card, a USB
# drive (NVMe/SSD/HDD), a NAS mountpoint, or a plain folder on disk.
#
# ARGUMENTS
#   $1  src   — absolute path to the extracted directory to copy
#   $2  dest  — destination subdirectory path under LVOL_MOUNT_POINT
# ...
```

See `adapters/lvol.sh:1-28` and `adapters/hdl_dump.sh:1-33` as the
template. The header is the one place where WHAT belongs — everywhere
else, prefer WHY.

### 4.2 Function docblocks

Public library functions get a block comment immediately above the
definition. The required fields are **Parameters**, **Returns**,
**Modifies**, **Locals**. See `lib/logging.sh:13-25` for the minimal
shape and `lib/workers.sh:30-55` for a rich one.

```bash
# ─── name ────────────────────────────────────────────────────────────────────
# One-paragraph description: what the function does and why it exists.
#
# Parameters
#   $1  name — purpose and type
#
# Returns
#   0 — success case
#   1 — failure case (with what it means)
#
# Modifies
#   <globals/env/filesystem>
#
# Locals
#   <each local variable>
# ─────────────────────────────────────────────────────────────────────────────
```

For private `_helpers`, a shorter one-to-three-line comment is fine —
but never zero lines. If you can't write a sentence about why the
helper exists, you haven't justified the helper.

### 4.3 Inline comments

- **Explain WHY, not WHAT.** The code already says what. Comments
  document hidden constraints, subtle invariants, past-bug rationale,
  surprising behaviour.
- **Past-bug rationale is load-bearing.** When a rule exists because a
  prior bug bit us, say so — see `lib/config.sh:15-21` ("the final
  line even when the file has no trailing newline — a classic bash
  pitfall that is particularly insidious here") and
  `lib/workers.sh:66-73` (PID-reuse guard). Deleting those comments is
  how the bug comes back.
- **No commentary on the current task.** Don't write `# fix for issue #123`
  or `# added during the hdl refactor`. Those belong in the commit
  message. Comments rot; git history doesn't.
- **No reference-to-caller comments.** Don't write `# called by
  lib/dispatch.sh` — `grep` finds that. Comments describe the function,
  not its graph.

### 4.4 Section dividers

Use Unicode horizontal rules to break files into sections:

```bash
# ── validate ─────────────────────────────────────────────────────────────────
# ── locate the ISO ───────────────────────────────────────────────────────────
```

Function docblocks use a slightly different rule (`# ─── name ───`) to
distinguish them visually. Both patterns are in the codebase — match
the surrounding file.

---

## 5. Error handling

### 5.1 Exit codes

The pipeline distinguishes three exit classes; preserve them.

| rc | Meaning                                         | Example                                        |
| --: | ----------------------------------------------- | ---------------------------------------------- |
|  0 | Success (or "already present", in precheck)     | `extract.sh` logs `[skip]` and exits           |
|  1 | Runtime failure — re-runnable                   | Transfer failed, source missing                |
|  2 | Fatal preflight failure — not re-runnable       | Bad config, malformed job line, unsafe archive |
| 75 | Temporary backpressure (space-reservation miss) | `extract.sh` — worker re-queues with backoff   |

`exit 2` is specifically reserved for config-validation failures.
Tooling greps for exit 2 + stderr pattern to distinguish "your .env is
broken" from "a transfer failed."

### 5.2 Error messages

Every `log_error` call must:

1. **Name the offending thing.** `"MAX_UNZIP must be a positive integer,
   got '${!_cfg_var}'"` — not "invalid config." The operator reading
   stderr shouldn't have to `grep` their own `.env` to figure out which
   variable is wrong.
2. **State what would fix it.** When the fix is non-obvious, add a
   second `log_error` line with the fix — see `adapters/hdl_dump.sh:71-73`
   ("install ps2homebrew/hdl-dump or set HDL_DUMP_BIN to an absolute
   path") and `adapters/lvol.sh:75-77` (install coreutils).
3. **Use the adapter/subsystem tag.** Adapters prefix with the adapter
   name (`[lvol]`, `[hdl]`, `[rclone]`); libraries use the subsystem
   tag visible in log output (`[config]`, `[spool guard:]`). See the
   log-format table in `docs/architecture.md`.

### 5.3 Fail-fast over degrade-silently

- Validate config at **load time** with the offending name in the error —
  see `lib/config.sh:135-168`. A misconfigured env var should stop the
  pipeline before workers spin up, not hang it forever waiting for a
  sentinel.
- Refuse ambiguity. Zero ISOs in an extract = fatal. Two ISOs in an
  extract = fatal; the adapter does not guess which one to inject.
  See `adapters/hdl_dump.sh:86-97`.
- Refuse unsafe inputs explicitly. Path traversal (`..`) is rejected
  in both `iso_path` and `destination` fields — see `lib/jobs.sh` and
  `lib/precheck.sh:_precheck_member_is_safe`. A missing guard
  utility (`realpath`) is a fatal error, **not** a reason to skip the
  guard — see `adapters/lvol.sh:74-78`.

### 5.4 Startup probes

When a class of job depends on external infrastructure that could fail
uniformly for every job in the batch (network share mounted wrong, PS2
HDD disconnected, FTP creds bad), add a startup probe in
`bin/loadout-pipeline.sh` that fails before the worker pool starts.
See the hdl probe at `bin/loadout-pipeline.sh:37-49`. The probe is
best-effort: skip it gracefully if the probe's dependencies aren't
configured (e.g. `HDL_HOST_DEVICE` unset → skip).

### 5.5 Traps and cleanup

- `extract.sh` uses an EXIT trap to `space_release`. Any worker that
  reserves shared state must release it from an EXIT trap — not at
  the end of the function — so SIGKILL / `set -e` unwinds don't leak.
- `mktemp -d` tempdirs: install `trap 'rm -rf "$tmpdir"' EXIT` at the
  point of creation. The trap should be set **before** the first
  operation that could fail inside the temp dir.
- The integration bootstrap has a single EXIT/INT/TERM teardown trap —
  see `test/integration/helpers/bootstrap.sh`. Add new substrate to the
  existing trap; don't chain a second one.

---

## 6. Logging

Logging is a contract, not decoration. See `lib/logging.sh`.

`DEBUG_IND` has **three hierarchical levels** (`0` / `1` / `2`), validated
in `lib/config.sh` — a typo aborts startup with exit 2 rather than
silently degrading to 0. Level 2 is a superset of level 1; level 1 is a
superset of level 0.

| Function     | Stream | Level | Use when                                                                                       |
| ------------ | ------ | ----- | ---------------------------------------------------------------------------------------------- |
| `log_info`   | stdout | all   | Top-level operator milestones from `bin/loadout-pipeline.sh`                                   |
| `log_warn`   | stderr | all   | Recoverable issue the operator should know about                                               |
| `log_error`  | stderr | all   | Failure path — always accompany a non-zero return / exit                                       |
| `log_enter`  | stderr | 1+    | First line of a sourced-lib function; pass `"$@"` to echo args at level 2                      |
| `log_debug`  | stderr | 1+    | Intermediate state in a sourced-lib function                                                   |
| `log_trace`  | stderr | 1+    | Subprocess scripts (`adapters/*`, `extract.sh`) where `FUNCNAME` is meaningless                |
| `log_cmd`    | stderr | 2     | Audit an external command about to run — `log_cmd rsync -a ...` **before** the real invocation |
| `log_var`    | stderr | 2     | Dump a variable's resolved value — pass the **NAME**: `log_var MAX_UNZIP`                      |
| `log_fs`     | stderr | 2     | Filesystem mutations in hot paths (mv / rm / flock acquire/release)                            |
| `log_xtrace` | stderr | 2     | Level-2 analogue of `log_trace` for subprocess scripts                                         |

Rules:

- **All non-operator output goes to stderr.** Only `log_info` writes to
  stdout, and only from the top-level orchestrator. This keeps
  stdout clean for future features (parseable status output, piping to
  jq, etc.).
- **`log_enter` + RETURN trap**: sourced-lib functions start with
  `log_enter`. The matching exit log is installed automatically by the
  RETURN trap in `lib/logging.sh:213-233` — don't add a manual
  `log_debug "exiting"` at the end. At level 2 the exit line includes
  `rc=<code>`.
- **`log_cmd` does not execute the command.** Log it, then run it.
  Coupling log to execution would make error handling murky:
  ```bash
  log_cmd rsync -a "$src/" "$target/"
  rsync -a "$src/" "$target/"
  ```
- **`log_var` takes the variable NAME**, not the value. It uses bash
  indirect expansion (`${!name}`) internally. Unset and empty both
  print as empty.
- **Adapter log prefix**: user-visible progress goes through
  `echo "[<adapter>] ..."` (see `adapters/lvol.sh:96`). Debug goes
  through `log_trace` (level 1) or `log_xtrace` (level 2). Don't
  `printf` directly to stdout from an adapter.
- **`$?` inside the RETURN trap** reflects the last command executed in
  the function body — not an explicit `return N` argument. If you need
  the `rc=` trace to surface a failure, make the final command fail
  (e.g. `false; return` over `return 1`). This is a bash quirk, not a
  framework choice.
- **Two strings are grep-anchored by tooling** and must not be
  reworded:
  - `"space reservation miss"` (in `lib/workers.sh`)
  - `"stub"` (in stub adapters that refuse with `ALLOW_STUB_ADAPTERS=0`)

---

## 7. Concurrency and shared state

The pipeline is concurrent by design: two worker pools, a shared space
ledger, a shared worker registry, and a queue directory that multiple
processes read/write. Every pattern below exists because a naive
implementation corrupted state at some point.

- **All queue mutations use atomic `mv`.** A worker "claims" a job by
  `mv`ing the file to a `.claimed.<pid>` suffix; only one `mv` wins per
  filename. Never `cat` / delete / read-then-remove.
- **All ledger mutations are `flock`-guarded.** `lib/space.sh` and
  `lib/worker_registry.sh` both take an exclusive flock on a sibling
  `.lock` file before check-and-commit. The whole critical section
  runs inside the flock.
- **Per-run isolation via `$$`.** Scratch spool is `$COPY_DIR/$$`; the
  test framework's `/tmp` paths all use `$$`; integration bootstrap
  uses `$$` for loopback file names. Never share a scratch directory
  between concurrent runs.
- **Startup sweep of dead PIDs.** Before claiming a per-run dir, sweep
  sibling dirs whose PID no longer passes `kill -0`. See
  `_spool_sweep_and_claim` in `lib/workers.sh`.
- **PID-reuse guard.** After the sweep, unconditionally `rm -rf` your
  own claimed dir before `mkdir -p`. PID-space wrap-around can collide.
- **Test for the race.** Concurrency patterns get their own unit tests
  (suite 19); see `Q1`, `Q3`, `R7` for the shape — fork N worker
  processes, let them race, assert no duplicate claims.

---

## 8. Adapter contract (frozen)

Every `adapters/<name>.sh` obeys the same interface:

```bash
bash adapters/<name>.sh <src_dir> <dest_subpath>
```

- **`$1`** = absolute path to the extracted payload directory.
- **`$2`** = adapter-specific destination string (from the job line).
- **Exit codes**: `0` on success, `1` on failure or validation refusal.
- **Environment**: adapters run under `env -u` stripping (see
  `lib/dispatch.sh:_build_strip_args`); declare every env var your
  adapter reads in its corresponding `_<ADAPTER>_ENV_VARS` array in
  `lib/dispatch.sh`. Variables not listed are unset before fork.
- **Semantics**: copy the **contents** of `$src` into `$dest`, not
  `$src` itself as a subdirectory. This matches precheck's convention
  (`$dest/<member>`, not `$dest/$(basename $src)/<member>`).
- **Validation before mutation**: check every precondition before
  touching the destination. See `adapters/lvol.sh:41-90` as the
  template.
- **Stub refusal**: scripts that are not yet implemented (`ftp.sh`,
  `rclone.sh`) refuse with `exit 1` and a message containing the word
  `stub` — unless `ALLOW_STUB_ADAPTERS=1`. Suite 20 A1 pins this as a
  regression guard. Do not silently succeed.

Adding a new adapter is a five-step change:

1. Create `adapters/<name>.sh` matching the existing shape.
2. Add a case arm in `lib/dispatch.sh`.
3. Add a case arm in `lib/precheck.sh` (or accept the default "not
   present" stub).
4. Extend the grammar regex in `lib/jobs.sh` to accept the new key.
5. Declare env vars in `lib/config.sh` and document them in
   `.env.example` + `README.md`.

All five are mandatory. Missing step 4 means `load_jobs` rejects every
line that uses your adapter; missing step 2 means dispatch silently
falls through the default branch.

---

## 9. Testing

### 9.1 Every change must keep the suite green

```bash
bash test/run_tests.sh         # unit suite
bash test/validate_tests.sh    # mutation validation
bash test/integration/launch.sh  # integration (requires Docker)
```

A merge-ready PR passes all three with **0 failures**. The unit suite
assertion count has a **non-regression floor** — see
`ai_agent_entry_point.md:79-81`. A dropping count means a pinned
behaviour was silently removed; investigate before merging.

### 9.2 Unit test conventions

- Suites are sourced, not forked — counters live in the parent shell.
  See `test/run_tests.sh:56-78`.
- Every test opens with `header "Test <ID>: <short description>"`.
  The `<ID>` is a letter + number (`U6`, `A1`, `R7`, `C3`). New tests
  pick the next free number in the relevant letter block.
- Every assertion calls `pass "<reason>"` or `fail "<reason>"`. Don't
  call `echo` + `(( FAIL++ ))` by hand — use the helpers so summary
  accounting stays correct.
- Subshell-isolated unit tests use the `_u_run_subshell` pattern in
  `test/suites/14_unit_parsers.sh:25-32`: the subshell emits `PASS ...`
  / `FAIL ...` lines on stdout, the parent shell pipes them back into
  the counter helpers.
- **Reason text**: say what was tested, not just "OK." `pass "happy
  path parsed into three correct fields"` is a better regression
  anchor than `pass "parse_job_line"`.

### 9.3 Integration test conventions

- Integration suites live in `test/integration/suites/` and mirror
  unit-suite numbering so a regression in both files shows up at a
  consistent ID.
- The integration container is **privileged** on purpose (`losetup`,
  `mkfs.vfat`, loopback mounts). Do not try to fake substrate with
  shims — the whole point is to exercise real kernel paths.
- Substrate setup goes in `test/integration/helpers/bootstrap.sh`.
  Teardown goes in the single EXIT/INT/TERM trap. Do not install a
  second trap.
- Fixtures that are slow to generate (synthetic archives, loopback
  images) are cached by presence — regenerate only when missing.
- Integration tests for real services (FTP, rclone, SSH) use real
  daemons inside the container, not mocks.

### 9.4 Mutation validation

Every meaningful assertion in `run_tests.sh` gets a paired `V-check` in
`validate_tests.sh` that **mutates the code**, runs the assertion, and
expects it to fail. An assertion with no V-check is dead weight — if it
can't distinguish working code from broken code, it isn't actually
testing anything. When you add a new assertion, add the V-check in the
same PR.

### 9.5 Fixtures

- No absolute paths baked into committed `.jobs` files. The test
  orchestrator generates `.jobs` at runtime with `$ROOT_DIR` + `$$`
  paths — see `test/run_tests.sh:23-34`. A committed absolute path
  breaks the moment the repo is cloned somewhere else.
- Unit fixtures go in `test/fixtures/`. Integration fixtures generated
  by the container go in `test/integration/fixtures/`.
- `${EXTRACT_BASE:?}` style guards in cleanup helpers — see
  `test/helpers/framework.sh:227`. A typo that unsets the variable
  would otherwise `rm -rf /`.

---

## 10. Security

The pipeline runs untrusted input (archives and `.jobs` files) and
writes to operator-owned destinations. Defence-in-depth is not
optional.

- **`..` rejected in both `iso_path` and `destination`.** Post-regex
  check — see `lib/jobs.sh`.
- **Destination containment enforced with `realpath -m`.** Adapters
  that write to a configurable root resolve both root and target to
  canonical form and assert target-under-root. See
  `adapters/lvol.sh:63-89`. **Missing `realpath` is fatal**, not a
  reason to skip the check.
- **Archive-member paths checked via `_precheck_member_is_safe`.** A
  malicious archive with `../../etc/passwd` inside is rejected at
  precheck, not at extract. See `lib/precheck.sh`.
- **Credentials are scoped per adapter.** `lib/dispatch.sh` uses
  `env -u` to strip every other adapter's credentials before forking
  the target adapter. An `rclone` adapter cannot see `FTP_PASS`.
- **`.env` permission warning.** `lib/config.sh:7-13` warns if `.env`
  is group- or world-readable. Don't remove the warning to make tests
  quieter; fix the test fixture permissions instead.
- **No `eval` on user input.** The codebase uses zero `eval` calls on
  job-file content; keep it that way. Parse with `read`, compare with
  `case` / `[[ ]]`, never expand input as shell.

---

## 11. Backwards compatibility

**The public interface surface of this pipeline is frozen.** Full
policy in `ai_agent_entry_point.md:23-81`. Summary:

- **Frozen**: CLI entry point argument shape, env var names and
  defaults, `.env` parser edge cases, the `~<iso>|<adapter>|<dest>~`
  grammar, adapter 2-arg contract, exit-code semantics, and every
  function pinned by a unit test in `test/suites/14_` … `20_`.
- **Not frozen**: test hooks (`ALLOW_STUB_ADAPTERS`,
  `SPACE_AVAIL_OVERRIDE_BYTES`), `tools/perf/` CLI flags until
  stabilised, private `_helpers` not pinned by a test, cosmetic log
  wording (except the two tooling-grepped strings listed in §6).
- **Additions are always allowed.** New env vars with defaults, new
  CLI flags, new adapters, new job-line fields (consumed via an
  adapter-specific parser) — all safe. The hdl adapter's 4-field
  extension (`parse_hdl_destination`) is the live example.

If you want to rename an env var "for consistency" or drop a flag
"because nobody uses it," stop and propose a new name in parallel
instead. A major-version bump is the only way to break compat, and
the bar for one is high.

---

## 12. PR checklist

Before opening a PR, confirm every item:

- [ ] Code follows the file-shape, naming, and documentation rules
      above.
- [ ] Every new function has a docblock with Parameters / Returns /
      Modifies / Locals.
- [ ] Every new env var has a default in `lib/config.sh`, is
      documented in `.env.example` and `README.md`, and if numeric is
      validated in the `_cfg_var` loops.
- [ ] Every new error path has a `log_error` that names the offending
      thing and (if non-obvious) states the fix.
- [ ] `bash test/run_tests.sh` passes with **no drop** in assertion
      count from the baseline in `ai_agent_entry_point.md`.
- [ ] `bash test/validate_tests.sh` passes — every new assertion has a
      paired V-check.
- [ ] `bash test/integration/launch.sh` passes (or: you state in the
      PR that you couldn't run it and why — e.g. no Docker host).
- [ ] Docs updated **in the same PR** as the code: `README.md`,
      `docs/architecture.md`, `docs/requirements/<subsystem>.md`,
      `ai_agent_entry_point.md` wherever affected.
- [ ] Commit messages explain WHY. "Add X" is not a message; "Add X
      because the prior approach corrupted state under concurrent Y"
      is.
- [ ] No new binary dependencies without a corresponding
      `check_prerequisites` update.
- [ ] No new absolute paths baked into committed `.jobs` or test
      fixtures.

---

## 13. Don'ts

Patterns that look tempting but are banned:

- **Don't `eval` user input.** Ever. See §10.
- **Don't disable `set -e` for a whole script** to quiet one noisy
  command. Narrow it to the specific call.
- **Don't use `exit 1` for config errors.** Use `exit 2`. Tooling
  distinguishes them.
- **Don't silently succeed on missing dependencies.** `realpath`,
  `flock`, `hdl_dump`, `rsync` — either they're present and you use
  them, or you exit with a clear error. Never "skip the check and
  hope."
- **Don't add `TODO` without a linked issue or the exact file that
  needs changing.** A stale TODO is worse than no comment. See
  `docs/requirements/` for the pattern — every contract lists
  **Exemptions** explicitly rather than leaving TODO notes in code.
- **Don't write defensive try/catch around code that can't actually
  fail.** Trust framework guarantees. Only validate at boundaries:
  user input, external APIs, filesystem operations.
- **Don't create `.md` files the repo didn't ask for.** Implementation
  docs belong in existing `docs/` files; one-off notes belong in the
  PR description, not a new `NOTES.md`.
- **Don't amend published commits** unless explicitly asked. Add new
  commits — the history is a log, not a draft.
- **Don't `rm -rf` without a guard.** See
  `lib/workers.sh:_spool_guarded_rm_rf` — every destructive path in
  the codebase asserts the target lives under an expected parent
  before running `rm -rf`. Follow the pattern.
- **Don't commit with `--no-verify`.** If a hook fails, fix the
  underlying issue.

---

*This document is a living contract. If you find a pattern in the code
that isn't reflected here — and you think it should be — open a small
PR that adds it. Rules derived from one good pattern are worth adding;
rules derived from one-off experiments are not.*
