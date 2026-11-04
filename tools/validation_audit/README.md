# Retrospective correctness validation

These tools strengthen external validation without changing generated programs,
sequential input programs or performance measurements. A failed supplemental
check changes effective eligibility to the existing failed-external-validation
category. Archived validation and benchmark records remain unchanged.

## Scope and execution

`inventory.rb` selects every observation with external-validation status 5 in
the current release, including subsequent benchmark failures. It resolves the
effective generated-source Git revision, including timing corrections and
observation replacements, and pins every staged source file. An inventory freezes
the release CSV and catalog digests for its campaign.

`runner.rb` reuses a binary only when the complete staged source tree, successful
build receipts and executable digest agree. Otherwise it rebuilds the exact Git
source. Builds and executions stay under a local `/tmp` workspace; compact
results and logs persist in the supplied home-directory evidence folder.
Executions take the native host lock, require the generation account to be idle,
and use the established resource/containment settings. The shape/topology pilot
uses the measured resource allocation, but it performs correctness executions,
not benchmark repetitions or timing extraction.

Failures are checkpointed without retries. A build that cannot reproduce an
earlier successful build stops as an infrastructure issue. Source or case changes
invalidate checkpoint reuse. No program is repaired to turn a failure into a pass.

## Pilot gates

Run each phase's pilot before its full scope. A recorded conservative estimate
below five hours permits that full phase; a higher estimate requires explicit
user approval. The estimate includes preparation and execution costs. Phases run
sequentially, not concurrently with one another or with other experiments.

```sh
ruby tools/validation_audit/campaign.rb LOCAL_WORKSPACE HOME_EVIDENCE floyd pilot
ruby tools/validation_audit/campaign.rb LOCAL_WORKSPACE HOME_EVIDENCE floyd full
ruby tools/validation_audit/campaign.rb LOCAL_WORKSPACE HOME_EVIDENCE stencil pilot
ruby tools/validation_audit/campaign.rb LOCAL_WORKSPACE HOME_EVIDENCE stencil full
ruby tools/validation_audit/shape_topology.rb LOCAL_WORKSPACE HOME_EVIDENCE pilot
```

The shape/topology pilot does not launch a full sweep automatically. The full
driver requires `shape-topology-full-authorization.json`, bound to the frozen
refined plan and pilot digests. It verifies the source inventories, reference
outputs and every cached result before resuming:

```sh
ruby tools/validation_audit/shape_full.rb LOCAL_WORKSPACE HOME_EVIDENCE check
ruby tools/validation_audit/launch_shape_full.rb LOCAL_WORKSPACE HOME_EVIDENCE llm-validation-shape-topology-YYYYMMDD
```

The launcher creates a durable user service and refuses to duplicate an active
one. `shape-topology-full-state.json` is replaceable operational progress;
individual results, failure events, skipped-check reasons and attempt receipts
remain immutable. A known failure is never retried. Later cases for that same
unchanged implementation are skipped with a digest-bound failure reason.
SpMV work-count verification and tolerant full-array observation have separate
pilot gates. The SpMV tool prepares a source/compiled-code inspection sample and
records manual review evidence and an elapsed-review-time projection; it does
not execute programs or automatically certify iteration counts. Its completed
12-program pilot found no omission. The separately authorized full static review
is complete: all 722 eligible implementations are covered, with no new work-count
omission identified. After a checked delegation pilot, up to three Luna reviewers
worked in parallel; four uncertain library/JIT cases received Sol-6.1 adjudication.
Primary review checked every finding and evidence claim, sampled each batch, and
returned incomplete or incorrect evidence for correction. Raw proposals, accepted
inputs and per-ID records are retained separately. This is not proof for all inputs
or a substitute for numerical validation. Tolerant full-array observation has its
own pilot gate and is not yet implemented.

The static-review driver checks source/build/executable bindings and exact compiled
excerpts before sealing completion. It never treats preparation or a progress count
as a scientific verdict, and it refuses duplicate or unresolved reviews:

