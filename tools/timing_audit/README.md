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
Both adjudication preparation commands accept `--model=MODEL` to retain the chosen
reviewer identity; pass that same model to the audit runner's `--model` option.
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

## QT-clustering measurement-boundary review

`bin/qtclustering_boundary.rb prepare` prepares a separate, all-backend audit of
every validation-passing QT-clustering implementation in `release/catalog.json`
and additional completed `--validation-run` directories. Benchmark success and
performance do not filter this review. It verifies the selected current source
trees against each evaluated original/corrected Git revision. Use a clean sparse
checkout on `/tmp`; persistent evidence belongs under home.

For a new batch whose historical counterparts have already been reviewed, add
`--validation-only` with one or more `--validation-run` arguments. Only those
validation runs supply candidate programs. The required `--release-root` still
supplies frozen configuration context, so inherited sizes remain checked against
the published campaigns without reviewing their programs again.

The frozen prompt includes the pinned sequential reference, inherited sizes,
and platform evidence. Input generation and allocation may remain outside timing;
input-dependent algorithmic preprocessing (distances, neighbors, candidate caches,
spatial indexes) must be included. The same contract applies to OpenMP, CUDA,
MPI and hybrid. Review workers cannot compile or execute code.

Run the ordinary audit runner with Luna/high and `--scope=trial --jobs=4`, then
`qtclustering_boundary.rb review --main=PATH --review=PATH --scope=trial --jobs=4`
for a blind Sol-6.1/xhigh check of the same pilot. `pilot-gate --main=PATH
--review=PATH` retains the quality check; inspect any failed gate before expanding.
Run the primary full inventory with 16 workers after the gate passes. The `review`
command with `--scope=full` selects every flagged or uncertain result and MPI
makespan controls, reusing the pilot adjudications. Prior verdicts are not sent
to Sol. `finalize --main=PATH --review=PATH` verifies source-only evidence, reviewer
identity and immutable artifacts and retains unresolved uncertainty explicitly.
Only difficult unresolved cases require Astra/human review. Earlier audit campaigns
are not overwritten; the new decisions must be reconciled before timing-only
corrections and affected-ID remeasurement. No blanket benchmark rerun is implied.

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
Its `prepare --scope=trial` prepares only the compiled pilot, so the pilot can
receive independent review before expanding proposals to the full set. The
default preparation scope remains `full`; both scopes bind their own compiled
patch and summary. CUDA-only and hybrid corrections use the same pinned CUDA
compiler and architecture during compile checks.
If compilation or review rejects a proposal, `bin/timing_fix_revision.rb` accepts
a JSON array of `program_id`, `prior_proposal_sha256`, and `feedback` records. It
revises only those proposals with a static worker, keeps the old responses and
feedback under `revisions/`, and requires compilation and independent review of
the new exact source. It never changes the frozen original proposal runner.
`bin/timing_fix_adjudication.rb` selects non-accepting and uncertain reviews without
requiring IDs from the historical release. An empty adjudication set is valid.

New correction campaigns bind source-only event evidence to every accepted response
and preserve earlier attempts on resume. Agents do not execute or compile programs;
the main workflow separately compiles and revalidates only affected programs.
Stage final corrections as one generated-source commit and preserve the original
commit. `bin/timing_fix_finalize.rb` emits the existing correction-registry schema,
including `timing_fixed`, source hashes and original/corrected GitHub URLs.

Revalidation uses the existing scientific validator, including its numeric tolerances
and output-contract checks. Result `Hash:` equality is not required where that
validator ignores it. Do not pause, retry, exclude, or repair a program solely for
such a hash difference. Original/corrected output comparisons may be retained as
descriptive evidence, but byte-for-byte equality is not an extra validation gate.
This does not relax source/artifact integrity hashes or any native validation check.

To reconcile a later focused audit before making that single correction commit,
`timing_fix.rb prepare --audit=BASE --overlay=FOCUSED --source-root=CLEAN_CHECKOUT`
accepts later decisions only at the same pinned Git commit and with identical source
digests/tree IDs for overlapping programs. A later valid decision removes an earlier
correction candidate; a later invalid decision supplies the operative findings.
All parent decision/manifest hashes and the review evidence origins are retained.
The optional clean checkout must contain the combined reviewed source set; use local
scratch, not a mutable user worktree. This does not rerun or overwrite earlier audits.
`bin/timing_fix_review_reuse.rb --source=PILOT --destination=FULL` reuses independent
pilot reviews only when source/proposal metadata, literal prompts, methods and model
identities match, retaining a hash-bound copy index and original attempt evidence.

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

If revalidation exposes a pre-existing correctness or output-contract defect, preserve the original
pass and failed revalidation as separate observations. After explicit user
resolution, `prepare --validation-failures=PATH` can accept a hash-bound JSON
disposition covering **exactly** the failed corrected programs. The records name
the source commits, revalidation manifest, failed stage, unchanged-defect reason,
user decision, static review and validation metadata/stdout hashes. These programs
are counted as validation failures and excluded from all benchmark partitions;
they are not benchmark failures, retried until passing, or algorithmically repaired.
Use `pre_existing_output_contract_failure` for uncoordinated MPI output that fails
the unchanged validator, distinct from `pre_existing_correctness_failure` for a
numerical/algorithmic defect. This classification does not relax the parser or
authorize output repairs or reclassification of other failed implementations.
Missing/unexpected dispositions and changed evidence block preparation/resume.
The immutable campaign retains the dispositions and exclusion IDs. Final aggregate
and release exports must overlay these failed corrected validations onto original
validation counts while retaining both observations; an earlier pass must never
restore eligibility. The raw validation files and measurement procedure are unchanged.

A combined correction commit may include programs outside a particular batch.
The campaign retains the complete correction registry and compiled/revalidated
coverage, while `SourceCorrectionAmendment`'s explicit `scope: "manifest"` mode
authorizes only the intersection with that run's IDs. Every original/corrected
source tree and the full commit's changed-path set must match the registry;
unreviewed changes are still rejected. Existing exact-scope behavior is the default.
For a new scoped evaluation initialized at the corrected commit, the explicit
`revision_mode: "already_corrected"` mode attaches the same correction provenance
after revalidation, without pretending the run was initialized at the original
commit. Both modes retain original/corrected source links and require explicit
corrected-ID benchmark selection. These are provenance/selection extensions;
benchmark measurement code, resources, arguments and repetitions are unchanged.

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
For each backend, preparation selects the lowest-numbered unchanged, validation-passing
Black–Scholes repetition of the requested canary model. This retains repetition 1
when eligible and allows a later repetition when earlier ones need timing corrections;
the exact four IDs are frozen in the campaign before any measurement.
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
