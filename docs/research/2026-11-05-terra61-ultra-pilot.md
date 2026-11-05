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
