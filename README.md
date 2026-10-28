# LLM Parallelization Evaluation — Experiment Scripts

This repository contains the experiment, validation, benchmarking, and scoring scripts for the paper:

> **Evaluating the Parallelization Capabilities of State-of-the-art Agentic Large Language Models**  
> Peter Thoman and Philipp Gschwandtner, University of Innsbruck  
> Accepted in **Euro-Par 2026**: 32nd International European Conference on Parallel and Distributed Computing
> *Full citation information to follow*

## Overview

This infrastructure allows tasking state-of-the-art LLM agents 
(accessed through a common agentic interface) with parallelizing sequential C++ 
HPC benchmark applications using four targets:
**OpenMP**, **MPI**, **CUDA**, and **hybrid** (MPI+OpenMP+CUDA).
Each combination can be repeated a number of times (default 5) to quantify variance.

Results are validated in a five-stage pipeline — semantic inspection, compilation, execution,
internal result checking, and external verification — and all valid programs are benchmarked
on a production supercomputer. A final composite score is derived for analysis.

All scripts are written in **Ruby**. The historical paper pipeline targets a Linux HPC
cluster with Slurm; a separate local pipeline supports re-validation and benchmarking
without Slurm.

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        experiment.rb                                │
│   Invokes LLM agents (GitHub Copilot CLI) for each                  │
│   (benchmark × model × parallelization type × run) combination      │
|   Prepares isolated working directories, and prompts agents as      |
|   a separate, limited user (needs to be set up a-priori)            │
└──────────────────────────────┬──────────────────────────────────────┘
                               │  LLM-generated code & metainformation
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│            validation.rb  /  validation_orchestration.rb            │
│   For each generated program:                                       │
│     1. Check for parallelization constructs (semantic inspection)   │
│     2. Build (cmake + compile)                                      │
│     3. Run with validation parameters                               │
│     4. Internal result validation                                   │
│     5. Compare output against sequential reference                  │
│   Orchestration handles Slurm allocation and timeouts               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │  validated binaries
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│           benchmark.rb  /  benchmark_orchestration.rb               │
│   Runs performance benchmarks (5 repetitions) on validated          │
│   binaries with production-sized inputs on the HPC cluster          │
│   Orchestration manages Slurm allocations per parallelization type  │
└──────────────────────────────┬──────────────────────────────────────┘
                               │  timing results
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     aggregate_evaluation.rb                         │
│   Aggregates data from experiments, validation, and benchmarking    │
│   into a single dataset (YAML) for analysis                         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │  aggregate dataset
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          scoring.rb                                 │
│   Computes final composite scores per run from validation status    │
│   and benchmark performance (relative to scoring thresholds),       │
│   outputs scored CSV for plotting and analysis                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Script Descriptions

### Reusable generation preflight

For a production-budget preflight, put one or more exact run IDs in a text file,
one per line, and use the same batch timestamp for preflight and continuation:

```bash
ruby experiment.rb --production --run --continue=TIMESTAMP --run-ids=/path/to/preflight-ids.txt
ruby experiment.rb --production --run --continue=TIMESTAMP
```

Selection preserves the configured execution order, prompts and per-run budget.
Unknown, duplicate or empty selections fail before generation. Completed IDs retain
their outputs and are skipped on continuation. Do not use `--smoke` for a reusable
production preflight: it uses a shorter timeout. Freeze the launch scripts and
source revision, and set `LLM_EVAL_CLAUDE_BINARY` or `LLM_EVAL_CODEX_BINARY` to a
versioned executable when pinning the CLI. Keep persistent campaign records under home, temporary work
on local storage, and the `llmtest` account free of unrelated sessions during runs.

`tools/generation_campaign.rb preflight|gate|run|status CAMPAIGN_ROOT` provides serial
supervision for a frozen Claude Code, Codex or OpenCode campaign. Its persistent `campaign.json` and
`run-ids.txt` identify the pinned harness, executable, model, budget, paths and
complete ordered selection. `preflight` runs the selected production observations;
Codex campaigns require one per model/effort profile. `gate` accepts those observations based
only on harness metadata, not on the generated program's correctness. `run`
reuses completed observations and invokes the frozen `runtime_root/run.rb` for
one pending ID at a time. It checks harness identity, effort, applicable capability
metadata and completion records between runs. Codex exact token accounting is
recovered from session rollouts at the preflight gate and after the full campaign,
with the account idle, never during agent performance tuning. Compact usage records
bind the counters to each transcript and session hash. An anomaly or a `STOP` file in
the campaign directory stops further launches; it does not regenerate completed
work. Genuine full-budget timeouts are retained as observations.

