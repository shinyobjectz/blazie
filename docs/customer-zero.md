# Customer zero: what blazie needs before socialite can run on it

*Written 2026-08-14, from both trees as they stand. Every claim about either
codebase names the file it came from.*

The question this answers: if socialite's backend were rebuilt from scratch
with blazie as its application infrastructure, its agentic infrastructure, and
its vector/graph infrastructure — socialite as blazie's first real customer —
what does blazie need to be ready, what does it already have, and what should
it refuse to build?

The two systems are close relatives. Both are Elixir/OTP. Both treat
provenance as structural rather than conventional, both draw the fabrication
fence at data access rather than at syntax, and both write refusals as data
with the repair attached. Socialite's `CLAUDE.md` ground rules read like
blazie doctrine because they largely are the same doctrine, arrived at
separately. That kinship is why the question is worth asking — and why the
gaps that remain are gaps of scale and integration, not of philosophy.

---

## 1. What socialite's backend actually is

Socialite is a research-and-reporting product for social media: it connects a
tenant's platform accounts, sweeps what they hold into a shared world-fact
cache plus tenant-private stores, runs agent Tasks that research and write
cited Dossiers, and draws an Atlas — a grouped, queryable picture of what the
workspace holds. Four components carry that.

### Nexus (`nexus/`, Elixir/OTP on Fly, Postgres)

The control plane and system of record. Its jobs, each with a module that owns
it:

- **Thread lifecycle** (`lib/nexus/threads.ex`, `threads/thread.ex`): a
  Thread is a user↔agent session; a Task is one run under it; a Plan is what
  the agent proposes after cheap recon and the run *parks on* until a human
  approves — alignment buys the bigger budget. Every event a client watches
  goes through one `emit/3` that writes and broadcasts in a single step, so
  transcript and live stream cannot disagree (v1 polled a table while the
  socket sat unused).
- **Run dispatch** (`threads/run_task.ex`, `harness/fly.ex`): a Task is an
  Oban job — a *row*, not a process — because v1 held runs in Durable Object
  memory and lost three measurement rounds to deploys. The worker creates one
  Fly microVM per Task, hands it the brief in the environment, and its job
  ends at `{:dispatched, machine_id}`. Fire-and-ack, no held connection:
  everything after the ack arrives as Events pushed the other way, so a lost
  machine costs the run, never the transcript.
- **The Gateway** (`lib/nexus/gateway.ex`, `gateway/limit.ex`,
  `gateway/book.ex`): the one credentialed door to everything outside. Vendor
  rate limits are per *account*, not per tenant, so the bucket must see every
  tenant's traffic — a per-run process cannot hold a limit that is global by
  definition, which is among the strongest reasons Nexus exists. `Book` is
  the cost seam: a verified price table (an unpriced vendor books *nothing* —
  a zero row would read as "measured, free"), one ledger row per call,
  per-org attribution, rollups as projections over the ledger.
