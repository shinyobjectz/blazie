# The storage plan — per-tenant SQLite over R2, and the end of Turbopuffer

*Drafted 2026-08-15; revised same day after the seam audit. Status: plan,
audit-grounded. Each phase is test-first, every commit stays green, and a
phase's verdict is written at the bottom before the next begins.*

## Why (the decision, kept)

blazie's model — append-only facts, provenance, snapshots, read-set reactivity,
the fence — is the product. Its homegrown storage engine is not. `Store.File`
is honest about being "a memory store that also persists": 241 bytes per fact
held live (87% of it the three sort orders), ~1M facts per world before stalls,
~6M before a 4GB box dies, and durability that is ours to operate. Both of the
operator's real anxieties — the RAM ceiling and being the DBA of a bespoke
engine — live in that one module, behind a seam (`Blazie.Store`) built to be
swapped and already proven swappable by `Store.Paged`.

The swap: **a tenant is a SQLite file.** Facts are rows; the three in-RAM sort
orders become on-disk B-trees; symbols (vectors) are rows in the same file;
durability is the WAL shipped to R2; the cache is SQLite's page cache plus the
OS. The World layer — a GenServer per world in a Registry with open/close — is
already the cache-lifecycle manager: open = hydrate from R2 if cold, close =
evict. Tenancy stays absence: another tenant's world is another file.

Turbopuffer is eliminated in the process. A symbol is a fact and the record;
the vector index is derived and disposable. Per-tenant N is bounded, so exact
search over a tenant's own vectors is correct, fast enough, and tenant-isolated
by construction — which the shared Turbopuffer namespace never was
(`namespace = prefix <> space` carries no tenant). The vendor leaves the way
its own doc says vendors leave: delete the file.

## Measured before planning

exqlite on the pinned OTP (27), fact-log shape, WAL mode:

| measure | result |
|---|---|
| append, batched | **237k facts/s** (100k in 421ms) |
| indexed point read (id+attr, latest) | **5µs** |
| as-of read | `WHERE tx <= N` — native |
| on-disk size | **88 bytes/fact** (vs 241 B/fact live RAM today) |

A 1M-fact world: an 88MB file, page-cache-resident, no wall.

## What the audit established (the load-bearing facts)

- **The seam is real.** The behaviour is 4 required callbacks
  (`open/append/replay/close`); `seek/tail/last_tx` are optional but travel
  together — `World.init` checks only `seek` and then calls all three, so a
  store implementing one must implement all. There is also an undeclared
  `stats/1` (Storage/Metrics read it) and a `filename/1` `World.exists?` leans
  on. The paged path (`world.ex` `paged?` branch) already does everything
  `Store.SQLite` needs World to do.
- **Reactivity is untouched by a store swap.** Watchers are a Registry
  dispatched by `World.append` *after* the store records; the store holds no
  reference to it. `storage_events_test.exs` pins this (doctrine 20).
- **Erasure is orthogonal.** Values are envelope-encrypted in the World
  (`seal/2`) before any store sees them; the store only ever holds ciphertext
  tuples; keys live in a separate dir with a separate backup. Sealed values
  must stay value-unsearchable (scalar column NULL).
- **The store is the easy part; the durability apparatus is the cost.**
  `Backup` + `Drill` + `Compact` are ~1,200 lines that assume append-only
  bytes (byte-range segments, restore-by-concatenation, walk-and-rewrite).
  Replication is more than half the total work. `Drill`'s restore-and-compare
  (`ask_both/3`) is store-agnostic and survives; the pull/reopen halves do not.
- **Compaction gets *better*:** erased-ciphertext reclamation becomes
  `UPDATE ... SET value = :erased WHERE subject IN (...)` + `VACUUM` — ~10
  lines replacing a 110-line file rewriter, with the same assertable
  properties.
- **Migration is first-class, not a footnote.** Real disks hold old-shape
  bytes (`LazyRiver.Fact`, `answer` slots — `old_shapes_test.exs`). So
  `Store.Record` + `Fact.from_stored/1` survive as the importer even after
  `Store.File` retires, and `.ledger → .sqlite` runs through them.
- **Deleting Turbopuffer is ~1 hour; the real task it hides is making
  `Index.Exact` production-worthy (~2–3 days):** nothing configures
  `:blazie, :index` today, the Exact holder Agent is unsupervised (a crash
  silently empties every index), and `Index.job/3` is wired to a runner only
  inside a test — nothing rebuilds an index after a node restart in
  production.

### The six landmines (named so they cannot bite silently)

1. **Within-tx ordering:** `Snapshot.value/3` is last-write-wins *by list
   position* inside a transaction. `ORDER BY tx` alone is wrong; every SQL
   read is `ORDER BY tx, seq` (seq = rowid). No existing test catches this.
