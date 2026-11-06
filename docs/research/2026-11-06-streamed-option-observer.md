# Read-only observation of streamed Black–Scholes output

`black-scholes_gpt-6.1-terra-ultra_mpi_r2` does not materialize the full
result on rank zero. Its `printDistributedResults` routine consumes the local
vector, then receives other ranks' contiguous blocks in rank order. The normal
`print_results` symbol exists but is called only for an empty input. Consequently
the initial full-array observer captured no arrays. This is an observer coverage
issue, not a generated-program validation failure.

The reviewed source is blob `0c1be017cd523b0b9df6595824dde438cb4a141b`
in original-output commit `e8a5a56facfc3feedc8de8dc0cca41af590acd66`.
The source-bound validation ELF has SHA-256
`82bcac98d064d0427fb90ffd229fc4a03796fa39fd329e38c40e9173366f1873`.
Source and disassembly agree on the System V vector-reference argument at the
entry of `_Z23printDistributedResultsRKSt6vectorIdSaIdEEmii`, and on rank-order
consumption. The observer uses the existing read-only hardware-breakpoint ABI.

The added adapter accepts only that binary, the unchanged canonical output/hash
helpers, four MPI ranks, and the established `-v -r -n 10003` case. It requires
exactly one block per rank with lengths 2501, 2501, 2501, and 2500, concatenates
the observed bytes, and checks correspondence with the program's own printed
hash before numerical comparison. No result values come from the reference.
Missing/duplicated blocks, wrong dimensions, changed bytes, and unreviewed
shapes are rejected. No source, executable bytes, tolerance, resource profile,
or performance setting changes.

The targeted native pilot took approximately 3.3 seconds including reference
capture. All 10,003 prices matched the sequential array exactly; the existing
summary comparison also passed. Full regression suite: 513 tests, 2,989
assertions, zero failures/errors/skips.

Existing complete observations remain valid: the added capture path is selected
only by the new exact binary digest. A closed six-file historical method map
allows reuse of unaffected observations with their original receipts. The newly
covered binary cannot reuse that historical method. Unknown method versions
remain rejected. A successor validation manifest can therefore retain the 11
already completed records, with explicit origin-manifest and metadata bindings,
and continue the remaining 209 without rerunning accepted observations. The
initial manifest and evidence remain intact. This changes observer coverage,
not the scientific acceptance criterion; no performance benchmark rerun is
involved.

Compact pilot and resume evidence is retained under the Terra Ultra campaign's
`evaluation/observer-resume` directory; raw captures and executable scratch stay
on local storage and are not publication artifacts.
