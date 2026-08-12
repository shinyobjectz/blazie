# The stack, and what it isn't

Decisions as of 2026-08-12. The vocabulary lives in `.monty/ontology.db`; this
file is engineering, which is deliberately not vocabulary (doctrine 12).

```
Phoenix           channels and subscriptions, the HTTP surface
OTP               process per ledger, jobs scheduled from the ledger
Wasmex/Wasmtime   tenant formulas and jobs
Rustler           SlateDB, Nx kernels
SlateDB on R2     facts as sorted keys, SSTs as immutable segments
Nx/EXLA           brute-force vector search until measurement says otherwise
Ports             ffmpeg, PDFium, libvips — OS-sandboxed, out of process
```

No Postgres, no Kuzu, no vector database, no message broker, no job queue.

## Storage — SlateDB, not a lakehouse format

The four covering indexes are key encodings in one sorted keyspace:

    e|a|v|t   everything about one id
    a|e|v|t   one attribute across ids
    a|v|e|t   value ranges and uniqueness
    v|a|e|t   edges backwards

That is an ordered KV store, not a columnar table, and it is what Datomic does —
sorted segments in a blob store. SlateDB is an LSM engine built for object
storage (Apache 2.0, community org, production users), and it batches writes
through a memtable, which matters because R2's egress is free but its operations
are not.

A snapshot is a manifest naming immutable SSTs. A ledger fork is a new manifest
naming the same SSTs. Both fall out of immutability rather than being bought.

**Rejected: Lance as the foundation.** Columnar-analytics shaped, so wrong for a
workload that is almost entirely point lookups and range scans. Three of its four
features (versioning, cloning, random access) we get free from immutability. The
fourth — ANN at scale — is deferred. It returns only if vectors outgrow brute
force, and then as one column's index rather than the foundation.

**Rejected: Parquet + Delta/Iceberg + DuckDB.** Right architecture for analytical
scans, wrong for ours. No vector index, so `fact` and `symbol` would re-split into
two systems. Its usual form also drags Oban and therefore Postgres back in, which
contradicts a job being a fact.

**Rejected: Kuzu.** Archived October 2025 after Apple acquired Kùzu Inc. It was
already excluded — a graph engine is a second row shape, and the graph is what
facts already are.

**Rejected: FoundationDB.** The best ordered KV store here, but a separate service
to operate.

## Compute — three tiers, one line

Doctrine 14. A formula never reaches outside; the sandbox is about trust.

| tier | what | where |
|---|---|---|
| ours, our bytes | embedding, hashing, index building | in process, native |
| ours, someone else's bytes | ffmpeg, PDFium, libvips | own process, seccomp + landlock |
| not ours | tenant and agent formulas | WebAssembly, no capability |

Out-of-process costs ~1–3ms to spawn against work measured in seconds, so it is
under a percent for these three. Pass a file descriptor rather than piping bytes.
A crashing Port does not take the node down; a crashing NIF does — which is why
the segfault-prone libraries are Ports and only memory-safe Rust is a NIF.

**Rejected: Wasmer.** Wasmex already ran on it and migrated to Wasmtime. WASIX is
non-standard and widens the default capability surface, which is backwards when
purity is doctrine. Its differentiators are hosting products.

**Rejected: MQuickJSEx.** A second sandbox with weaker guarantees. QuickJS
compiles to WASM — run JavaScript in the sandbox we already have.

## Media — three out-of-process dependencies, and only three

ffmpeg (CLI binary, not libav bindings), PDFium, libvips for HEIC/AVIF/JP2 and
very large images. Everything else is pure Rust in process: `image`/`zune-*`,
`calamine`, `docx-rs`, `zip`, `blake3`, `csv`, `arrow`.

The dividing line is memory safety, not language. Pure Rust parsing a stranger's
file is fine in process; C parsing a stranger's file is not, however stable its
API.

Not covered, deliberately: adaptive-bitrate delivery is a CDN's job, and OCR and
virus scanning stay tenant formulas until something demands them.

## Vectors

A vector is a `symbol` — a fact's answer — so there is no vector store. Embedding
is a formula, never a job. Search starts as one Nx matrix multiply over the
snapshot: exact, no index, no invalidation. An index appears later as a formula
the engine wrote for itself.

Symbol columns are packed contiguously rather than stored inline. An attribute
declares its space, and a cross-space comparison is refused.

**Open:** dtype and dimension. At a million vectors, f32 is 1GB, f16 half, int8 a
quarter — which decides whether brute force needs an index at all.

**Rejected: Arcana.** Needs Postgres and pgvector. It is also what an application
built *on* Lazy River would be, not a component of it — its feature list is a good
acceptance test.

**Rejected: Jido.** Models agent state as process state, which is a second store
outside every ledger. An agent is a job and its state is facts.

**Rejected: Temporal-style durable workflow engines.** The ledger is the durable
execution log by construction. Resuming is reading it and continuing.