For Claude Code, an identical same-session initialization repeated after a background-task
notification is accepted only when the follow-up result identifies that origin
and its token/API counters remain cumulative. The final cumulative totals are
counted once. Changed identities/capabilities or unexplained reinitialization
still stop the campaign; original transcripts are never rewritten.

New Claude Code, Codex and OpenCode observations run inside a mount allowlist: only
the current workspace, fresh private home/scratch, read-only system tools and
the pinned harness executable are visible. CPU/GPU and network access remain
unchanged. The trusted outer driver verifies isolation before inference; there
is no unrestricted fallback. Claude retains a compact `claude-filesystem.txt`
receipt, excludes setup and credential synchronization from task time, and
preserves refreshed subscription credentials outside the published outputs.
`tools/check_claude_filesystem.rb PINNED_EXECUTABLE` checks CLI startup, visibility,
MPI/OpenMP, CUDA and cleanup as `llmtest`, without a model request. A frozen
campaign needs an explicit recorded launcher amendment before using this policy.

Codex retains an analogous `codex-filesystem.txt` receipt. Its private configuration
keeps the established model, effort and disabled web-search settings without prior
project history. Fresh session rollouts are archived after the observation exits,
then bound by hash to the deferred exact-token recovery; previous sessions remain
inaccessible to the agent. Subscription credential refresh and session collection
are outside task time. `tools/check_codex_filesystem.rb PINNED_EXECUTABLE` checks
the same CLI, visibility, MPI/OpenMP, CUDA and cleanup properties without inference.
The Terra 6.1 profile is `gpt-6.1-terra-medium`, explicitly selecting
`gpt-6.1-terra` with `medium` effort and the unchanged production task budget.

After each harness invocation, the supervisor verifies that the reserved evaluation
account has no processes left. Any survivors are sent SIGKILL as that account,
with at most two seconds of polling for their disappearance. An already-empty
account incurs no wait. Persistent processes (including zombies) stop the campaign
with PID/state diagnostics. This cleanup runs outside generation timing and is
recorded under `cleanup/`; the pre-launch idle check never kills unrelated sessions.

The supervisor writes progress and per-observation records under the campaign
directory. `status` records the generation service's state and can be scheduled
about every four hours. After generation it commits only the new batch in the
generated-source repository, subject to its ignore rules; pre-existing staged
work, nested repositories or missing metadata require operator review. Validation
and benchmarking are separate subsequent stages. Freeze and retain the supervisor
alongside the launch scripts before unattended use.

### OpenCode harness comparison

OpenCode uses its stock build-agent prompt and model-specific adapters, with the
same task prompt and four-hour budget as the native harnesses. Local shell,
read/edit, build and performance-testing capabilities remain available. Web tools,
subagents, interactive questions, MCP, external plugins and inherited instructions
or skills are disabled; bundled skills remain available. Fresh XDG directories
isolate each observation. Updates and model-catalog refreshes are disabled.