```sh
ruby tools/validation_audit/spmv_full_review.rb LOCAL_WORKSPACE HOME_EVIDENCE status
ruby tools/validation_audit/spmv_full_review.rb LOCAL_WORKSPACE HOME_EVIDENCE check PROPOSAL_JSON
ruby tools/validation_audit/spmv_full_review.rb LOCAL_WORKSPACE HOME_EVIDENCE record CHECKED_REVIEW_JSON
ruby tools/validation_audit/spmv_full_review.rb LOCAL_WORKSPACE HOME_EVIDENCE verify
ruby tools/validation_audit/spmv_full_review.rb LOCAL_WORKSPACE HOME_EVIDENCE finish
```

`record` requires explicit zero activity counters for new reviews and primary
acceptance metadata for delegated work. Early immutable schema-v1 records omit
the compilation counter; verification reports that missing metadata without
inventing values. Reported agent intervals are not a cost or throughput estimate.

## Full array observation

The full-array tools observe unchanged executables with GDB hardware breakpoints
and read-only memory capture. Arrays remain under the local workspace; comparisons
retain elementwise absolute tolerance `1e-5`, or the existing Roomsim distance
tolerance `5`. A captured array's own printed hash binds the observation to the
output; floating-point hashes are not compared across implementations.

The stratified pilot covered 120 programs across 40 benchmark/backend strata.
The compatibility pilot checked 13 unusual output layouts, four canonical
controls and one reference. `full_array_adapters.rb` pins reviewed vector/span
helpers and five executable-specific sites. Unsupported or incomplete observation
stops for review and is not a scientific exclusion. Identical rank replicas may
be compared once without changing the benchmark output contract.

`full_array_full.rb` freezes the approved scope and method, verifies and reuses
completed comparisons, and saves immutable per-ID evidence. Its systemd launcher
survives disconnection, never auto-restarts failed executions, and updates
`full-array-full/state.json` approximately once a minute. The full sweep uses
the piloted serial scheduling; the shape-only concurrency result does not establish
safe debugger concurrency. `STOP-full-array-full` requests a checkpointed stop.

```sh
ruby tools/validation_audit/full_array_full.rb LOCAL_WORKSPACE HOME_EVIDENCE prepare
ruby tools/validation_audit/launch_full_array.rb LOCAL_WORKSPACE HOME_EVIDENCE llm-validation-full-array-20261104
```

Launching requires an explicit user approval receipt, not merely a completed
pilot. `export_full_array_pilot.rb` retains compact observations, method versions,
source/binary bindings and full numerical witnesses for pilot failures, with no
executables or repeated successful-result arrays. No full-array command invokes
an LLM or records a performance measurement.

To list new full-array failures and mark IDs only after reporting them in chat:

```sh
ruby tools/validation_audit/failure_notifications.rb HOME_EVIDENCE pending-full-array
ruby tools/validation_audit/failure_notifications.rb HOME_EVIDENCE mark-full-array RUN_ID
```

## Shape sweep concurrency

Concurrency changes scheduling only. A separately authorized pilot compares
fresh serial controls with two and four independent copies of the same passing
MPI/OpenMP programs, covering all 22 primary CPU strata. Inputs, source, rank and
thread counts, CPU affinity, memory limits, timeouts and comparisons stay fixed.
The pilot retains every output and samples memory availability, pressure and OOM
counters. It stops expanding concurrency after a failed stage.

```sh
ruby tools/validation_audit/concurrency_pilot.rb LOCAL_WORKSPACE HOME_EVIDENCE
ruby tools/validation_audit/concurrency_policy.rb HOME_EVIDENCE
```

The 2026-11-03 pilot passed 22 serial and 44 two-worker checks. MPI throughput
improved by about 13.5%; concurrent OpenMP checks were slower overall. Four MPI
copies exceeded the unchanged 30-second timeout, so that setting was rejected.
Those four scheduling-pilot timeouts remain separate from the canonical
validation results; the same control passed at both one and two workers.

