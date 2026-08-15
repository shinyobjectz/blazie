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
5. **Litestream vs native: RESOLVED — Litestream sidecar.** The
   dynamic-tenant objection is dead: v0.5.x takes `dir` + `pattern` +
   `watch` (a new tenant file starts replicating within seconds; a deleted
   one is cleanly removed), and adds distributed leasing with conditional
   writes and a tested restore path (integrity validation, follow mode,
   PITR). Most actively maintained project in the whole survey. The native
   SigV4 client keeps its backup job (belt and suspenders). Revisit native
   only if R2 request costs at real tenant counts break the budget — and
   then copy Verneuil's content-addressed chunks + manifest, not WAL
   shipping.
6. **Netsplits: routing is a hint, the lease is the fence.** cr-sqlite /
   Corrosion / Marmot are one long proof that a second concurrent writer
   means either full CRDT machinery or silent last-writer-wins loss — both
   wrong for a provenance fact log. Sticky routing decides who *should*
   write; an object-store **conditional-write lease** (Litestream v0.5.8's
   distributed leasing) is what makes a stale node's flush *fail* instead of
   clobber. The concrete hole it closes: node A partitions mid-flush, node B
   hydrates from R2 and writes, A returns and flushes stale WAL.

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
Schema steals from Mozilla Mentat (EAV-on-SQLite, proven; died of scope,
not mechanism): consider the **two-table split** (current-state table beside
the append-only history so reads never fight their own past — measure
whether our tx-bounded reads need it), a **type tag participating in every
index** so ordering stays sane across value types, extra access paths as
**partial indexes gated by per-row flags** (unindexed attributes cost
nothing), and an **excision flag reserved now** — append-only with no lawful
deletion path is a liability both Mentat (`allow_excision`) and Datahike
(purge) engineered for from day one; ours can stay unimplemented but named.

**P2 — the migrator (1–2 days).** `.ledger → .sqlite` through `Record.walk` +
`Fact.from_stored/1`; proven against `old_shapes_test`'s hand-written byte
fixtures answering identically from SQLite.

**P3 — Turbopuffer out, Exact in (2–3 days; parallel to P1–P2).** Delete the
vendor module + its test half (keep `Wire` as the generic HTTP-provider
fixture so the swappable claim stays proven). Then the real work: supervise
the Exact holder, `config :blazie, :index`, wire `Index.job/3` under a
runner, and a restart-rebuilds-the-index test. The Index seam stays — a whale
tenant can bring an ANN provider back for one space without a rewrite.
Later refinement, behind the same seam: `sqlite-vec` (`vec0` tables in the
tenant file — exact KNN only, which is exactly our bounded-N case, float32
by default so 2× smaller than today's float64 symbols) — but it is genuinely
alpha, so BEAM brute-force over symbol facts is the default and vec0 an
implementation detail, adoptable per space when it stabilizes.

**P4 — replication to R2 (3–5 days; highest risk).** Continuous per-tenant
shipping + hydrate-on-open. **Vendor decided by the prior-art survey:
Litestream sidecar** (landmine 5 — the dynamic-tenant objection is dead).
Conditions on the verdict: pin the version + set `meta-dir`; Litestream owns
WAL checkpointing (no manual checkpoints host-side); `sync-interval` set
with Verneuil's cost math in view (per-tenant intervals multiply into the R2
request bill — budget requests globally, ~30/s/process is the survivor's
number, with a bounded local spool so an unreachable R2 can never fill the
disk); shutdown drains the replicator (deploys-reset-in-flight, our own
ground rule); restore-from-R2 exercised in CI, not just replication. Keep
Backup's keys half; rework `Backup.run` to report replication lag as facts
so `proven_at` alarms survive; rework `Drill.pull` to restore-into-scratch
while `ask_both/3` stays. Exit: kill a node after an append, reopen
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

## The Lua runtime track (LT) — one language, one fence