The pinned executable and supported subscription login are installed separately
under the evaluation account, without replacing its existing OpenCode setup.
The OpenAI subscription models are `openai/gpt-6.1-sol` and `openai/gpt-6-luna`, both at medium.
Anthropic authentication/billing setup remains deferred by the operator; these
OpenAI campaigns enable no API keys, paid-credit fallbacks, impersonation plugins or
substitution of Claude Code's agent loop. OpenAI documents
[OpenCode subscription sign-in](https://learn.chatgpt.com/docs/sign-in-with-chatgpt).

`tools/prepare_opencode_campaign.rb` freezes committed method sources, the existing
sequential baseline, the executable and the full ordered selection into a local
runtime with persistent provenance under home. It verifies that Fable remains
fully suspended. The predeclared production pilot covers black-scholes/OMP,
nbody/CUDA, floydwarshall/MPI and qtclustering/hybrid, repetition 1. Accept it using
the normal campaign controller, review the infrastructure evidence, then start
`run` with the same campaign: all four observations are reused, independent of
program correctness. Select `--profile=gpt-6-luna-oc-medium` for Luna 6, or
`--profile=gpt-6.1-sol-oc-medium` (the default) for Sol 6.1. Native profiles are
not renamed or regenerated; the selected native comparison is recorded in the
campaign manifest.

OpenCode Go uses a separate, private subscription credential and requires operator
confirmation that **Use balance is off**, with no paid-credit fallback. Its profiles
are `deepseek-v4.1-flash-oc-high` (the middle supported effort; no medium is exposed),
`minimax-m3.1-flash-oc-medium` (the free alias only),
`claude-haiku-5.5-oc-medium`, and `beam-1.0-oc-medium` (the free alias only). Prepare one with
`--profile=PROFILE --go-balance-fallback-disabled`. MiniMax and Beam catalog entries
are frozen in `lib/opencode_models/`; the stock executable, prompts and adapters are
unchanged. Go's native edit/write tools serve the same local editing capability as
the OpenAI adapter's apply-patch tool.

Haiku uses the stock Anthropic adapter's adaptive-thinking `effort` option;
the other Go profiles use their stock OpenAI-compatible `reasoningEffort` option.
The requested and resolved settings are checked before inference and again in
the retained observation. Haiku's native comparison is batch `20261012-111947`,
profile `claude-haiku-5.5-cc-medium`. The provider route changes along with the
harness, so this is not an isolated causal estimate of the harness alone.

Go requests use each model's advertised per-response output allowance (including
reasoning), set through the stock `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` option.
The frozen policy, effective environment flag and resolved model limit are retained
and cross-checked before inference. Stock context reservation/compaction accounts
for that allowance; the four-hour task budget is unchanged. Historical observations
retain their original settings. Operator-approved replacements are limited to
affected observations, with superseded sources, transcripts and metadata retained
separately. Exhausting the advertised allowance is a retained generation outcome,
not grounds for an automatic retry.

`tools/opencode_campaign_queue.rb run QUEUE_ROOT` accepts a `queue.json` listing
an approved pair of prepared campaign paths in `campaigns`: DeepSeek then MiniMax,
or Haiku then Beam, plus a passing
`regression-tests.log` in each campaign. It checks the four reusable pilots before
continuing each campaign. Read-only Go admission checks run between observations,
outside task timing: paid generation pauses at 95% of any quota window. The queue
switches to the selected free campaign at that boundary, then resumes unfinished
subscription-quota work. Completed observations and production pilots are reused.
The free alias must still be available; no paid replacement is selected. A `STOP`
file in the queue or campaign prevents the next observation without interrupting
an active one. `status` records progress and optional `generation_unit` health;
a monitor timer records status but does not itself notify an assistant. Generation
is serial. Queue order covers generation only; an operator-requested full
evaluation and publication takes precedence over starting the next campaign.

`tools/launch_opencode_queue.rb PAID_CAMPAIGN FREE_CAMPAIGN SETUP_DIRECTORY`
records and launches an approved pair after checking its frozen method, passing
regressions, no-inference isolation/hardware checks and suspended Fable state.
The setup directory contains `setup-check.json` and `regression-tests.log`.
The queue holds the shared native-performance lock for its lifetime. The launched
four-hour timer records progress; it does not notify an assistant by itself.

The stock `serve` and `run --attach` commands use a fresh authenticated loopback
server for each observation. A read-only subscriber retains native retry-status
events omitted by the CLI's JSON output. Explicit session titles prevent helper
title-model calls; compaction uses the selected model and effort. Native event
and session `step-finish` counters must agree and are summed once per request,
including compaction. The CLI transcript is cross-checked too; its final accounting
event can be absent, but both native records must retain it. Input includes cached tokens and
output includes reasoning tokens. Recorded scheduled retry waits are subtracted
from elapsed time; API-only time is left unavailable, not inferred from turns
that also contain local tool work. Setup inspection and final metadata export
are outside task timing; server and CLI startup are inside it.

Each output retains its source, `output.txt`, normal instruction/process/timing
records, and four compact `opencode-*.txt` metadata files. Native message headers,
accounting parts and lifecycle events are retained without repeating tool output
and reasoning text already in the transcript. Databases, dependencies, binaries
and credentials are excluded. Configuration and accounting anomalies stop further
launches without repeating accepted observations.

An explicitly adjudicated model-caused termination retains the original source,
transcript, timing and failed exit status; it receives no fresh attempt. A
hash-bound `generation-termination.txt` records that decision and any recovered
native metadata. The source still undergoes normal validation. Incomplete token
counters are retained separately as a lower bound, not a complete cost measure.