The retained policy selects two workers for nine MPI strata and one elsewhere,
including Roomsim/SpMV MPI, GPU/hybrid checks and large-grid cases. Policy loading
reproduces the pilot comparisons and selection. Each execution wave records its
IDs, concurrency, elapsed time and result digests. Workers finish their current
checks before a checkpoint stop or infrastructure error is propagated. A failed
concurrent execution also creates `CONCURRENCY-REVIEW.json` and prevents automatic
resumption until program failure versus scheduling contention is investigated.

For failure-driven monitoring, follow `shape-topology-full-service.log` and query
the unannounced events. Mark an event only after its ID has actually been reported
to the user:

```sh
ruby tools/validation_audit/failure_notifications.rb HOME_EVIDENCE pending
ruby tools/validation_audit/failure_notifications.rb HOME_EVIDENCE mark RUN_ID
```

Floyd's full-result integer hash can reuse archived stdout when its source digest
matches the effective source. Hash mismatches require checking for a numerical
error rather than assuming equivalent values always have the same in-memory
representation. The retrospective failures were checked individually. No
floating-point hash difference is itself a failure.

The stencil case is `65 × 61 × 67` for 21 iterations. Three fixed samples land in
the interior, and the case tests odd-iteration and remainder handling. It improves
coverage but does not replace a tolerant full-array check.

## Export and verification

```sh
ruby tools/validation_audit/export.rb HOME_EVIDENCE NEW_EXPORT_DIRECTORY floyd
ruby tools/validation_audit/export.rb HOME_EVIDENCE NEW_EXPORT_DIRECTORY stencil
ruby tools/validation_audit/export_shape_pilot.rb HOME_EVIDENCE NEW_EXPORT_DIRECTORY
ruby tools/validation_audit/export_shape_full.rb LOCAL_WORKSPACE HOME_EVIDENCE NEW_EXPORT_DIRECTORY
ruby tools/validation_audit/export_spmv_full.rb LOCAL_WORKSPACE HOME_EVIDENCE NEW_EXPORT_DIRECTORY PUBLISHED_SPMV_PILOT_DIRECTORY
ruby test/test_comparison_policy.rb
ruby test/test_external_validation_cases.rb
ruby test/test_validation_audit.rb
ruby test/test_validation_shape_full.rb
ruby test/test_validation_shape_cases.rb
ruby test/test_validation_shape_export.rb
ruby test/test_validation_concurrency.rb
ruby test/test_spmv_work_count.rb
ruby test/test_spmv_full_review.rb
ruby test/test_export_spmv_full.rb
```

Exports reproduce every comparison, bind original JSONL lines by digest where
archival stdout is reused, and retain fresh correctness output and bounded build
logs. They contain no binaries or repeated generated-source trees. Each export
has its own checksummed receipt and external-validation exclusions registry.
The artifact repository applies these as eligibility overlays and regenerates
derived scores and website data without overwriting the original measurements.

The full shape export requires a completed sweep. It keeps one registry per
case and a receipt for the complete campaign, including approval, attempt method
snapshots, newly failing IDs and skipped-check reasons. Its compact scope can
reconstruct the approved plan byte-for-byte from retained source bindings;
skipped checks are never presented as passes.

Method snapshots retain the experiment baseline commit and per-file hashes for
the pilot code overlay; they are not standalone copies of the entire driver.

The full SpMV export requires verified completion and reuses the already-published
pilot by digest. It retains exact accepted inputs, per-ID findings, pinned source
references, selected compiled excerpts and raw delegated proposals. Binaries,
copied source trees and complete disassembly dumps stay out of the export.

The 2026-11-03 shape pilot retains an initial and a refined plan. The refinement
only repeats the four Cahn/stencil MPI observations with every grid dimension
above 128; `refine_shape_topology.rb` records that scoped transition. Use the
refined plan and estimate for a subsequent full sweep. A partial pilot must have
its original elapsed costs reconciled before resumption: replaying cached checks
must never make the budget estimate artificially smaller.