*Decided 2026-08-15, alongside this plan: blazie gets super-opinionated about
authored code. Everything a guest runs is Lua on Luerl — wasmex, the wasm
lane, and WASI-CPython are removed. One guest runtime, one capability
function (`Lua.capabilities/1`), BEAM process isolation (unlinked process,
deadline, `max_heap_size`) instead of fuel. Rustler NIFs stay available for
HOST-side performance; guests never see them.*

Why the trade is good: inside a no-network fence, Python's ecosystem
advantage mostly evaporates — you cannot `pip install` behind the fabrication
fence anyway, so the interpreter was carrying its weight in syntax, not in
libraries. Lua is one small language the model writes fluently, guests stay
pure, and heavy numerics escape to host seams (Model providers, NIFs) — the
same escape hatch the continual-learning sketch already names. Pure-Lua
vendoring only (the `learn` treatment); luarocks C modules cannot load under
Luerl and the capability model would refuse what they do anyway.

**LT1 — the workspace grant (steal tiny-lasers' VFS).** The Coding agent's
`run` tool needs files; Luerl guests deliberately have none. The answer is
`~/Apps/workbooks/tiny-lasers`' `Wasm.VFS` design (101 lines, barely
wasm-coupled): a key→bytes map mediated entirely in Elixir — "a guest path is
never a host path… there is no filesystem to traverse out of, because there
is no filesystem" — with a backend seam whose second backend is already a
tenant-partitioned SQLite store, converging with P1 on its own. For Lua we
skip tiny-lasers' 372-line fd_table entirely (that half is WASI emulation):
guests get `file.read/write/list` as granted host functions over the VFS,
scoped per run, `:job`-only like every reaching capability. Workspace bytes
land in the tenant's file (or as blob refs), so P4 replication covers the
workspace for free.

**LT2 — Coding runs Lua.** The `run` tool executes Lua in a Luerl guest over
the granted workspace instead of Python in WASI. The coding loop's tools
(list/read/write) re-point at the VFS. Verdict written on: suite damage,
deadline/heap parity with fuel for runaway guests, and a wall-clock number
for a representative dossier computation.

**LT3 — wasmex out.** Delete `Sandbox`'s wasm/WASI lanes, the wasmex dep, and
the Python image path; `Lua.capabilities/1` is the single fence (doctrine 14
becomes literally one function). `sandbox_fence_test` properties re-pointed
at the Lua fence — the *claims* (no network, no clock, no reach) all survive,
only the engine underneath changes.

**LT4 — the expressive grants (after P1).** `sql(query)` — host-executed,
read-only, against exactly the tenant's staged SQLite file; the fence is the
file, guests never hold handles. `http.get_many` if a fan-out case demands
it — async is more guests or a granted concurrent primitive, never an event
loop inside one.

