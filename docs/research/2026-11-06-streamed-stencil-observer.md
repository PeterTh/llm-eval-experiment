# Read-only observation of streamed stencil slabs

`stencil3d_gpt-6.1-terra-ultra_mpi_r4` streams each rank's final grid slab
to rank zero and consumes the slabs there without materializing a full grid.
Its `reportResults` routine is inlined; no supported print-function symbol
remains. The incomplete observer attempt is an infrastructure/coverage finding,
not a scientific failure.

The original source is blob `ba14e84509618673040a105b2e53140516599d59`
in commit `e8a5a56facfc3feedc8de8dc0cca41af590acd66`. The validation
ELF is pinned by SHA-256
`1c347e084b6c9f2ba1a11e8e1b5fab659d4d26a2915184c817576e3b4efdbf24`.
Source lines 63–118 stream `grid.data() + plane` for `localZ * plane`
values from ranks in increasing order. The two communication halos are not
output. Global boundary faces are part of the rank-local observed data.

Disassembly selects `grid2` at `rbp-0xf0` for odd iteration counts
(`main+0x9f9` through `main+0xa12`) before entering the inlined reporting
path. The read-only hardware breakpoint at `main+0xc45` executes once per
rank before the rank-zero/worker split, with instruction bytes
`4c8badb0fdffff`. The adapter accepts only this exact binary, unchanged
canonical output/hash helpers, four MPI ranks, and the established
`-v -r -x 65 -y 61 -z 67 -i 21` validation case. Changing the iteration
parity or any other argument rejects the adapter.

Capture requires exactly one vector per rank, with 19, 19, 19, and 18 planes
respectively, including halos. Assembly removes the first and last plane of
each vector and concatenates the observed 17, 17, 17, and 16 local planes.
It synthesizes no values. The assembled bytes must match the program's own
printed hash before comparison with the sequential array. Missing or repeated
ranks, wrong dimensions, changed bytes, or a different topology fail closed.

The targeted unchanged-program pilot took approximately 6.5 seconds including
reference capture. All 265,655 values matched the reference exactly and the
existing summary comparison passed. No source or executable-file changes,
performance measurements, tolerance changes, or resource changes were made.
The focused observer regressions passed: 19 tests and 140 assertions.

Two closed historical six-file method maps permit reuse of already complete,
unaffected observations while retaining their original method receipts. Neither
old method can validate this newly covered binary. The previous option-stream
adapter remains unchanged. A successor manifest imports the 193 complete
validation records with explicit previous-manifest and metadata bindings; only
the remaining 27 observations continue. The prior manifests and evidence remain
intact, including the incomplete observer attempt.

Compact pilot/resume evidence is retained under the campaign's
`evaluation/stencil-observer-resume` directory. Temporary arrays and executables
stay on local storage and are not publication artifacts.
