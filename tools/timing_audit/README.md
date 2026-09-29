# Timing audit and correction tools

This directory contains the maintained source for the static MPI/hybrid timing audit,
timing-only corrections, independent review and adjudication, scoped remeasurement,
and final scoring checks used by the local evaluation.

The command-line entry points are under `bin/`; implementation code, agent prompts,
and structured-output schemas are under `lib/`, `prompts/`, and `schemas/`. Run entry
points from the repository root, for example:

```bash
ruby tools/timing_audit/bin/timing_audit.rb
ruby tools/timing_audit/bin/timing_fix.rb
ruby tools/timing_audit/bin/timing_fix_review.rb
ruby tools/timing_audit/bin/timing_fix_adjudication.rb
```

Store temporary agent and build workspaces on node-local storage such as `/tmp`, not
on NFS. Store persistent audit decisions and results in a dedicated directory under
the operator's home directory, outside this repository. Do not commit generated
program copies, agent transcripts, build products, or run directories here.

## Validation-first batches

A newly committed experiment batch can be audited before benchmarking. Validate an
isolated, clean checkout of that batch with `local_evaluation.rb` first; a sparse Git
checkout on local scratch avoids including unrelated batches or uncommitted files.
The existing validation pipeline and pass/fail criteria are unchanged.

```bash
ruby tools/timing_audit/bin/timing_audit.rb prepare \
  --validation-run=/path/to/completed-local-validation \
  --source-root=/path/to/pinned-generated-repository \
  --output=/path/to/new-audit
ruby tools/timing_audit/bin/timing_audit.rb run --output=/path/to/new-audit --scope=trial --jobs=4
# Review the pilot's source-grounded findings before expanding:
ruby tools/timing_audit/bin/timing_audit.rb run --output=/path/to/new-audit --scope=full --jobs=16
```

Preparation requires one consistent, completed validation result per manifest ID.
It selects only MPI/hybrid programs passing all five stages, retains exclusions,
and leaves benchmark timings, scores, and benchmark configuration hashes null.
Infrastructure failures must be resolved, not silently excluded. The older
`--release-root` mode still selects successful, scored benchmark measurements.

Independent review of a validation-first batch includes every invalid, ambiguous,
non-high-confidence, and valid-without-explicit-`MPI_MAX` result. Prepare/run/compare
with `bin/timing_priority_review.rb`; its `prepare-adjudication --main=PATH
--review=PATH --output=PATH` command selects verdict/category disagreements,
fixability disagreements, and remaining uncertainty for blind `gpt-5.6-sol`/`xhigh`
review via the ordinary audit runner. No earlier verdict is sent to the reviewer.
Finalization retains ambiguity rather than requiring a forced binary verdict.
Validation-first independent reviews and adjudications explicitly trace whether a
root-issued scatter or first pivot broadcast gates all useful computation. This
guards against mistaking a proven root-clock global makespan for an invalid local
timer merely because it lacks `MPI_MAX`. Review guidance is frozen with its prompt.
`prepare-adjudication --context=PATH` can additionally freeze independently verified
static platform facts (for example a compile-only ABI proof and recorded MPI rank
profiles), without supplying prior verdicts. Unknown problem-size conditions remain
explicit; validation sizes are not silently assumed to be benchmark sizes.
If final source inspection exposes an overlooked platform assumption in an agreed
verdict, `prepare-supplemental --main=PATH --output=PATH --selection=PATH
--context=PATH` freezes a separate blind review. The selection is JSONL with
`program_id` and `reason` fields; these reasons and previous verdicts are not sent
to the reviewer. Run the derived inventory with Sol/xhigh, then pass
`--supplemental=PATH` to the finalizer and exporter. All earlier evidence remains
intact, and the final decision records the supplemental selection and verdict.

Workers receive only the source dossier. Successful attempts are checked for
prohibited tool events, and their source, response, event stream, usage, and method
provenance are retained. Retry attempts receive new directories instead of
overwriting earlier evidence.
The worker CLI explicitly disables shell execution, web search, hooks, and external
integrations in addition to the read-only sandbox and source-only instructions.

`bin/export_validation_audit.rb --run-dir=PATH --output=PATH` exports compact
validation-only evidence to a new supplementary batch directory in the artifact
repository, without replacing the canonical release. After auditing, add
`--primary=PATH --priority=PATH --adjudication=PATH` to retain decisions and review
provenance. Builds, generated sources, and repeated raw agent streams are omitted;
failure logs, commands, method snapshots, and checksums are retained. Refresh the
artifact repository's global checksums after exporting.

## Correcting a validation-first batch