2. **Deterministic keys:** ids and world names can be maps; keying rows on
   `term_to_binary/1` breaks across OTP releases (EEP-18). Use
   `term_to_binary(term, [:deterministic])` (OTP 27 is pinned). The same
   hazard already exists in `Store.File.filename/1`.
3. **Decode is a trust boundary (C7):** bytes can come back from a bucket.
   Keep `[:safe]` + shape-gating on every value decode, per-value.
4. **The serialized check sees resident facts only** — already a hole for
   bounded worlds; going residency-less makes it everyone's. Fix it (lazy
   store handle) before `resident: :none` ships.
5. **Litestream vs native:** worlds are created at runtime with arbitrary
   names; Litestream's config is path-listed — whether it globs new files is
   an open question that decides the P4 vendor. blazie's `Backup.Target.S3`
   (hand-signed SigV4, already the R2 path) is the native alternative; the
   drill and `proven_at` alarms must keep meaning something either way.
6. **Netsplits:** today `:global` *refuses* a second opener; a
   file-replicator would instead last-writer-win. Sticky tenant→node routing
   is therefore a correctness requirement in P4-cluster, not an optimization.

Also noted: symbols are float64 (`<<_::float-64-little>>`) — 3.2KB per
384-dim symbol, 2× what float32 costs on disk, in RAM, and over replication.
Orthogonal to the swap; worth its own measured decision.

## The phases (audit-sized; ~3–4 weeks focused, P4 more than half)

**P0 — the conformance suite (1 day).** Extract the store-agnostic assertions
from `store_test` / `memory_test` / `store_paged_test` / `compaction_test`
(non-checkpoint half) into one suite parameterized on `{module, opts}`; run it
against Memory, File, Paged. Green = nothing changed, three stores share one
suite. This is the highest-leverage day in the plan.

**P1 — `Store.SQLite`, additive (2–3 days).** `{:exqlite, ...}` (NIF precedent:
wasmex already ships rustler). One file per world; `facts(seq, tx, id_blob,
attribute, value_s, value, by_blob)` with EAVT/AEVT/value partial indexes;
WAL; `BEGIN IMMEDIATE` per append (atomicity replaces the torn-record
apparatus); `seek/tail/last_tx` + `stats` + filename; `PRAGMA synchronous`
mapped to the `sync:`/`LEDGER_SYNC` dual-CI story. Registered in the
conformance suite. File stays the default. Landmines 1–3 addressed here.

**P2 — the migrator (1–2 days).** `.ledger → .sqlite` through `Record.walk` +
`Fact.from_stored/1`; proven against `old_shapes_test`'s hand-written byte
fixtures answering identically from SQLite.

**P3 — Turbopuffer out, Exact in (2–3 days; parallel to P1–P2).** Delete the
vendor module + its test half (keep `Wire` as the generic HTTP-provider
fixture so the swappable claim stays proven). Then the real work: supervise
the Exact holder, `config :blazie, :index`, wire `Index.job/3` under a
runner, and a restart-rebuilds-the-index test. The Index seam stays — a whale
tenant can bring an ANN provider back for one space without a rewrite.

**P4 — replication to R2 (3–5 days; highest risk, decided by measurement).**
Continuous per-tenant shipping + hydrate-on-open. Vendor decision inside the
phase: Litestream sidecar vs extending native `Backup.Target.S3` into a
per-commit replicator — settled by the runtime-tenant/glob question (landmine
5). Keep Backup's keys half; rework `Backup.run` to report replication lag as
facts so `proven_at` alarms survive; rework `Drill.pull` to restore-into-
scratch while `ask_both/3` stays. Exit: kill a node after an append, reopen
elsewhere, the fact is there; the drill proves it on cadence.

**P4-cluster — hydrate, evict, stick.** Idle eviction (close + drop local
file; R2 is truth), disk-pressure LRU, sticky tenant→node consistent-hash at
the surface (landmine 6 makes this correctness). Single-writer per tenant;
`Cluster.owner/1` already answers who; routing starts acting on it.

**P5 — flip the default (0.5 day; the dangerous commit).**
`World.default_store/0` → SQLite; boot-time migration of any `.ledger` in
`LEDGER_DIR`; `store_default_test` + `storage_layout_test` updated
deliberately (its moduledoc records why: a silent rename once left a node
green beside 791KB of invisible facts).

**P6 — compaction + residency (1–2 days).** `Compact.erased/2` as
UPDATE+VACUUM (same asserted properties). Then `resident: :none`, fixing the
serialized-check hole (landmine 4) first.

**P7 — retirement (much later, maybe never).** `Store.Record` stays as the
importer; `Store.File` demoted to the read-only legacy path. Retiring it buys
nothing; not scheduled.

## Verdicts

*(appended per phase as they land)*
