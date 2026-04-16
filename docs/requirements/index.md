# loadout-pipeline — Per-Function Requirements

This directory is the authoritative contract for every shell function
and script entry point shipped by loadout-pipeline. Each subsystem doc
contains a full-spec requirements block — signature, preconditions,
postconditions, invariants, side effects, error modes, example — for
every function (public **and** private) in its scope.

The goal is a single place where each function's behavior is spelled
out as a contract the test suite checks *against*, not just the
incidental behavior the tests happen to pin. When you change the
behavior of any function documented here, update its requirements
block in the same commit and call out the change in the commit
message per the compat policy in
[`ai_agent_entry_point.md#backwards-compatibility-required`](../../ai_agent_entry_point.md).

See also:

- [`../architecture.md`](../architecture.md) — narrative overview of
  how the subsystems fit together.
- [`../../README.md`](../../README.md) — user-facing quick start and
  configuration reference.
- [`../../ai_agent_entry_point.md`](../../ai_agent_entry_point.md) —
  orientation doc for AI agents touching the codebase, including the
  frozen public interface surface.

## Subsystems

| # | Doc | Scope | Functions |
|---:|---|---|---:|
| 1 | [`bootstrap.md`](bootstrap.md)                         | `lib/config.sh` validation + `lib/logging.sh` + `lib/prereq.sh` + `lib/init.sh` + `bin/loadout-pipeline.sh` entry contract | 9 fns + 2 scripts |
| 2 | [`job_parsing.md`](job_parsing.md)                     | `lib/job_format.sh` + `lib/jobs.sh` + `lib/strip_list.sh` — the `~src\|adapter\|dest~` grammar and strip-list file format | 3 fns |
| 3 | [`queue.md`](queue.md)                                 | `lib/queue.sh` — atomic-mv claim semantics for the two-stage queue | 3 fns |
| 4 | [`space_ledger.md`](space_ledger.md)                   | `lib/space.sh` — flock-guarded reservation ledger with device pooling | 11 fns |
| 5 | [`worker_registry.md`](worker_registry.md)             | `lib/worker_registry.sh` — BASHPID-indexed worker accounting for SIGKILL recovery | 6 fns |
| 6 | [`workers_orchestration.md`](workers_orchestration.md) | `lib/workers.sh` — the two worker loops, pass runner, spool sweep, recovery loop | 10 fns |
| 7 | [`extraction_pipeline.md`](extraction_pipeline.md)     | `lib/extract.sh` + `lib/precheck.sh` + `lib/dispatch.sh` — per-job orchestration inside the workers | 5 fns + 3 scripts |
| 8 | [`resume_planner.md`](resume_planner.md)               | `lib/resume_planner.sh` — cold-restart fast-path pre-pass | 6 fns |
| 9 | [`adapters.md`](adapters.md)                           | `adapters/lvol.sh` + `adapters/rsync.sh` real adapters + 3 stub script contracts (ftp, hdl_dump, rclone) | 5 scripts |
| 10 | [`performance_framework.md`](performance_framework.md) | `tools/perf/perf_metrics.sh` + `perf_recommender.sh` + `perf_harness.sh` + `perf_report.sh` (tools-tier, compat-exempt) | 7 fns + 2 scripts |

## Function-name index

Alphabetical. Jump from a grep hit straight to the contract.

