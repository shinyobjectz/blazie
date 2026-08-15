# The storage plan — per-tenant SQLite over R2, and the end of Turbopuffer

*Drafted 2026-08-15. Status: plan. The seam audit's findings are folded in below;
each phase is test-first and every commit stays green.*

## Why (the decision, kept)

blazie's model — append-only facts, provenance, snapshots, read-set reactivity,
the fence — is the product. Its homegrown storage engine is not. `Store.File`
is honest about being "a memory store that also persists": 241 bytes per fact
held live, ~1M facts per world before stalls, ~6M before a 4GB box dies, and
durability that is ours to operate. Both of the operator's real anxieties —
the RAM ceiling and being the DBA of a bespoke engine — live in that one
module, behind a seam (`Blazie.Store`) that was built to be swapped.

The swap: **a tenant is a SQLite file.** Facts are rows; the three in-RAM sort
orders become on-disk B-trees; symbols (vectors) are rows in the same file;
durability is the WAL streamed to R2; the cache is SQLite's own page cache
plus the OS. The World layer — a GenServer per world in a Registry with
open/close — is already the cache-lifecycle manager: open = hydrate from R2 if
cold, close = evict. Tenancy stays absence: another tenant's world is another
file.

Turbopuffer is eliminated in the process. A symbol is a fact and the record;
the vector index is derived and disposable. Per-tenant N is bounded (hundreds
of thousands, not hundreds of millions), so exact search over the tenant's own
vectors — the built-in provider — is correct, fast enough, and tenant-isolated
by construction, which the shared Turbopuffer namespace never was
(`namespace = prefix <> space` carries no tenant). The vendor leaves the way
the module's own doc says vendors leave: delete the file.

## Measured before planning (the spike numbers)

exqlite on this machine's OTP, fact-log shape, WAL mode:

| measure | result |
|---|---|
| append, batched | **237k facts/s** (100k in 421ms) |
| indexed point read (id+attr, latest) | **5µs** |
| as-of read | `WHERE tx <= N` — native |
| on-disk size | **88 bytes/fact** (vs 241 B/fact live RAM today) |

A 1M-fact world: 88MB file, page-cache resident memory, no wall.

## What does NOT change

- The `Store` behaviour (`open/append/replay/close` + optional
  `seek/tail/last_tx`) and everything above it: `World`, `Snapshot`, jobs,
  subscriptions, the fence, `Keyring`, `Secret`, `Authority`.
- Reactivity: watchers are a Registry notified by `World.append`, decoupled
  from storage.
- Blobs: bytes to R2 via `Backup.Target.S3`, references as facts. Unchanged.
- Backups and drills keep existing until the new store's own R2 stream is
  proven — then they cover it too (a drill restores a tenant file and replays
  it; a backup nobody restored is still a rumour).

## The phases

Gate rule (house rule: spike before commitment): each phase lands behind the
seam with the existing suite green, and the next phase does not start until
the previous phase's verdict is written at the bottom of this file.

### P1 — `Store.SQLite`: the engine swap, single node, no R2 yet
A third `Store` implementation (beside Memory/File): one SQLite file per
world, `facts` table, EAVT/AEVT indexes, WAL mode, INSERT-only (the
append-only discipline stays the seam's, not the engine's). Implements
`seek/tail/last_tx` so `World` takes the paged path — the resident tail stays
small and indexed reads go to the store. Store selection stays a config line.
**Test-first:** the existing store/durability suites parameterized over the
new module, plus a store-parity property test (File and SQLite answer every
seek/replay identically over generated histories).
**Exit:** full blazie suite green on `Store.SQLite`; measured bytes/fact and
open-time recorded here.

### P2 — durability to R2: stream out, hydrate in
Continuous shipping of the WAL/file to R2 (per tenant), and `open` on a node
without the file restores it from R2 first. Decision inside this phase,
measured not guessed: extend blazie's native S3 target (it already signs
SigV4 to R2, and backup/drill know it) to per-commit shipping, vs. run
Litestream as a sidecar per node. Native keeps one wire and the drill
covers it; Litestream is battle-tested but a second moving part per node.
**Exit:** kill a node after an append; reopen elsewhere; the fact is there.
Drill extended to the new path.

### P3 — the index comes home: Turbopuffer deleted
Vectors live where facts live. The exact provider becomes the default and
only in-tree provider; its hot structure is rebuilt per world from symbol
facts on open (or lazily on first search) — derived and disposable, now with
tenancy by absence because a world's symbols are in the world's file.
`Index.Turbopuffer` and its wire test are deleted; the deferred live-tripwire
item is closed as moot. The `Index` behaviour seam STAYS (a future whale
tenant can bring an ANN provider back for one space without a rewrite).
**Exit:** grep for the vendor answers nothing but history; index tests green
against rebuilt-from-facts; the sweep epic's C3/C4 wire the built-in provider.

### P4 — the cluster cache policy: hydrate, evict, stick
World lifecycle grows the two policies the file model needs: idle eviction
(close world + drop local file; R2 remains truth) and disk-pressure LRU.
Sticky tenant→node routing (consistent hash at the surface/router) so a
tenant's writers and watchers land where the file is warm — which also keeps
read-set reactivity in-process, where it already works. Single-writer per
tenant is the invariant that makes this a router, not a consensus problem.
**Exit:** two-node test — tenant sticks, evicted tenant rehydrates on next
touch, no cross-node write ever happens.

### P5 — retirement
`Store.File`/`Store.Paged` demoted to test/reference (or deleted if nothing
pins them), migration tool ships (open old store, replay into new — replay IS
the migration), deployment docs + runtime config flip the default. UpCloud
deploy updated; keys/backup env unchanged.

## Open items the audit must settle (folded in as answered)

- Exact seek-pattern semantics `Store.SQLite` must honor.
- Which of backup/drill/compact/erasure touch the ledger file format directly
  (hidden coupling), and what erasure's key-destruction needs from the store.
- Whether `World` can shed its in-RAM sort orders entirely in P1 or that is a
  P1.5 (memory win lands later, correctness first).
- Turbopuffer's full delete footprint.

## Verdicts

*(appended per phase as they land)*