Use `bin/timing_fix.rb prepare --audit=PATH --output=PATH [--context=PATH]`
to select only confirmed-invalid final decisions; null performance scores are
supported and conditional cases are not selected. Run a proposal pilot before
expanding, compile with `bin/timing_fix_materialize.rb` on local scratch, then
prepare independent corrected-source review with `bin/timing_fix_review.rb`.
`bin/timing_fix_adjudication.rb` selects non-accepting and uncertain reviews without
requiring IDs from the historical release. An empty adjudication set is valid.

New correction campaigns bind source-only event evidence to every accepted response
and preserve earlier attempts on resume. Agents do not execute or compile programs;
the main workflow separately compiles and revalidates only affected programs.
Stage final corrections as one generated-source commit and preserve the original
commit. `bin/timing_fix_finalize.rb` emits the existing correction-registry schema,
including `timing_fixed`, source hashes and original/corrected GitHub URLs.

`bin/export_timing_corrections.rb --batch-dir=PATH --proposals=PATH --review=PATH
--adjudication=PATH --final=PATH --validation-run=PATH --original-source=PATH`
exports the accepted registry, compact review/compile evidence and affected-program
revalidation to an existing supplementary batch. `--original-source` is a clean
checkout of the original pinned commit, retained to verify exact proposal edits.
Both source links match the current website's correction fields; the batch is not
added to performance views until benchmarking/scoring and publication are requested.
Original validation/audit evidence and unrelated historical measurements are kept.

## Benchmarking a validation-first batch

`bin/benchmark_validation_batch.rb` sequences the unchanged benchmark pipeline for
a completed validation-first batch. `prepare` requires the historical frozen
configuration, accepted timing-correction evidence, completed corrected-program
revalidation, and a clean original-source backup on local scratch. It inherits all
cells, sizes, iterations, timeouts and target settings without recalibration; only
the new manifest/validation/seed-path bindings and inheritance provenance change.
It refuses to overwrite an existing campaign.

```bash
ruby tools/timing_audit/bin/benchmark_validation_batch.rb prepare \
  --run-dir=/path/to/original-validation \
  --baseline-config=/path/to/historical/benchmark_config.yaml \
  --corrections=/path/to/accepted-corrections \
  --corrected-validation=/path/to/completed-corrected-validation \
  --original-backup=/tmp/clean-original-checkout \
  --canary-model=claude-sonnet-5-cc-medium
ruby local_evaluation.rb preflight --run-dir=/path/to/original-validation
ruby local_evaluation.rb benchmark --run-dir=/path/to/original-validation \
  --ids-file=/path/to/original-validation/benchmark-campaign/canary-ids.txt
# Inspect all four canaries before starting/resuming the remaining work:
ruby tools/timing_audit/bin/benchmark_validation_batch.rb run \
  --run-dir=/path/to/original-validation
ruby tools/timing_audit/bin/benchmark_validation_batch.rb status \
  --run-dir=/path/to/original-validation
```

Resolve conditional audit findings against the inherited sizes before launch.
Canaries use the same warm-up and five repetitions and are retained, not repeated.
The runner first benchmarks unchanged valid programs from their validation builds,
then guards those records before advancing the isolated source checkout to the
accepted correction commit. The existing immutable source-correction amendment
authorizes only the affected IDs, which are built on local `/tmp` and benchmarked
with native timing-fixed/source-revision metadata. Only operational checkout paths
are rebound in derived correction evidence; its accepted manifest hash is retained.

The campaign manifest, runner snapshot and ID partitions are frozen. Resume skips
consistent completed records; it does not automatically retry generated-program
failures. Infrastructure issues require diagnosis and only scoped recovery.
Avoid concurrent tests, qualification, compilation or other heavy analysis while
measurements are running. Keep logs/results under home and export compact evidence
after completion; do not replace historical results or silently score a new batch.

`bin/export_benchmark_batch.rb --run-dir=PATH --batch-dir=PATH
--conditional-decisions=PATH` exports only a completed campaign to a new
`benchmark/` subtree of its existing supplementary batch. It verifies every native
record, the unchanged-record guard and inherited settings before writing. The
conditional-decisions JSONL must cover unresolved audit conditions and bind their
source revision, frozen arguments and resource profile. Records use the existing
benchmark schema, including timing-fixed flags and both source links. A compact
evidence index preserves native metadata key order and log hashes; the metadata is
reconstructed byte-for-byte rather than duplicated. Failure logs are retained.
Large correction registries and pipeline sources reference the batch's existing
copies through `reconstruction.json`. Refresh batch/global checksums after updating
the human-readable report and summary.

The exact frozen tool snapshot and compact evidence for the canonical release are in
[`llm-eval-local` at `local-eval-2026-08-25`](https://github.com/PeterTh/llm-eval-local/tree/local-eval-2026-08-25/method/timing-audit).
The release snapshot is intentionally duplicated there so its checksums remain stable;
this repository owns the maintainable source and tests.

Run all tests from the repository root:

```bash
ruby -Itest -e 'Dir["test/test_*.rb"].sort.each { |file| require_relative file }'
```
