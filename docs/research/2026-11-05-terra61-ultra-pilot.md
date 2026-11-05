# Terra 6.1 Ultra pilot

The authorized pilot uses the normal production prompt, sequential input, tool
restrictions, isolated filesystem and four-hour task budget. Four observations
(one per backend) are selected in advance and retained for reuse in a possible
220-observation campaign; program correctness is not a pilot acceptance gate.

Only the `gpt-6.1-terra-ultra` profile permits native Codex delegation. It removes
the two single-agent disable flags and explicitly enables `multi_agent`, leaving
the pinned client's other native delegation defaults unchanged. Existing model
profiles still receive exactly their previous flags. There are no custom agent
instructions, child-model overrides, prompt changes or new external tools.

All fresh parent and child rollouts are archived after the isolated process tree
exits. Recovery and inspection happen with the evaluation account idle, never
during performance tuning. The existing parent-only usage record must not be
represented as total Ultra usage: pilot review must establish the child-session
tree, actual model/effort selection, complete accounting without inherited-history
double counting, and cleanup before accepting the full campaign. Native Ultra
delegation behavior is something to verify in the pilot, not infer from flags.

Pilot generation alone is authorized. It yields at an observation boundary for
Fable's 2026-11-06 17:00 UTC reset; it never interrupts an active observation to
meet that deadline. Persistent evidence is under home, working copies on local
scratch. A later full campaign requires pilot review and authorization.

## Catalog preparation

The four-observation pilot exposed three catalog-refresh timeouts. Only the CUDA
matrix-multiplication observation used fallback metadata; the other three retained
Terra's native metadata. The previous 440 Terra medium/xhigh transcripts, using
the same CLI binary and isolation runner, contain neither refresh errors nor
fallback warnings. This is an infrastructure issue, not a generated-program
failure; only the affected observation is authorized for replacement, preserving
its original evidence separately.

New Codex generation requires a captured native catalog and its bound preparation
receipt. The collector uses only initialize/model-list RPCs in a fresh isolated
home, strips account/cache bookkeeping, and preserves all upstream model
definitions. Before publication it removes the fresh cache, disables networking,
proves that the pinned CLI loads the local catalog, rejects a missing file, and
checks that the catalog mount is read-only. Preparation is outside the task clock.
The catalog is frozen once per campaign; observations verify its fingerprints and
pass the stock `model_catalog_json` setting. No prompt, model definition, model
binary, tool permission or compute budget is changed by this repair.

Ultra may cancel unfinished children when the parent completes. Count recorded
per-request usage across all unique child threads, not only the parent's terminal
counter. Preserve a flag when interrupted-request usage cannot be established;
do not modify native shutdown behavior or discard otherwise valid observations
for this limited accounting uncertainty.

## Corrected pilot outcome

The catalog repair passed 495 regression tests (2,925 assertions), the offline
metadata-only checks, and the existing native MPI/OpenMP and CUDA preflights.
The captured Terra model definition exactly matches the native catalog retained
before the initial pilot. Only `matmul_gpt-6.1-terra-ultra_cuda_r1` was repeated;
its original attempt remains in the campaign's `catalog-repair-20261105/superseded`
directory. File fingerprints establish that the other three observations are
unchanged. The replacement completed in 147.76 seconds with two native child
agents and no catalog-refresh or fallback warning.

All four retained observations passed the harness pilot review: 16 sessions
(four parents and 12 children), all using Terra Ultra and native context metadata,
with verified cleanup. The 341 unique recorded request counters reconcile with
each thread's cumulative usage: 7,577,635 total tokens, including 7,102,720 cached
input tokens. Three observations retain the interrupted-child uncertainty flag;
these are recorded totals, not a claim that every interrupted request is billed
exactly. The retained generation time is 852.58 seconds.

A post-run controller check initially read the progress snapshot as though it
were an observation report. Independent review of the already-retained report
resolved that bookkeeping error without another generation run. Detailed evidence
is retained under
`~/llm_para_campaigns/20261105-131145-terra61-codex-ultra/catalog-repair-20261105/`,
including `completed-review.json`, `recorded-tree-usage.jsonl`, and native catalog
receipts. This accepts the harness pilot, not the scientific validity of the
generated programs; validation and benchmarking have not started.

The remaining 216 observations are not launched or authorized by this pilot.
Before a full campaign starts, its accounting path must use parent-plus-child
records and interruption flags rather than the legacy parent-only recovery.
