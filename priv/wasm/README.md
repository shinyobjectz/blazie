

## programs/ — the TL2 registry

Real compiled tools, registered by filename into `:tl_programs` and invoked
by washy's `host_exec` when a shell line names them. Each earns its entry
from the shelf-refusal telemetry, one at a time. Rebuild: wasi-sdk clang
(`--target=wasm32-wasip1 -O2`), vendored at
`nexus/compilers/rust/mrustc-root/wasi-sdk-33.0-arm64-macos`.

| file | from | license | vendored |
|---|---|---|---|
| programs/sed.wasm | github.com/tar-mirror/minised (sedcomp.c + sedexec.c) | BSD-3-Clause (E. S. Raymond 1995-2003, Rene Rebe 2004-2005) | 2026-08-15 |
| programs/seq.wasm | ours (seq.zig — raw-WASI, zig 0.16 `-target wasm32-wasi -O ReleaseSmall`, 2.9KB) | blazie's own | 2026-08-15 |

Programs read stdin and write stdout; file arguments are unresolved for now
(wasi-libc has no cwd) — pipe into them, which is what a shell line does.
