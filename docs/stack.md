# The stack, and what it isn't

Decisions as of 2026-08-12. The vocabulary lives in `.monty/ontology.db`; this
file is engineering, which is deliberately not vocabulary (doctrine 12).

**The selection rule: prefer what we do not maintain.** Where a maintained
library covers the requirement, it wins over code that fits better but is ours
to keep alive. Guest code here is written against our ABI rather than ported
from the world, so the requirement is narrower than a general sandbox — Wasmex
covers it, and the ambitious cases (unmodified POSIX binaries, x86 emulation,
JS on the BEAM) solve a problem we do not have.

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

## Asking — re-execution now, and no query language yet

This is socialite's substrate, not a database product, and that decision removes
the hardest component from the critical path.

**Incremental view maintenance is product engineering.** It earns its cost when a
stranger might define an enormous derived view nobody anticipated. For a known
application, recording what a question read and re-answering it when a later fact
lands in that read set is enough — the approach Convex has proven at real
application scale. It has a ceiling. Socialite will not reach it.

So: **no Datalog yet, and no query language yet.** A formula is an Elixir function
over `Snapshot.find/2`, and read-set tracking works regardless of what expressed
the reads. A language is a surface for *tenant-authored* questions, which do not
exist. Doctrine 15 says a formula never says how it is evaluated, so this choice
is reversible by construction.

**What we walked away from, and where it waits.** `differential-dataflow` is the
engine if IVM is ever needed (active, storage-agnostic, proven at Materialize
scale); `dbsp` is the live alternative with better theory but treats outside
consumers as off-label; FlowLog compiles Soufflé-syntax Datalog to differential
dataflow and is the living successor to the archived DDlog. Any of them slots in
under the same seven words.

**Rejected: Cypher and SQL as the eventual surface** — mutation-oriented over a
property graph we do not have, and neither composes without string building. But
this is now a later decision, not a founding one, and the standards argument for
them is real.

**Rejected: CozoDB.** Architecturally the closest thing that exists — embedded,
Datalog, graph algorithms, HNSW inside the query language, time travel — and
unpushed since December 2024 with a dormant Erlang binding. Excellent to
prototype semantics against; the Kuzu mistake to build on.

**Rejected: Ascent and Crepe** for tenant questions, since Rust macros compile
rules at build time and questions arrive at runtime. Right tool for the engine's
*own* fixed checks.

## The client contract — four operations

A caller outside the cluster holds a snapshot's *name*, not its bytes: which
ledgers were composed, at which transaction. Small, stable, comparable.

    open      which ledgers  -> a snapshot name
    ask       name, question -> an answer
    watch     name, question -> answers as the name advances
    write     name, facts    -> a new name

That is the whole surface. `write` returning a name is what lets a caller read
its own write without polling: the name it got back is the snapshot its facts
are in.

Because an answer at a name never changes, a client caches on (name, question)
and never invalidates. There is no cache-coherence protocol here because there is
nothing to cohere — old names stay answerable, and a stale cache entry is simply
an answer to an older question.

**Authorization is which ledgers a caller may name.** Not row rules, not
predicates. `open` is the checkpoint, and the resulting name records what was
composed, so every later answer carries its own provenance.

**Transports:** Phoenix Channels carries all four and is required for `watch`.
Plain HTTP covers the first, second and fourth for callers that do not need live
answers. MCP wraps the same four for agents.

## Changing things — additive, except erasure

Doctrine 16. Migration is mostly not migration:

| want | do |
|---|---|
| add an attribute | write facts with it |
| change what an attribute means | add a new one, formula maps old to new |
| fix wrong data | write a later fact |
| change a model | new formula identity; derived facts recompute |
| stop using an attribute | stop writing it; old facts stay readable |
| make data actually gone | erasure — the only destructive operation |

**Erasure is crypto-shredding.** Facts carry a subject and are encrypted under
that subject's key; erasing destroys the key. Chosen over the alternatives for a
specific reason: excision rewrites segments, which would change the answer at an
already-named snapshot and break the client contract's caching guarantee.
Shredding turns a value unreadable instead of turning it into a different value —
a bounded, explicit break rather than an arbitrary one.

Key store is separate from the segments, so backups need no special handling.

**Reaching derived facts is a walk over `derived-by`.** An embedding of an erased
message may still encode it, so erasure closes over what the formulas produced.
This is the one place provenance stops being a nicety.

**The constraint, stated up front:** a fact that does not declare its subject can
never be erased. Subject is decided at write time or not at all.

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