- **The job plane** (`lib/nexus/jobs.ex`): agent-authored Python DAGs,
  validated by an AST-only parser (errors come back as
  `{line, description, repair}` for the agent's repair loop), stored as
  Postgres rows and materialized to the folder the Gust engine loads.
  DAG names are guarded because they become Quantum job atoms.
- **Sweeps** (`lib/nexus/sweep.ex`, `sweep/reader.ex`): the shared write
  path. A per-platform reader returns four separated things and the sweep
  writes each to exactly one place — public `rows` to the Graph, the org's
  `holding` to the Atlas, private `readings` (numbers) and `passages` (text)
  to tenant-scoped stores. The reader cannot leak private data into the
  shared pool because it never calls a write function at all. Cursors advance
  only after writes land.
- **Connections** (`lib/nexus/connections.ex`, `lib/nexus/vault.ex`): OAuth
  tokens for tenants' platform accounts, encrypted at rest, spendable only
  through `call/4` — no function returns a token. **Hints**
  (`lib/nexus/hints.ex`): webhooks may only make a sweep run *sooner*;
  polling is the backbone, so unplugging every webhook loses latency and
  nothing else.
- **Research** (`lib/nexus/research.ex`): one objective, every source at once
  — workspace holdings, the shared cache, live web, live social, brand facts
  — all answering in one `Document` shape so citations mean the same thing
  regardless of source. Round-robin interleave, no invented cross-source
  score. Live reads are written back to the shared Graph fire-and-forget.

### The Harness (`harness/`, Python, Mellea, one microVM per Task)

The agent runtime. The brief arrives in the environment (no inbound path at
all — Fly's IPv6-only 6PN made reaching in cost hours; outbound worked first
try), and every answer leaves as an Event to Nexus.

- **Checkpointing** (`checkpoint.py`): the run's state lives in Nexus after
  every turn, hooked through Mellea's `Compactor` seam — the machine is
  designed to be killable. Context is assembled per call, never accumulated
  (`_session.py`: no long-lived session; Mellea's `ChatContext` corrupts
  under concurrent writes).
- **Typed laws** (`contract.py`, `verdict.py`): the contract exists because a
  run once answered a research brief from training memory and still settled
  `done`. Laws are typed objects with stable names and versions; the verdict
  runner never raises — its job is turning failure into data with a name.
- **The judge** (`judge.py`): grounding checks against a hosted model.
  Instructive economics: the Granite Switch GPU service was sunset 2026-08-12
  after a gold-labelled benchmark — f1 0.86 at $82.94/month on H100 lost to
  f1 1.00 at ~$0.0007/run on a hosted model. Citation offsets are *found in
  the text* by string matching, never trusted from the model: an invented
  offset looks like a receipt.
- **The Dossier** (`dossier.py`, `nexus/lib/nexus/threads/dossier.ex`):
  executed, never typed. The body is source plus everything its code produced
  plus the data it ran over; it lives in R2, the row is the index. The
  fabrication fence is data access: the Cell that runs Dossier code is
  network-blocked and can only cite what was staged.
- **Tools as a library** (`tools.py`): code actions, not schema tables — v1
  paid ~4,600 prompt tokens per turn for a 107-route catalogue; a library has
  `help()`.

### MadEmb (`zoo/MANIFEST.md`, `serve/modal_scenes.py`, Modal, one T4)

The embedding suite. Five lanes: text (MiniLM-L12, 384d — captions,
transcripts, OCR text, comments), video retrieval (CLIP, one vector per
*scene*, scored as a max over scenes — X-CLIP was measured on the real corpus
and lost, 0.127 vs 0.245), video similarity (Perception Encoder, 1024d),
visual stills (DINOv3, 768d), audio (CLAP, 512d). OCR and transcripts are
text *producers*, not lanes — words go to the text space like any other
words. The OCR reader is a 34.5M CPU model that beat a GPU VLM 8x on speed
with near-identical text.

Two invariants Nexus enforces at its client seam (`lib/nexus/madem.ex`):
every space carries a **role**, and a `query_only` space may never assert
that two things are alike (`visual-siglip2`, at +0.039 over baseline, cannot
tell two videos apart — letting it draw a similarity edge would invent a
relationship). And **fetch and embed are one pass**, because signed CDN URLs
expired before a backfill ran — a design that embeds from a stored URL is
structurally broken, not merely slower. GPU seconds are metered per org.

### Graph / Atlas (Turbopuffer + R2)

The Graph (`lib/nexus/graph.ex`) is one shared pile of world facts that every
tenant's work fills and reads. **No function in it takes an org** — there is
no filter to forget, because nothing there has ever heard of a tenant. v1
held the same line with `requiresTenantFilter()`, defined and never called.
The Atlas (`lib/nexus/atlas.ex`) is what *this* org reached: holdings are
Postgres rows, a different store entirely, so no query against the shared
pile can return membership however it is written. `hydrate/1` flows one way.
On top: a view language (`atlas/query.ex`) with parser-as-validator, four
dimension kinds (`atlas/grouping.ex`), and precomputed semantic topics at
three nested resolutions (`atlas/topics.ex`) so grouping by what something is
*about* costs what grouping by platform costs.

---

## 2. What blazie already covers

Blazie is an immutable fact log: one row shape (id, attribute, value, tx, and
`by` — what produced it), append-only worlds, snapshots whose names travel
instead of their bytes, formulas that cannot reach outside, jobs as the only
door out, Lua as the whole authoring surface. The mapping, with honest
maturity notes — a thing that exists with one test has not carried load.

| Socialite workload | Blazie construct | Maturity |
|---|---|---|
| Org tenancy, Atlas-vs-Graph split | Worlds + Studios + `Authority` grants | Shape complete; one cluster's mileage |
| Thread/Task runs, checkpointing | `Run` — turns as facts, resume is a query | Tested incl. live; no production load |
| Oban + Gust job plane | `Job` + `Job.Runner` — the world is the queue | Solid single-node; no DAGs, no fairness |
| contract.py laws + judge | `Attribute` requirements + `Job.Generative` | Same doctrine, tested, live-tested |
| Harness react loop, tools | `Coding` + `Tool` + `Directive` + sandbox | Young; end-to-end tests exist |
| Dossier fence | The formula/job line itself | The strongest thing in the tree |
| R2 Dossier/media bytes | `Blob` — content-addressed references | Shape right; untested at scale |
| Spend/metering | `Spend`, `fuel_spent` facts | Records only; no prices, no rollups |
| Vitals/observability | `Vitals`, `Storage`, `Otel` | Facts + one span kind; no dashboards |
| MCP for tenant agents | `web/lib/control/mcp.ts` + remits | Genuinely good shape; low mileage |

**Tenancy.** A tenant is one or more worlds; sovereignty is decided at write
time by which world a fact went into, and authorization is which worlds a
caller may name (`lib/blazie/authority.ex`) — checked on *every* operation,
because a snapshot name is a plain map a caller can forge
(`surface/authorize.ex`). A Studio is a set of worlds plus one token that may
name exactly those, refused at the cluster's own `$authority` rather than
filtered by the control plane (`web/lib/control/clusters.ts`, `remit.ts`).
This is structurally the same answer as socialite's Graph/Atlas split — the
shared cache is a world no tenant token names; a workspace's holdings are the
tenant's own worlds — and it is *stronger* than v1's forgotten filter for the
same reason `Nexus.Atlas.scoped/1` is: the boundary is where the write went,
not a clause someone remembers.

**Runs.** `lib/blazie/run.ex` is the Harness's `checkpoint.py` made
unnecessary. A run's turns are facts; resuming is reading them back into the
shape `converse/5` takes; forking opens the parent's snapshot under a new id
with nothing copied; compaction *adds* a summary fact and touches nothing.
"A run survives a deploy" needs no machinery because the process was never
where the run was. Socialite built exactly this by hand against Nexus —
blazie gives it as a property of the substrate. On top sit trajectories,
`Refinement` (an agent may improve only what a thing *says about itself*,
never its authority — the bound is the safety argument), and
`Formula.Learned` (repeated identical tool calls harvested as examples for a
verified generated formula). Socialite has no equivalent of the last two;
they are a reason to move, not a gap to close.

**Jobs.** Cadence, runs and failures are ordinary facts; the runner reads
the world each tick, so a restart needs no reconciliation
(`lib/blazie/job/runner.ex`). Backup, the restore drill, vitals and storage
readings are all just jobs — the pattern socialite would use for sweeps.
`Job.Generative` is the sample-until-requirements-hold loop that `verdict.py`
plus `write_strategy.py` implement in Python, with the same rule: a rejected
sample is not written, a total failure is written with its reasons.

**The agent surface.** `Coding` (`lib/blazie/coding.ex`) is a react loop
whose tools are Lua facts, whose prompt is assembled from declarations (so it
cannot drift and is refinable), and whose writes pass both the vocabulary
check and the requirements before landing. `Directive`
(`lib/blazie/directive.ex`) bounds effects to a registry and records both
what was asked and what came of it — what socialite's Event stream records by
convention, blazie records as refusable facts. Foreign code runs as WASI
under wasmex with fuel and a memory ceiling (`sandbox.ex`) — a real Python
interpreter has been run inside the fence (`test/sandbox_python_test.exs`).

**The MCP surface.** The control plane's MCP server
(`web/lib/control/mcp.ts`) is how socialite would expose agent access to its
own tenants: schema and handler are one object so drift is unrepresentable,
tool prose is generated from the ontology, nothing returns a credential, and
a grant carries a *remit* — a ceiling (`most` counts machines, not calls,
because a rate limit does not bound spend), a world list, an expiry, and
optionally a Studio to act as, with cluster operations forced to `none` for
Studio-scoped grants. This is further along than anything socialite has for
delegated agent access.

---

## 3. What's missing that a customer like socialite needs

Ordered by how much of Nexus's reason-to-exist each one is.

**Backpressure, fairness and account-wide limits — Nexus's whole job.**
Blazie has no rate limiter anywhere. `Job.Runner` runs everything due;
`Model` calls providers with no bucket; nothing arbitrates two Studios
contending for one vendor. Socialite's Gateway exists precisely because a
vendor limit is per account and must see every tenant's traffic — on blazie
today, every tenant's jobs would hit a vendor independently until the vendor
rejected the whole account. Needed: a per-vendor bucket at the one place
calls already pass (`Model` and whatever job-http door emerges), fairness
across worlds when the bucket is contended, and refusals that carry the
retry-after as the repair. This is infrastructure blazie must own; it cannot
be an integration.

**Vector search at corpus scale.** Blazie's `Symbol` has the right
*discipline* — a space declared on the attribute travels with every vector,
cross-space comparison is refused, which is exactly `Nexus.Madem`'s role
invariant — but search is one exact pass over the resident snapshot, measured
at ~1s for 50k vectors serial (`lib/blazie/symbol.ex`). Socialite's corpus is
260,527 tracked deals across five spaces; Turbopuffer serves filtered ANN
plus BM25. The moduledoc's own position — "an index is a formula the engine
writes for itself, and it should not write one until measurement says to" —
has now been measured against customer zero's numbers, and the answer is: it
must exist, and it should be an external index behind a seam (§5), not a
homegrown ANN.

**Memory residency and store scale.** Every fact is held resident in every
node that opened the world (`lib/blazie/blob.ex` states this as the reason
blobs exist). A world holding socialite's readings — per-ref, per-metric,
per-sweep time series — grows without bound and lives in RAM. The `Store`
seam was built for exactly this ("a file on disk and an LSM on object storage
implement the same three functions", `store.ex`), but the LSM/paged store
does not exist, and reading from disk unindexed measured a thousand times
slower. Append throughput is fine — 2–5µs per transaction flat to two
million facts, a 120–200k txn/s serial ceiling (`.research/write-throughput.md`)
— residency is the wall.

**Multi-node, and running work elsewhere.** One cluster is one UpCloud
machine; `Cluster` only guarantees one-world-one-owner and says distribution
is deliberately not implemented (`cluster.ex`). Socialite's topology is a
control plane plus N short-lived agent machines plus a GPU service — the
compute never lives where the facts live. Blazie runs all guest code
in-process (Luerl, wasmex). What is missing is not consensus — worlds owned
by one writer make that the wrong problem — it is *dispatch*: a way to run a
brief on a machine that is not the cluster and take its answers back as
writes, which socialite's fire-and-ack pattern (`harness/fly.ex`) already
shapes. §5 argues this is an integration seam, not a subsystem.

**DAGs and job dependencies.** A blazie job has a cadence; it has no
upstream. Socialite's job plane is authored DAGs with dependencies,
triggerable, surviving deploys as rows. The world-is-the-queue design can
carry "run after" as facts (a job whose `due?` reads another job's last run),
but nothing packages that, and agent-authored jobs need what
`Nexus.Jobs.author/1` has: a validating parser whose error is the product.

**Migration and backfill tooling.** Blazie's position — "the refusal is the
migration engine" — answers schema evolution, not arrival. Customer zero
shows up with Postgres tables, a Turbopuffer namespace and an R2 bucket, and
needs bulk import: idempotent (socialite's sweeps key on canonical refs and
re-run to repair — the importer needs the same property), resumable,
cursor-after-write, at millions of facts. Nothing in the tree does this, and
the sweep contract (`sweep/reader.ex`) is the design to copy: a reader
returns separated things, the importer decides where each goes.

**Query capability, honestly stated.** The Atlas view language filters in
SQL over indexed columns and groups in Elixir; a fact log's `each{}` is a
scan of residents. Blazie has sort orders inside the world and nothing else.
For workspace-scale worlds (thousands of holdings) Lua-over-snapshot is fine
and is the design; for readings-scale aggregation ("impressions by week by
platform for a year") it is not, and pretending otherwise would be the
`requiresTenantFilter()` of performance. Either derived rollup formulas
(incremental maintenance is what the shapes decision in `DESIGN.md` §8
preserved) or the honest answer: analytics tables are a projection a job
maintains somewhere queryable.

**Per-tenant billing.** `Spend` records tokens and deliberately does not
refuse (`spend.ex`) — same doctrine as socialite's `Book`, which observes and
never eats the completion. But Book has the half blazie lacks: a verified
price table with sources and dates, per-org attribution on every booked call,
and rollups as projections. For a substrate whose customers have customers,
"what did this Studio cost this month" must be a query. The facts
substrate makes this easy; nobody has written it.

**Client SDKs.** Blazie speaks HTTP+Lua, plus a Go CLI and a TypeScript
console client (`web/lib/blazie.ts`). Socialite is Elixir and Python. An
Elixir client (Nexus calling blazie in-VM or over the wire) and a Python
client (the Harness's one durable place to checkpoint) are table stakes —
both thin, both caching on `{name, source}` since an answer at a name never
changes, which is the selling point and needs a client to demonstrate it.

**Observability beyond spans.** `Otel` emits one span kind (model calls),
by hand, no SDK, no propagation — stated plainly in its moduledoc. Vitals are
facts with no exporter. A customer running production wants: request-level
traces, a metrics projection something like Prometheus can scrape, and
alerting on the facts that already exist (`proven_at` stops advancing is
*the* drill alarm, and nothing watches it). The facts-first design is right;
the missing piece is one job that projects facts outward, which is cheap and
should stay optional.

---

## 4. Smaller common pitfalls

The paper cuts every early customer hits. Most of these blazie's own code
already records as measured findings; the work is closing them, not
discovering them.

- **Memory store by default.** Without `:ledger_dir`, `World.default_store/0`
  answers `Store.Memory` and everything dies with the node — `run.ex` says
  plainly that a run in a memory world "is not a defect in a run, and is
  indistinguishable from one if nobody says so first". A production boot with
  no `LEDGER_DIR` should refuse or shout, not default. Same for `KEY_DIR`:
  keys on an ephemeral disk erase everybody on redeploy (`blazie.ex`).
- **Durability defaults off, and every test runs with it off.**
  `LEDGER_SYNC=true` is opt-in; `.research/failure-modes.md` principle 5: a
  flag no test sets is an untested path.
- **The confirmed-findings list (C1–C12).** Twelve failure modes were
  reproduced against the working tree on 2026-08-13
  (`.research/failure-modes.md` §0). The worst for a customer: a snapshot
  name pinned to a future transaction silently means "everything so far", so
  the central answers-forever claim is falsifiable today (C1); erasure does
  not reach the formula cache or any client that followed the
  cache-forever advice (C10); a zero-filled tail makes a ledger permanently
  unopenable because CRC32 of empty is zero (C12); cache eviction silently
  stops encrypting (C4); corruption and lawful deletion both read `:erased`
  (C5); backup retention keeps every pre-erasure key-store version, making
  crypto-shredding controller-reversible for the retention window (finding
  5). These are known, scripted, and must be burned down before any tenant
  data arrives.
- **Token rotation.** A cluster's founding token and each Studio's token are
  minted at provisioning and there is no rotation flow — the deployment notes
  already say tokens need rotating. Grants are revocable facts
  (`authority.ex`), which is the mechanism; what's missing is the operation
  that mints a successor and retires the old fingerprint without a
  reprovision.
- **Reasoning-model timeouts.** Measured: a Workers AI model took over a
  minute on a single proposal, and the provider's timeout refusal says so
  (`model/provider.ex`). Every generative job a customer declares will hit
  this; the repair text is good, the default deserves revisiting per-provider.
- **WASI's absences.** The sandbox has no sockets, no subprocess, no
  filesystem — by construction, which is the point — but that means no pip,
  no native wheels, no shelling out. A Python guest is the interpreter and
  its stdlib (`test/sandbox_python_test.exs`). And fuel is the *entire* kill
  switch: a NIF runs to completion, no signal reaches it, so an unfueled
  infinite loop never returns (`sandbox.ex`). Customers will file both as
  bugs unless the docs say them first.
- **Luerl performance.** No automatic collector: fifty thousand tables built
  and *discarded* still exhausted the heap until the binding grew a sweep at
  the iterator (`lua/binding.ex`). Walking a large world is exactly the
  table-per-iteration shape — now measured: a Lua `each{}` aggregation over
  50,000 readings costs **1,127ms per query** (~22µs per entity), which is
  the ceiling a query author designs against. The repair for aggregation is
  `Blazie.Rollup` (a projection a job maintains — 231ms once, re-firing on
  change, sub-millisecond reads; the spike and the losing design's verdict
  are in its moduledoc). Also `pairs` order is unspecified, so anything
  order-sensitive must sort — `facts/1` already does.
- **Cold start and teardown of tunneled clusters.** A cluster is reachable
  only through cloudflared dialing out, ordered so nothing irreversible
  happens before the way in exists (`web/lib/control/opening.ts` — every
  check there was paid for by a failure), and tunnels with live connections
  take minutes to drain on removal. Fine for a person; an agent on a remit
  will hit the in-between states constantly. **Measured 2026-08-14 on a real
  provision (uk-lon1, 1xCPU-2GB): request→reachable was 697s, and the split
  is the finding — UpCloud machine provision+boot was 671s while the entire
  blazie install *including the docker image pull* was 13s.** So the earlier
  assumption that image caching is the cold-start lever is wrong: caching the
  image saves ~13s of a ~12-minute wait. The real levers are a warm pool of
  pre-booted machines, a faster plan/zone, or keeping clusters long-lived
  rather than on-demand — none of which is image caching. One sample, but a
  measured one, and it points somewhere different than the guess did.
- **Generated-surface budgets.** Socialite's rendered vocabulary skill
  already exceeds montology's 24k disclosure budget, carried as a known gap.
  Blazie's MCP tool prose is generated from the ontology (`mcp.ts`); as the
  vocabulary and remit surface grow, the same ceiling arrives. Decide the
  disclosure strategy (progressive, like `tools.py`'s library argument)
  before the surface is big, not after.
- **One writer per world.** Appends serialize through the world process. A
  chatty agent writing turn-by-turn shares that lane with a sweep writing
  thousands of facts. The ceiling is high (120k+/s) but per-world; the fix
  when it bites is more worlds, and tenant design should say so up front.
  The topology rules below are that "up front".

### Worlds topology — the rules a tenant designs by

Stated here because every number in them is measured, and a topology chosen
before the numbers is a topology chosen twice.

**The measured constants.** Appends serialize per world at 2–5µs per
transaction, flat to two million facts — a 120–200k txn/s ceiling *per
world*, not per node (`.research/write-throughput.md`). A resident fact
costs ~241 bytes of RAM, 87% of it the three sort orders; about a million
facts per world before stalls bite, six million before a 4GB box does
(`store.ex`). Until the paged store lands, `resident:` bounds the world's
working set but the file store still holds everything, so it saves 63% of
the bytes rather than 99%.

**Rule 1 — split by writer, not by topic.** Two things that write at the
same time belong in different worlds: an agent's turn-by-turn run and a
sweep landing thousands of facts share nothing but the lane they would
contend for. Reads compose across worlds for free (`Snapshot.open/1` takes
a list; `also:` on the wire); writes never do. When in doubt, give the
chatty writer its own world.

**Rule 2 — split when the fact count has a different growth curve.**
Holdings grow with the workspace (thousands); readings grow with time ×
metrics (millions). A world mixing both inherits the worst curve's memory
bill for the smaller set's queries. Time-series-shaped data gets its own
world per shard — and until the paged store exists, readings-scale data
should not land at all (§3).

**Rule 3 — the tenant boundary is a world boundary, always.** Sovereignty
is decided at write time by which world a fact went into. A world shared
by two tenants "for efficiency" reintroduces the filter this design exists
to not have. Efficiency comes from Rule 1, never from sharing.

**Rule 4 — erasure granularity is subject granularity, but blast radius is
world granularity.** Destroying a world (close + delete the file) is the
only bulk deletion there is; anything finer is per-subject crypto-shredding.
Data with a retention story different from its neighbours wants its own
world so the retention story stays executable.

**The shape socialite lands on under these rules:** one shared Graph world
(one writer: the sweep pipeline), one Atlas world per org (writer: that
org's jobs), one world per agent run or per Thread (writer: the run), and
readings deferred to the paged store, then sharded by time window.

---

## 5. Big hurdles to deliberately NOT build — first-class integrations

Blazie's own table of things it said no to (`DESIGN.md` §9) is the right
instinct. For customer zero, five more belong on it — each with the seam
named in blazie's vocabulary, and with the standing rule enforced: **vendors
are not vocabulary.** The tree already has three vendor shapes to reuse — a
provider module (`Blazie.Model.Provider`: "new endpoints are modules, not
branches"), a target module (`Backup.Target`), and a control-plane vendor
file (`upcloud.ts`: "adding a second vendor means another file this shape,
not another word").

**Vector search — Turbopuffer or similar.** Do not build ANN. The seam:
`Symbol` keeps the vocabulary (space, role, refusal across spaces); an
external index is a *materialization a job maintains* — the engine's own
framing, "an index is a formula the engine writes for itself", carried one
step further to an index a job writes outward. Reads go through a behaviour
shaped like `Model.Provider` (`search(space, vector, filter, k)`), and the
door sits under the Gateway-shaped limiter from §3 because socialite already
learned that the read layer must not be the exception
(`nexus/gateway.ex`: `:turbopuffer` is a door for exactly that reason). What
must not leak: no vendor name in any attribute, space, or word — a space is
`potion_256`, never `turbopuffer_*`. The index is derived and disposable; the
symbols in the world remain the record, so a vendor swap is a re-materialize.

**GPU embedding and inference — Modal.** Do not build model serving. The
MadEmb pattern is the integration: a customer's own suite (their models,
their bake-offs, their T4) reached as a job through the provider behaviour's
`embed` callback, with two blazie-side obligations copied from
`nexus/madem.ex` — the space's *role* is stated by the suite and enforced at
the seam, and fetch-and-embed happens in one pass because staged URLs expire.
GPU seconds are booked per Studio at the same cost seam as tokens. Blazie
contributes the facts, the metering, and the refusals; the GPU is the
customer's or Modal's.

**Cloudflare — already half in, finish it as a seam.** Tunnels, the Pages
control plane, and a Workers AI provider (`model/provider/cloudflare.ex`)
exist. R2 belongs behind the `Blob`/`Backup.Target` shape — socialite's
`r2.ex` is the reference for why object storage is its own seam and not a
Gateway door (S3 auth is a signature, not a header; the account-limit failure
mode doesn't apply to your own bucket). AI Gateway slots in front of
providers as configuration, not vocabulary.

**Retrieval vendors — Exa, Parallel, Brave.** Do not build search. The shape
to copy is `Nexus.Research`: capabilities name what they do, never who
provides it, every source answers in one citable document shape, round-robin
rather than an invented cross-source score. In blazie's terms these are
declared `Tool`s (jobs with `describe` and `takes`) whose vendor appears only
inside the tool's source or a provider module — an agent composes research
without learning a vendor exists (`harness/capabilities.py` says exactly
this).

**Elastic compute — Fly, UpCloud.** Do not build a scheduler fleet. The seam
is a **directive**: a tool answers "dispatch this brief", the runtime — whose
registry is the bound on an agent's reach (`directive.ex`) — provisions
through a vendor module, and the remote machine reports back as ordinary
writes under a token whose grant names exactly the worlds that run may touch.
That is socialite's fire-and-ack dispatch plus blazie's remit, and both
halves already exist separately: `harness/fly.ex` proves the protocol shape,
`remit.ts` proves the credential shape. What was asked and what came of it
are facts under the run, so a vanished machine is a visible gap, not a
mystery.

The test for every one of these: `onto check` stays clean. If an integration
wants a word, it is trying to become a subsystem.

---

## 6. Preparation sequence

Phased, one verdict gate each — spike before commitment: one proven site
before any cross-cutting build. Phases 3–5 order by how much of Nexus each
gap replaces; nothing later starts until its gate has a written verdict.

**Phase 0 — make the claims true.** Burn down C1–C12: bounds-check snapshot
names, make erasure reach the formula cache (settle the doctrine first —
finding 4 says the tests encode whichever answer is chosen), handle
zero-filled tails, fix eviction-drops-encryption, refuse to boot production
without `LEDGER_DIR`/`KEY_DIR`, decide the backup-retention/erasure conflict.
*Gate: the claims suite passes with fault injection — damage shapes varied,
not just process SIGKILL — and `LEDGER_SYNC=true` is exercised by CI.*

**Phase 1 — SDKs and the spike site.** Elixir and Python clients, thin,
caching on names. Then rebuild **one** bounded socialite subsystem on blazie
as the proven site — Hints is the candidate: small, self-contained, and it
exercises tenancy (per-org worlds), a job (the sweep-advance), idempotency
(redelivery collides harmlessly), and the wire. *Gate: the subsystem runs
against real traffic shape with a verdict written — what was easier, what
fought back, what the SDK was missing.*

**Phase 2 — the scale spine.** The paged/LSM store behind the existing
`Store` seam so residency stops being the wall; the bulk importer with the
sweep contract's shape (separated outputs, cursor after write, idempotent by
canonical ref). *Gate: socialite's Graph-scale corpus imported — millions of
facts — with append at the measured ceiling, open-world RAM bounded, and a
workspace-scale query under interactive budget.*

**Phase 3 — limits, fairness, metering.** The Gateway-shaped door:
per-vendor buckets where calls already pass, fairness across Studios under
contention, the price table with sources and dates, per-Studio booking as
facts with rollups as projections. *Gate: two Studios contending for one
limited vendor, fairness measured, and "what did this Studio cost this
month" answered by a query whose numbers reconcile with the vendor's bill.*

**Phase 4 — the vector seam.** The index-provider behaviour, a Turbopuffer
module behind it, the maintaining job, role enforcement at the seam, the
embed door to a Modal suite. *Gate: one Atlas capability — topics refit or
kind-scoped retrieval — reproduced on blazie symbols at recall parity with
the manifest's measured numbers, with the vendor swappable in a test.*

**Phase 5 — the agent runtime.** Runs as the checkpoint store (retiring
`checkpoint.py`'s job), the dispatch directive with remit-scoped write-back,
requirements as the law registry, the judge as a generative job. *Gate: one
real Task end-to-end — brief, plan, park, approve, research, Dossier — with
the fence held by data access, every turn a fact, and a mid-run machine kill
that loses one call, not the run.*

Then, and only then, the cross-cutting question — moving Nexus's remaining
organs — gets asked, with five verdicts in hand instead of a hope. If any
gate fails, the honest outcome is the one this document was written to make
cheap: socialite keeps that organ, blazie keeps the seam, and the seam is
excellent.