Comparisons reuse historical native-harness baselines with the same sequential
input and budget. Provider model aliases are not immutable snapshots, and
OpenCode's model-specific prompts and adapters are part of the tested harness;
these are not contemporaneous, model-only causal comparisons.

### Main Pipeline (in execution order)

| Script | Description |
|--------|-------------|
| **experiment.rb** | Main entry point. Defines the benchmark suite, models, and parallelization types. Iterates over all configurations, preparing isolated working directories and invoking the LLM agent (GitHub Copilot CLI) with a parallelization prompt for each. Supports dry-run, production, and continuation modes. |
| **validation.rb** | Validates each LLM-generated program through five stages: (1) textual detection of parallelization constructs, (2) cmake configure + build, (3) execution with validation-sized inputs, (4) internal result checking, and (5) comparison of outputs against a sequential reference. |
| **validation_orchestration.rb** | Wraps `validation.rb` in a Slurm-managed loop, re-submitting jobs when the validation script hits time limits, until all validations are complete. |
| **benchmark.rb** | Runs performance benchmarks on all validated binaries. Executes each benchmark 5 times with production-sized inputs and per-parallelization-type Slurm configurations. Collects timing and throughput data. |
| **benchmark_orchestration.rb** | Manages Slurm allocations (varying by parallelization type: different node/GPU/CPU configurations for OMP, CUDA, MPI, hybrid) and invokes `benchmark.rb` with the appropriate job ID. |
| **aggregate_evaluation.rb** | Collects data from experiment outputs (token usage, timings, code changes), validation results, and benchmark results into a unified YAML dataset per run. |
| **scoring.rb** | Takes the aggregated dataset and a scoring matrix (with "top"/"great"/"good" thresholds per benchmark and parallelization type) to compute a final composite score (0–10) combining validation status and relative performance. Outputs scored CSV for analysis. |

### Support Scripts

| Script | Description |
|--------|-------------|
| **general.rb** | Shared constants, helper functions (ID string parsing, build helpers, run-with-timeout utilities), and common require statements used across all scripts. |
| **general_evaluation.rb** | Defines the `AggregateEvaluation` data class holding all per-run metrics (tokens, times, code changes, validation status, benchmark results, final score). |
| **validation_class.rb** | Defines the `ValidationResult` class tracking per-stage pass/fail status for each validation run.  |
| **validation_helper.rb** | Parallelization detection (textual analysis of source for OpenMP/CUDA/MPI constructs) and output comparison logic for validating results against references. |
| **check_generated_dependencies.rb** | Scans generated CMakeLists.txt files for non-whitelisted dependencies (e.g. unexpected libraries beyond standard OpenMP/MPI/CUDA). |
| **find_binaries.rb** | Locates validated binaries in the validation output directory, filtering by benchmark and parallelization type. |
| **gather_bench_results.rb** | Parses benchmark output logs to extract timing/throughput metrics using per-benchmark regex patterns. |
| **benchmark_analysis.rb** | Helper to compute total lines of code (TLOC) for each benchmark for paper tables. |
| **reset_server_error_runs.rb** | Identifies and resets runs that failed due to transient LLM API server errors, moving them to a `failed/` directory so `experiment.rb` can re-run them on its next invocation. |

## Related Data Repositories

The following repositories contain the data generated when this experiment was enacted.
They are published alongside this scripts repository for full reproducibility:

| Repository | Contents |
|------------|----------|
| [llm-eval-generated](https://github.com/PeterTh/llm-eval-generated) | Raw LLM agent output for each run (generated code, logs, token usage) |
| [llm-eval-validation](https://github.com/PeterTh/llm-eval-validation) | Validation pipeline outputs (build logs, run outputs, reference comparisons) |
| [llm-eval-bench-results](https://github.com/PeterTh/llm-eval-bench-results) | Benchmark performance results (timings, aggregate data, scoring) |

## Requirements

- **Ruby** (tested with Ruby 3.x)
- **Linux HPC cluster** with Slurm workload manager
- **GitHub Copilot CLI** (`copilot` command) with access to the evaluated models
- **CMake**, C++ compiler with OpenMP support, MPI implementation, CUDA toolkit
- The [benchmark suite](https://github.com/PeterTh/llm-eval-benchmarks) (expected at `../benchmarks` relative to experiment scripts)

## Local validation and benchmarking

`local_evaluation.rb` provides a resumable pipeline which leaves both the historical
Slurm scripts and generated source repositories unchanged. A local run combines all
timestamped batches below an experiment root and records their provenance in an
immutable manifest. Generated projects are copied into read-only source snapshots and
built out of source inside the evaluation directory; a malformed or brittle generated
project can fail its own validation without changing its source batch.

Use a high-capacity local filesystem for a production run directory. A complete run
contains thousands of independent source snapshots, builds, and logs, so a small `/tmp`
filesystem is appropriate for canaries but not for the full corpus. The pipeline checks
for at least 10 GiB of free space before execution, but that guard is only an emergency
floor, not a capacity estimate.

```bash
RUN_DIR=~/llm_para_local_evaluation/$(date +%Y%m%d-%H%M%S)

ruby local_evaluation.rb init \
  --experiments-root=~/llm_para_experiments \
  --run-dir="$RUN_DIR"
ruby local_evaluation.rb preflight --run-dir="$RUN_DIR"
ruby local_evaluation.rb validate --run-dir="$RUN_DIR"
ruby local_evaluation.rb calibrate --run-dir="$RUN_DIR"
```

`preflight` verifies the exact CPU/NUMA/GPU topology, compiler and launcher tools,
user-systemd containment, all eight validation/benchmark launcher profiles, and free
disk space. Validation and benchmarking repeat their launcher preflight and save a
phase-local report. `status` shows the recorded preflights, validation stages and
pending count, calibration cell statuses, benchmark artifact/configuration consistency,
and aggregate completeness.

Calibration checkpoints `benchmark_config.proposed.yaml` after every cell and resumes
without repeating resolved cells. `--retry-failed` explicitly retries unresolved cells.
It considers both benchmark-reported compute time and external wall time. A
`wall_limited` cell is intentional: the reported compute region may remain much shorter
than one second when startup or input costs already put the pilot wall time in the
accepted 2–8 second window. This prevents calibration from making end-to-end runs
unmanageably long merely to enlarge a narrowly measured kernel.

Review all 44 benchmark/backend cells. For a manually accepted `review_required` cell,
set `status: reviewed` and `resolved: true` after checking its arguments, observed
times, and timeout. Freezing is refused until validation is complete and every cell is
resolved, within its safe input caps, and has a 30–120 second timeout:

```bash
ruby local_evaluation.rb freeze-config --run-dir="$RUN_DIR"
ruby local_evaluation.rb benchmark --run-dir="$RUN_DIR"
ruby local_evaluation.rb aggregate --run-dir="$RUN_DIR"
ruby local_evaluation.rb prepare-scoring --run-dir="$RUN_DIR"
```

The frozen `benchmark_config.yaml` and its `.sha256` sidecar are read-only. Every
benchmark invocation and per-ID result records that digest, and benchmarking refuses to
mix results from another configuration or continue after the file changes.

Reported benchmark times must be finite and strictly positive. Zero-valued timings are
treated as generated-program measurement failures during calibration and benchmarking,
and are rejected again by resume reconciliation, aggregation, status, and scoring so a
broken timer cannot receive the fastest-result score.

A post-run pipeline correction does not require repeating unrelated results. For a
localized defect, create one immutable amendment tied to the original manifest, the
old and corrected pipeline snapshots, and the exact affected run ID:

```bash
ruby local_evaluation.rb amend-pipeline \
  --run-dir="$RUN_DIR" \
  --id=EXACT_RUN_ID \
  --reason="Why this record, and only this record, must be rerun" \
  --dry-run
# Repeat without --dry-run after reviewing the complete source-digest diff.
ruby local_evaluation.rb benchmark --run-dir="$RUN_DIR" \
  --id=EXACT_RUN_ID --retry-failed
ruby local_evaluation.rb aggregate --run-dir="$RUN_DIR"
```

The amendment authorizes only the named benchmark record and then unfiltered
aggregation/scoring. It cannot authorize validation, calibration, a filtered
downstream rebuild, or another benchmark ID. Prior artifacts are archived by the
normal retry path, and the repaired record and aggregate freshness metadata bind the
amendment digest. Reserve a full-corpus rerun for a systemic issue that affects the
whole corpus.

`prepare-scoring` writes sorted local timing distributions and an intentionally
incomplete threshold template. After choosing the `top`, `great`, and `good` group
boundaries from the complete distributions, set `reviewed` to `true` for every row
and score the dataset:

```bash
ruby local_evaluation.rb score \
  --run-dir="$RUN_DIR" \
  --thresholds="$RUN_DIR/local_scoring_thresholds.csv"
```

Canonical scoring files are only written for an unfiltered full-corpus operation.
Filtered `prepare-scoring` and `score` commands instead use names containing
`.selection-<digest>` so a diagnostic subset cannot overwrite full distributions,
threshold templates, or scores.

The per-run `validate`, `calibrate`, `benchmark`, `aggregate`, `prepare-scoring`, and
`score` phases support `--id=RUN_ID`, `--filter=TEXT`, and `--dry-run`; `init`,
`preflight`, and `freeze-config` also provide dry-run inspection. Validation,
calibration, and benchmarking additionally support `--retry-failed`. Use
`ruby local_evaluation.rb status --run-dir="$RUN_DIR"` at any time to inspect progress.
Completed per-ID results and calibration cells are committed atomically, so an
interrupted command can be run again without repeating completed work. Reproducible
generated-program failures are recorded as complete failures; infrastructure failures
leave work pending for a later resume.

Local performance runs are serialized and pinned to the configured physical CPU/GPU
resources. The operator remains responsible for keeping unrelated system load away
from the machine while measurements are in progress; the pipeline deliberately does not
reject a run based on ambient CPU or GPU load.

Generated configure, build, validation, calibration, and benchmark processes run in
transient user-systemd scopes. The runner applies aggregate memory limits of 32 GiB for
builds, 64 GiB for validation, and 256 GiB for calibration/benchmarks; PID limits are
256, 256, and 512 respectively. It also enforces process-tree wall timeouts, disables
core dumps, caps each stdout and stderr log at 8 MiB while continuing to drain output,
and limits a generated file to 1 GiB during builds or 64 MiB during program execution.
Timeout cleanup terminates both the process group and the complete cgroup, including MPI
children. If user-systemd scopes are unavailable, execution of generated code is refused.
`LOCAL_EVALUATION_ALLOW_UNCONTAINED=1` is the explicit emergency opt-out; use it only
after reviewing the risk because aggregate memory/PID containment is then unavailable.

## Timing audit and corrections

Generation metadata from Claude Code uses the last result's cumulative `modelUsage`
counters when available. A later background-task notification can have a per-turn
`usage` value, so using that value would undercount the session's tokens. Total input
includes uncached, cache-read, and cache-creation tokens; cached tokens remain a subset.

Haiku 5.5's context tiers apply to each request's input, including cache reads and
writes, not the cumulative session input. `tools/metadata/recover_claude_context_usage.rb`
recovers compact tier evidence from original Git-pinned transcripts and generation
observations. It verifies request input and cache-lifetime counters against the
native totals. Streamed output counters are incomplete; single-tier sessions use
the native final output total, while mixed-tier output totals are explicitly labeled
as derived from that total and the harness's reported list-price total. Integer,
range and pricing checks must all pass. The comparison retains the existing Claude
convention of pricing cache creation as ordinary input. Original counters remain
unchanged. See the [documented Haiku pricing and threshold](https://platform.claude.com/docs/en/models/haiku-5-5/overview).

For completed Claude sessions, aggregation subtracts the sum of recorded
`system/api_retry.retry_delay_ms` waits from both generation `total_time` and
`api_time`, excluding server retry backoff from the analysis. Original values are
retained as `raw_total_time` and `raw_api_time`, together with `agent_retry_count`
and `agent_retry_backoff_seconds`, in aggregate/scored YAML and CSV. Only explicitly
recorded waits are subtracted; unrecorded failed-request latency is not estimated.
The original transcripts and `timing.txt` remain the evidence, so repeated aggregation
does not subtract the adjustment again. These fields concern generation time, not
the execution times measured by benchmarking the generated programs.

The static timing audit, timing-only correction, independent-review, adjudication,
scoped-rerun, and final scoring utilities are maintained under
[`tools/timing_audit`](tools/timing_audit). Run-specific decisions and ID lists do not
belong in this repository. The exact method snapshot and compact evidence used for the
published local release are retained in
[`llm-eval-local`](https://github.com/PeterTh/llm-eval-local/tree/local-eval-2026-08-25/method/timing-audit).

Temporary agent/build workspaces must use node-local storage such as `/tmp`, not NFS.
Persistent audit and benchmark results belong in a dedicated directory under the
operator's home directory and are exported to the artifact repository only after
curation.

Run the complete unit test suite with:

```bash
ruby -Itest -e 'Dir["test/test_*.rb"].sort.each { |file| require_relative file }'
```

## License

This code is provided for research reproducibility. See the associated paper for citation information.
