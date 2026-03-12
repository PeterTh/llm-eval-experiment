# LLM Parallelization Evaluation — Experiment Scripts

This repository contains the experiment, validation, benchmarking, and scoring scripts for the paper:

> **Evaluating the Parallelization Capabilities of State-of-the-art Agentic Large Language Models**  
> Peter Thoman and Philipp Gschwandtner, University of Innsbruck  
> *currently under review*

## Overview

This infrastructure allows tasking state-of-the-art LLM agents 
(accessed through a common agentic interface) with parallelizing sequential C++ 
HPC benchmark applications using four targets:
**OpenMP**, **MPI**, **CUDA**, and **hybrid** (MPI+OpenMP+CUDA).
Each combination can be repeated a number of times (default 5) to quantify variance.

Results are validated in a five-stage pipeline — semantic inspection, compilation, execution,
internal result checking, and external verification — and all valid programs are benchmarked
on a production supercomputer. A final composite score is derived for analysis.

All scripts are written in **Ruby** and designed to run on a Linux HPC cluster with Slurm.

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        experiment.rb                                │
│   Invokes LLM agents (GitHub Copilot CLI) for each                  │
│   (benchmark × model × parallelization type × run) combination      │
└──────────────────────────────┬──────────────────────────────────────┘
                               │  LLM-generated code
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

## License

This code is provided for research reproducibility. See the associated paper for citation information.