| Function | Visibility | Subsystem |
|---|---|---|
| [`_assert_pipeline_dir_safe`](bootstrap.md#_assert_pipeline_dir_safe) | private | bootstrap |
| [`_build_strip_args`](extraction_pipeline.md#_build_strip_args) | private | extraction_pipeline |
| [`_dispatch_handle_job`](workers_orchestration.md#_dispatch_handle_job) | private | workers_orchestration |
| [`_maybe_flatten_wrapper`](extraction_pipeline.md#_maybe_flatten_wrapper-libextractsh) | private | extraction_pipeline |
| [`_on_exit`](extraction_pipeline.md#_on_exit-libextractsh) | private | extraction_pipeline |
| [`_perf_metrics_self_test`](performance_framework.md#_perf_metrics_self_test) | private | performance_framework |
| [`_perf_recommender_self_test`](performance_framework.md#_perf_recommender_self_test) | private | performance_framework |
| [`_pipeline_run_init`](workers_orchestration.md#_pipeline_run_init) | private | workers_orchestration |
| [`_precheck_member_is_safe`](extraction_pipeline.md#_precheck_member_is_safe) | private | extraction_pipeline |
| [`_recover_orphans`](workers_orchestration.md#_recover_orphans) | private | workers_orchestration |
| [`_resume_plan_archive_members`](resume_planner.md#_resume_plan_archive_members) | private | resume_planner |
| [`_resume_plan_dest_for_job`](resume_planner.md#_resume_plan_dest_for_job) | private | resume_planner |
| [`_resume_plan_job_is_satisfied`](resume_planner.md#_resume_plan_job_is_satisfied) | private | resume_planner |
| [`_resume_plan_load_dest_cache`](resume_planner.md#_resume_plan_load_dest_cache) | private | resume_planner |
| [`_resume_plan_member_is_safe`](resume_planner.md#_resume_plan_member_is_safe) | private | resume_planner |
| [`_run_worker_pass`](workers_orchestration.md#_run_worker_pass) | private | workers_orchestration |
| [`_space_apply_overhead`](space_ledger.md#_space_apply_overhead) | private | space_ledger |
| [`_space_avail_bytes`](space_ledger.md#_space_avail_bytes) | private | space_ledger |
| [`_space_dev`](space_ledger.md#_space_dev) | private | space_ledger |
| [`_space_ledger_gc_phantoms`](space_ledger.md#_space_ledger_gc_phantoms) | private | space_ledger |
| [`_space_ledger_path`](space_ledger.md#_space_ledger_path) | private | space_ledger |
| [`_space_lock_path`](space_ledger.md#_space_lock_path) | private | space_ledger |
| [`_space_reserved_on_dev`](space_ledger.md#_space_reserved_on_dev) | private | space_ledger |
| [`_spool_guarded_rm_rf`](workers_orchestration.md#_spool_guarded_rm_rf) | private | workers_orchestration |
| [`_spool_sweep_and_claim`](workers_orchestration.md#_spool_sweep_and_claim) | private | workers_orchestration |
| [`_strip_pass`](extraction_pipeline.md#_strip_pass-libextractsh) | private | extraction_pipeline |
| [`_unzip_handle_job`](workers_orchestration.md#_unzip_handle_job) | private | workers_orchestration |
| [`_wr_lock_path`](worker_registry.md#_wr_lock_path) | private | worker_registry |
| [`_wr_path`](worker_registry.md#_wr_path) | private | worker_registry |
| [`check_prerequisites`](bootstrap.md#check_prerequisites) | public | bootstrap |
| [`dispatch_worker`](workers_orchestration.md#dispatch_worker) | public | workers_orchestration |
| [`init_environment`](bootstrap.md#init_environment) | public | bootstrap |
| [`load_jobs`](job_parsing.md#load_jobs) | public | job_parsing |
| [`log_debug`](bootstrap.md#log_debug) | public | bootstrap |
| [`log_enter`](bootstrap.md#log_enter) | private | bootstrap |
| [`log_error`](bootstrap.md#log_error) | public | bootstrap |
| [`log_info`](bootstrap.md#log_info) | public | bootstrap |
| [`log_trace`](bootstrap.md#log_trace) | public | bootstrap |
| [`log_warn`](bootstrap.md#log_warn) | public | bootstrap |
| [`parse_job_line`](job_parsing.md#parse_job_line) | public | job_parsing |
| [`perf_recommend_workers`](performance_framework.md#perf_recommend_workers) | public | performance_framework |
| [`perf_sample_cpu`](performance_framework.md#perf_sample_cpu) | public | performance_framework |
| [`perf_sample_disk`](performance_framework.md#perf_sample_disk) | public | performance_framework |
| [`perf_sample_queue`](performance_framework.md#perf_sample_queue) | public | performance_framework |
| [`perf_sample_space_retries`](performance_framework.md#perf_sample_space_retries) | public | performance_framework |
| [`queue_init`](queue.md#queue_init) | public | queue |
| [`queue_pop`](queue.md#queue_pop) | public | queue |
| [`queue_push`](queue.md#queue_push) | public | queue |
| [`resume_plan`](resume_planner.md#resume_plan) | public | resume_planner |
| [`space_init`](space_ledger.md#space_init) | public | space_ledger |
| [`space_ledger_empty`](space_ledger.md#space_ledger_empty) | public | space_ledger |
| [`space_release`](space_ledger.md#space_release) | public | space_ledger |
| [`space_reserve`](space_ledger.md#space_reserve) | public | space_ledger |
| [`strip_list_contains`](job_parsing.md#strip_list_contains) | public | job_parsing |
| [`unzip_worker`](workers_orchestration.md#unzip_worker) | public | workers_orchestration |
| [`worker_job_begin`](worker_registry.md#worker_job_begin) | public | worker_registry |
| [`worker_job_end`](worker_registry.md#worker_job_end) | public | worker_registry |
| [`worker_registry_init`](worker_registry.md#worker_registry_init) | public | worker_registry |
| [`worker_registry_recover`](worker_registry.md#worker_registry_recover) | public | worker_registry |
| [`workers_start`](workers_orchestration.md#workers_start) | public | workers_orchestration |

## Conventions

**Template.** Every function block uses the same structure:

```
### `fn_name`

**Source**: lib/foo.sh:NN
**Visibility**: public | private (_prefixed)
**Test coverage**: test/suites/NN_name.sh (label) — or "none — not currently asserted"

**Signature** ... parameter table ...
**Returns / Stdout / Stderr**
**Preconditions / Postconditions / Invariants**
**Side effects / Error modes / Example**
**Exemptions (if any)**
```

**Script contracts** use the same template but replace "Signature"
with "Invocation" and add an "Env dependencies" block listing every
environment variable the script reads.

**Source line numbers** are a snapshot at the time the doc was
written. A `grep` for the function name that surfaces a stale line
number means the source moved — the doc must be updated in the same
commit per the compat policy.

**Test coverage** either cites the specific suite and assertion label
that pins the function, or says `none — not currently asserted`
explicitly so gaps in coverage are visible rather than invisible.
Public functions with no coverage are a red flag — the freeze expects
at least one pinning test.

**Exemptions** are called out in each function block. The two standing
exemptions are:

- `SPACE_AVAIL_OVERRIDE_BYTES` — test hook inside `space_reserve` /
  `_space_avail_bytes` that bypasses `df`. Not frozen.
- `ALLOW_STUB_ADAPTERS` — test hook that allows stub adapters to be
  used in harness runs and unit tests without falling back to the
  default-refuse guard. Not frozen.
- `tools/perf/` as a whole is compat-exempt until the first real
  sweep informs a stable rule set.