**The guest library shelf** (surveyed 2026-08-15; every candidate gets a
Luerl smoke test — the `learn` treatment — before trust). Keep: **lust +
luassert** (minimal pure-Lua describe/it — likely IS the tenant-test core LT
planned to hand-write), **json.lua** (guest-side JSON before `blob()`),
**Moses/Microlight** (functional utility belt for authored code),
**serpent/inspect** (legible dumps), **LuLPeg** (pure LPeg, shelved until a
job needs parsing). Rejected with reasons: lua-lockbox (crypto is host-plane
— `Secret`/Keyring — by design), RxLua (reactivity is the Job model's),
cron.lua (the clock is the fence's), 30log/middleclass (closures suffice —
`learn` proved it). kong-lua-sandbox: mechanism NOT adopted — in-language
env-whitelist + cooperative debug-hook quotas, with its own README candid
about bytecode escapes; blazie sandboxes below the language (host-stripped
Luerl state, no bytecode path, preemptive BEAM heap/deadline). Its curated
BASE_ENV whitelist is kept as an LT1 review checklist against
`Lua.world/2`'s strip list — every divergence deliberate.

Ordering: LT1–LT2 can start immediately (only LT4 waits on P1); LT3 lands
when LT2's verdict is green. Each LT phase gets a verdict below like every
storage phase.

## Verdicts

**P0 (2026-08-15): PASS.** `test/store_conformance_test.exs` — one macro,
29 assertions of the seam's contract run against Memory, File and Paged
(ordering, resumption, bounded-residency-never-changes-answers, old names
answer forever, erasure reaches evicted facts), including the two
within-transaction ordering guards that no per-store file had (landmine 1's
tripwire, now armed before any SQL is written). Existing per-store files
untouched — format-level claims (tears, checkpoints, same-file-either-store)
stay where they belong. Full suite 852 green, and green again under
`LEDGER_SYNC=true`. `Store.SQLite` now has a definition of done before it
has a line of code.

**P1 (2026-08-15): PASS.** `Blazie.Store.SQLite` — one file per world, the
whole `Store` behaviour plus `seek/tail/last_tx` (so `World` takes the paged
path), `stats`, deterministic `filename`. Landmines 1–3 addressed as
designed: every read is `ORDER BY tx, seq`; every key is
`term_to_binary(term, [:deterministic])`; every decoded value passes the
same C7 gate (`Record.stored_fact?` + `harmless?`) the file stores enforce.
INSERT is the only statement ever issued — append-only stays the module's
discipline, not the engine's. Passed the ENTIRE conformance suite on the
first run (40/40 incl. erasure-reaches-evicted and both within-tx ordering
guards); full suite 863 green and green under `LEDGER_SYNC=true`
(`synchronous=FULL`). Measured through the real store (Fact structs, gate,
keys): **97k facts/s append · 88 bytes/fact on disk (vs 241 live-RAM today)
· 777µs indexed seek across 100k facts · 2ms reopen** (a File-store reopen
replays everything). Default store unchanged — additive, as planned.

**P2-migrator (2026-08-15): PASS.** `Blazie.Store.Migrate.ledger_to_sqlite/2`
— parses no bytes itself: reads through `Store.File`'s replay (which already
normalizes every shape ever written; `old_shapes_test`'s own fixture writers
are the test's fixtures here) and appends into `Store.SQLite` in one SQL
transaction, original tx numbers kept, replay order = insertion order = seq,
so within-tx position survives the migration boundary (tested). One-way and
refusing to double: a target already holding transactions refuses with the
repair; a missing ledger refuses with the repair. The ledger is untouched —
the read-only legacy record, `Store.Record` alive to read it forever. 5
tests; suite 868 green.

**P3 (2026-08-15): PASS.** The vendor left the way the moduledoc always said
one would — the file deleted, no word, no attribute, no space touched — and
the doc now records it happened. What the delete was hiding, done: the Exact
holder is SUPERVISED with the supervisor as its only starter (the first fix
kept the lazy start as a fallback and the two raced — a caller could take
the name inside the restart window and the supervisor then looped on
already_started until it took the tree down; single ownership closes both
that and the original silently-empty-tables failure); the exact provider is
the configured default (`config :blazie, :index`), so `Index.nearest` works
with no provider option; and derived-and-disposable is now proven where it
matters — a dead index comes back from the facts via the maintaining job,
tested across a holder kill. The parity gate survives the delete: a
test-local `HttpProvider` over the `Wire` fixture keeps "an HTTP vendor is a
module, same answers" proven with zero vendor code in the tree — and is the
template file for the day a whale tenant brings one back. Deferred
live-tripwire closed as moot. Suite 871 green.

**P4 (2026-08-15): PASS.** The walking skeleton first (its own commit):
`Blazie.Replication`, litestream in dir mode as a supervised Port — a tenant
file created at RUNTIME starts replicating within seconds with no per-tenant
config, `restore_if_missing/2` is the cold-open path with an honest refusal
when neither disk nor replica knows the name, `drain/1` is
deploys-reset-in-flight wired in rather than remembered. Then the three
halves that make it a phase. The R2 test (`replication_s3_test`,
`:object_storage`, the backup S3 test's env-var discipline, prefix-per-run)
runs the SAME lifecycle the `file://` test proves — shipped, wiped, hydrated
— against a real bucket; never required for the suite. Replication state is
facts now: `Replication.reading/1` is a Job riding the backup's own runner
into `$backup`, per database — `local_tx` (the blazie transaction), beside
`replicated_ltx` and `replicated_at` parsed from `litestream ltx`. Stated
plainly: the LTX txid is litestream's counter, NOT a blazie tx, so the two
are never compared as equals — the alarm shape is `local_tx` advancing while
`replicated_at` stands still, and a replica holding nothing reads zero
rather than nothing. And the drill drills SQLite worlds the way they are
kept: the pull is `litestream restore` into the same scratch dir (through
`Replication.restore/2`, the one restore path), the reopen is
`Store.SQLite`, and `ask_both/4` is the same comparison the ledger drill
runs — parameterized on the store, never forked. Conditions still open,
said out loud: the binary is a pinned v0.5-line dev build but `meta-dir` is
not set (the daemon defaults it beside the db), and the R2 request-budget
math waits for a real tenant count. Suite 878 green, and green under
`LEDGER_SYNC=true`.

**P4-cluster (2026-08-15): PASS, with the fence's limits stated.** Hydrate
and evict are both lifecycles now. Idle eviction is the World's own:
`evict_after:` rides the GenServer timeout, a world nobody has talked to
closes itself exactly the way `World.close/1` closes it — the process ends,
the file stays, the next open answers everything (worlds became `:transient`
children for this, which changes nothing about crash-restarts and everything
about staying evicted). Disk pressure is `Replication.evict/3`: close AND
delete the local file — REFUSED unless the replica actually holds the
world's LTX, because "R2 is truth" is a claim this function checks rather
than assumes, and deleting the only copy would be erasure by accident. The
round trip is tested: evicted, then hydrated back through
`restore_if_missing/2` with its facts intact (and probed first: a local
deletion does NOT delete replica data — the daemon logs an unregister error
and the LTX stays). The lease: this binary was probed for the upstream
distributed-leasing config the survey promised and DOES NOT EXPOSE IT (no
lease key in its config schema; the lease symbols in the binary belong to
its Azure SDK), so the fence is the honest minimum — a LEASE object at the
replica prefix, exclusive-create on `file://`, a second node refused with
the holder named, released on drain before the caller's `drain/1` returns,
kept across a crash so only the same node retakes it. NOT enforced, said
plainly: `s3://` starts unfenced with a logged warning — R2's conditional
writes are the production fence and are not wired; faking them with
read-then-write would only shrink the race, not close it. Sticky
tenant→node routing (who SHOULD write; the lease is who MAY) is the
remaining piece of this phase and is deliberately not started. Suite 884
green, conformance green under `LEDGER_SYNC=true`.

**P5 (2026-08-15): PASS — the default flipped.** `World.default_store/0`
with `:ledger_dir` set now answers `{Store.SQLite, dir:, sync:}`;
`checkpoint_every` is gone from the default because a checkpoint was the
file store's cure for replaying everything at open and SQLite opens by
reading nothing. The one-way door sits at the seam the World already owns:
`World.init`, before the store opens — a world whose `.sqlite` is absent
while a `.ledger` exists is migrated first (through `Store.Migrate`, so
through `Store.File`'s replay and every old shape it normalizes), logged,
serialised by construction since only one init ever runs per name. Proven
with hand-written old-shape ledger bytes: the migrated world answers
identically, resumes its tx counter, and never migrates twice — the
`.sqlite`'s presence is the door closing. `World.exists?/1` answers true
for either file, because a name is taken by its facts, not by which engine
holds them. `store_default_test` updated deliberately; and
`storage_layout_test` — the file that exists because a silent layout change
once left a node green beside 791KB of invisible facts — now pins BOTH
suffixes: `.ledger` forever (the migration door finds pre-flip disks by
that exact name) and `.sqlite` as the layout the replicator's pattern
watches. Memory default unchanged. Suite 888 green, and the conformance +
default files green under `LEDGER_SYNC=true`.
