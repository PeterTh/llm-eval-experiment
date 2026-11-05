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
