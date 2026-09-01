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

The exact frozen tool snapshot and compact evidence for the canonical release are in
[`llm-eval-local` at `local-eval-2026-08-25`](https://github.com/PeterTh/llm-eval-local/tree/local-eval-2026-08-25/method/timing-audit).
The release snapshot is intentionally duplicated there so its checksums remain stable;
this repository owns the maintainable source and tests.

Run all tests from the repository root:

```bash
ruby -Itest -e 'Dir["test/test_*.rb"].sort.each { |file| require_relative file }'
```
