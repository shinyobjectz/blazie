# Distribution

*Design research, 2026-08-13. Nothing in this document is built.
`LazyRiver.Cluster.distributed?/0` returns false, there is one node, and this
exists so that stays a decision somebody took rather than a task that keeps
being postponed.*

## The short answer

**The unit of distribution is the ledger, and ledger-per-node placement is
enough.** A ledger is already an append-only sequence with exactly one writer,
and doctrine 8 already says a fact belongs where it was written. Nothing Lazy
River promises today needs consensus, and the reason is structural rather than
lucky: there is no operation that writes to two ledgers, so there is no
cross-ledger atomicity to preserve.

**A cross-node snapshot is coherent.** It is exactly as coherent as a
cross-ledger snapshot already is on one node — which is to say: stable, and
never atomic. A snapshot name was never a point in a global order. It is a
vector of independent per-ledger positions, each indexing an immutable sequence
owned by one writer. Which machine that writer runs on does not enter into it.

**What breaks the guarantee is replication, not distribution.** Placement
cannot make a name answer differently. Asynchronous replication with automatic
failover can, and does so permanently, in a system whose clients are documented
to cache forever and never invalidate. The option that sounds safest — put a
replica behind each ledger — is the only one that attacks the load-bearing
claim directly.

**And the motivation is probably not availability.** The backup job already
covers "the disk died" at RPO = `BACKUP_EVERY`. What a second node buys, over
and above what is already there, is a shorter deploy window and a way to hold
more tenants than one machine holds — and the first of those is blocked on the
*store* being shared, not on the cluster existing. Section 6 works through the
failure list one at a time.

---

## 1. Where the tree actually stands

Eight findings. The first was measured on this machine today; the rest are read
off the code. They matter because most of them mean the current position is not
"one node, ready for a second" but "one node, and a second node would be a
second database sharing a name registry".

### 1.1 `:global` prevents a fork only *within* a partition — measured

`LazyRiver.Cluster`'s moduledoc says a claim exists so that "a claim somebody
else holds is refused with its repair, rather than quietly forking", and puts
`:global`'s netsplit behaviour aside as "a weakness of *distribution*, which is
not here yet". Both halves are true, and together they mean the failure the
module exists to prevent is exactly the failure it does not prevent from the
moment a second node exists.

Measured on OTP 29 / erts 17.0.5, three nodes, `prevent_overlapping_partitions`
disabled so the observer survives the split:

```
n1 register (whole cluster): :yes
n2 register (whole cluster): :no        <- refused, as designed

--- partition n1 | n2 ---
n1 register during split:   :yes
n2 register during split:   :yes        <- both nodes now own "tenant-7"
n1 whereis: #PID<18766.100.0>
n2 whereis: #PID<18767.98.0>

--- heal ---
n1 whereis after heal: #PID<18766.100.0>
n2 whereis after heal: #PID<18766.100.0>
pid1 alive: true
pid2 alive: false                       <- one ledger process killed
```

Two ledger processes accepted appends under one name for the length of the
split. On heal, `:global`'s default conflict resolution killed one of them. Its
facts are on its own disk, unreachable under that name, and the survivor holds a
different history at the same transaction numbers. That is the silent fork,
achieved through the mechanism intended to prevent it.

With the OTP 25+ default (`prevent_overlapping_partitions: true`), the first run
of the same script produced instead:

```
[warning] 'global' at node lr_a requested disconnect from node lr_c
          in order to prevent overlapping partitions
```

— `:global` responded to the partition by tearing down connections to nodes that
were perfectly reachable. That is the better of the two behaviours and it should
be understood for what it is: `:global` trades a fork for a wider outage, and it
makes that trade without being asked.

`:global` is a same-partition mutual exclusion. It is not a placement mechanism,
and it cannot become one, because it has no way to fence a process that comes
back.

### 1.2 There is no routing, so a second node is a second database

`Ledger.via/1` and `Ledger.local/1` address `LazyRiver.Registry`, a plain
`Registry`, which is node-local. `Ledger.open/2` on node B for a ledger owned by
node A returns `{:error, :owned_elsewhere}` and there is no other path that
reaches it. `Snapshot.find/2` calls `Ledger.find_at/3` on a via-tuple pointing at
the local registry.

So one node is not currently a deployment choice among several. It is the only
configuration in which the system answers at all. Everything below is
green-field.

### 1.3 `watch` is silently node-local

`Ledger.announce/3` uses `Registry.dispatch(LazyRiver.Watchers, name, …)`. That
registry is node-local, so an announcement never crosses a node. A subscription
registered on another node would join successfully, receive nothing, and never
error.

That is the worst failure shape in this repository's own taxonomy: a watch that
has stopped pushing is indistinguishable from a watch over data that has stopped
changing. `failure-modes.md`'s second cross-cutting principle — "a value that
two different causes can produce cannot be evidence for either" — applies
directly.

### 1.4 The keyring is per-node, so erasure is per-node

`LazyRiver.Keyring` is a GenServer registered under a *local* `name: __MODULE__`.
`Keyring.Local` keeps KEKs in a file under `KEY_DIR` on that node's disk, and
`Keyring.GCP` delegates `wrap`, `unwrap` and `destroy` to it — the KMS is touched
once at boot to unwrap a master and never again. So the thing erasure destroys
lives on one machine's disk under both keyrings.

`Erasure.erase/1` writes a tombstone and calls `Keyring.destroy/1`. On one node.
Consequences, stated plainly:

- Another node holding a copy of `KEY_DIR` keeps the KEK, and the subject is not
  erased there.
- Another node's DEK cache holds the *plaintext data keys* for up to
  `@cache_for` (15 minutes) regardless of what any KEK store says. `destroy/1`
  drops the local cache; it has no way to drop anyone else's.
- Doctrine 16's "erasure destroys the key" becomes "erasure destroys one of the
  keys", which is not erasure.

### 1.5 `$authority`, `$erasures` and `$backup` are single-owner ledgers

Each is one ledger, so each has exactly one owning node. Every `open`, every
channel join and every write consults `$authority`. Every keyring boot
reconciles against `$erasures`.

In a cluster those become cross-node calls on the hot path and single points of
failure for the whole cluster. Worse, the failure is quiet: `Keyring.forget_erased/1`
catches both a raise and an exit and returns the state unchanged, with the
comment "a keyring that cannot read tombstones must still open". On one node
that is right. On a node that can never read them, it means the keyring runs
permanently un-reconciled and says nothing.

### 1.6 The backup job clobbers itself across nodes

`Backup.copy_keys/3` writes each key file to the fixed object key
`keys/<file>` — in practice `keys/keks`. The supervisor starts the backup job
on every node that has `BACKUP_TARGET` configured. Two nodes therefore both
write `keys/keks` on their own cadence, whichever ran last wins, and the bucket
holds one node's KEKs.

A restore from that bucket is mass accidental erasure of every subject whose key
lived on the other node — indistinguishable, per `failure-modes.md` C5, from a
lawful deletion. Ledger segments escape by accident, because the object key
carries the ledger's filename; they stop escaping the moment two nodes hold the
same ledger, which is precisely what §1.1 shows a partition arranges.

### 1.7 Jobs would run once per node, not once per cluster

`Job.Runner` reads the ledger to find what is due and holds in-flight state in
its own process. `Job.run/4` writes the "it ran" fact *after* the work finishes,
so the cadence check is a query, not a lock. Two runners ticking on two nodes
both see the same job due and both run it.

A job is the one thing that reaches outside (doctrine 6), so a duplicate run is
a duplicate side effect: a second POST, a second model call, a second backup.
Nothing in the design currently makes a job cluster-singular.

### 1.8 The two confirmed name bugs get worse, not merely carried

`failure-modes.md` C1: a snapshot name is client-writable and a transaction
above the ledger's current one is accepted, silently meaning "everything, so
far". Distributed, a transaction number minted against one node's counter is not
merely unbounded — it is meaningless on another node, so a name becomes
ambiguous as well as unstable.

C2: `Controller.named/2` zips `Map.values/1` against the caller's argument order,
assigning each ledger somebody else's transaction. Across nodes it would assign
each ledger another *machine's* transaction. Both are prerequisites, not
consequences: there is no point designing distribution on top of a name that is
already wrong at n = 1.

---

## 2. The crux: what does "read at a transaction" mean across nodes?

This is the question the whole design turns on, so it gets answered rather than
gestured at.

### 2.1 The name was never a point in time

A snapshot name is `%{ledger => tx}`. Two different properties get bundled
together in the prose around it:

1. **Stability** — the same name answers the same facts forever.
2. **Atomicity** — the ledgers in a name were read at one common instant.

Lazy River has (1). It has never had (2), and does not claim it anywhere in
doctrine. `Snapshot.open/1` is:

```elixir
%__MODULE__{at: Map.new(ledgers, &{&1, Ledger.tx(&1)})}
```

— one `GenServer.call` per ledger, in sequence. A write landing in the second
ledger between the two calls is included or excluded by timing. That is read
skew across ledgers, and `failure-modes.md` already classifies it as a
**single-node** anomaly.

Crucially, nothing wants (2). There is no multi-ledger write: `Ledger.append/3`
takes one ledger, and `Controller.write/2` takes `"ledger" => name`, singular.
Doctrine 8 says a fact belongs where it was written, decided once at write time.
So there are no cross-ledger transactions for a cross-ledger snapshot to be
non-atomic about. Atomicity across ledgers would be a property with nothing to
protect.

**Therefore: a cross-node snapshot means exactly what a cross-ledger snapshot
already means.** Each component of the name is a position in an append-only
sequence with a single writer; each such sequence is immutable at and below that
position; the composition of immutable prefixes is immutable. Node placement
appears nowhere in that argument. The name is a vector clock that never needs
comparing, and vectors do not care where their components live.

This is the same answer Datomic gives. A Datomic database has its own basis-t;
several databases in one query have several, and Datomic offers no global
timestamp across them and no cross-database consistency guarantee. The
comparison is exact because the shape is the same.

### 2.2 So what does distribution actually cost?

Precisely two things, and they are both about `open`, not about `ask`.

**The skew window in `open` widens.** From a few microseconds (a local
`GenServer.call` per ledger) to a network round trip per remote ledger, and
under partition to unbounded. A wider window means read skew across ledgers is
more likely to be *observed*, not that a new anomaly appears.

**`open` can return a name that is behind.** If node B cannot reach the owner of
ledger A, it either blocks, or refuses, or returns a name with a stale
component. The third of those is not a snapshot violation — the name it returns
still answers the same thing forever — it is a **monotonic-reads** violation: a
client that held `{A: 9}` and then calls `open(["A"])` and receives `{A: 7}` has
watched time run backwards.

That is a real anomaly and a different one, and it has a cheap fix that is worth
naming now: `open` takes the caller's previous name as a floor and refuses to
return anything below it, with a repair naming the ledger that went backwards.
A session guarantee, twenty lines, and it does not need distribution to be
worth having.

By contrast `ask` at a fixed name is *more* robust distributed than `open` is,
because every component is already pinned. Its only new failure is
unreachability, and the correct response to unreachability is a refusal naming
which ledger could not be reached. It must never be a partial answer: a partial
answer at a name gets cached by the client forever, and there is no channel to
tell it otherwise.

### 2.3 What actually breaks it: replication

Placement cannot make a name answer differently. Replication can.

Consider ledger A with an asynchronous replica. Transaction 9 is appended, the
number 9 is returned to the writer, the primary dies before the replica has
received it, and the replica is promoted. Now:

- the name `{A: 9}` answers *fewer* facts than it did, forever; and
- once the new primary writes, transaction 9 is issued again to different facts,
  so the name answers *different* facts, forever.

In a mutable database that is a lost write. Here it is a lost write **plus**
permanent poisoning of every client cache and every `Formula.Engine` entry keyed
on that name — and `Formula.Engine`'s moduledoc states flatly that "there is no
invalidation here and there is no cache-coherence protocol, because there is
nothing to cohere." Async replication is the thing that creates something to
cohere.

The rule this produces is short enough to be a doctrine sentence:

> **A transaction number may not be returned until the facts it names are
> durable everywhere that could ever answer for that ledger.**

Which admits exactly two shapes. Either one node answers for a ledger and the
number is returned after a local fsync (placement, no replication), or a quorum
answers for it and the number is returned after quorum commit (Raft). There is
no correct middle. "Async replica, automatic failover" is the middle, and it is
the one option in section 3 that should be refused outright.

### 2.4 The restriction that falls out of doctrine 7

Doctrine 7 says the evaluator runs where the data is, and "a read is a pure
function of a snapshot, never a round trip to a second server to fetch what it
needs — which is what makes reading several ledgers at once cheap, and that is
what makes multi-tenancy possible without filtering."

Now put two ledgers of one snapshot on two nodes. Answering one question over
that snapshot requires either shipping the question to both owners and composing
the two fact sets somewhere, or shipping one owner's facts to the other. Both
are round trips to a second server to fetch what the read needs. The first is
cheaper and is still exactly what doctrine 7 refuses.

So the honest design consequence, and it is a real restriction:

> **Every ledger a caller may name in one snapshot must live on one node.**
> Placement is a decision about a *tenant*, not about a ledger.

A tenant is one or more ledgers (`led`); those ledgers move together or not at
all. Cross-tenant snapshots become impossible rather than merely discouraged —
which doctrine 8 arguably wanted anyway, since a snapshot spanning two tenants
is the shape a tenant filter exists to prevent.

The alternative is to relax doctrine 7 for the multi-node case and accept a
scatter-gather `ask`. That is a coherent choice; it is just a different system,
and it should be taken as an amendment to doctrine rather than as an
implementation detail of a routing layer.

---

## 3. The options

| | What it buys | What it costs | What it forbids | Work |
|---|---|---|---|---|
| **A. One node** (today) | Everything currently true stays true. No new failure modes, no new vocabulary, no consensus. | Availability is one machine's; RPO is `BACKUP_EVERY` (900s default); RTO is a manual restore on the least-tested path in the system. Capacity is one machine's. | More tenants than one box holds. Zero-downtime deploys. Regional residency. | 0 |
| **B. Ledger placement, `:global` claims, no replication** | Capacity across machines. Blast radius per node. Placement is the only new concept. Snapshot guarantee untouched (§2.3). | A partition forks a ledger (§1.1) unless the claim is replaced by a real lease. Every cross-node hop is a doctrine-7 violation unless a tenant's ledgers are co-placed. A node's death makes its tenants unavailable until a restore. | Cross-tenant snapshots. Ledger mobility (moving a ledger means moving its disk). | Routing in four operations, cross-node watch, cluster-singular jobs and keyring, backup key namespacing. Weeks. |
| **B2. Placement with a fenced lease** | Everything B buys, plus a partition cannot fork: a returning owner is refused by its stale token. Ledger mobility, and with a shared store, seconds-not-minutes failover. | Needs a lease store that is not the cluster (object storage, or a small Raft group holding *only* the placement map). Needs the fencing token threaded through every write. | Same as B. | B plus the lease and the token. Weeks, and the store work in §6 first. |
| **C. Primary/replica per ledger (async)** | A warm copy. Reads could be served locally. Sounds like HA. | **Breaks the central claim on every failover** (§2.3). Read-your-writes needs the primary anyway. Replica lag is a new unbounded quantity. | Nothing — and that is the problem: it forbids nothing and quietly withdraws the guarantee everything rests on. | Weeks, for a negative. |
| **D. Raft per ledger (`ra`)** | RPO zero for an acknowledged transaction. Automatic failover with no lost-write window. The snapshot guarantee survives, because a tx is only returned after quorum. | A transaction becomes a network round trip plus remote fsyncs instead of a local write. `tx` stops being a cheap counter. Membership, snapshotting and recovery become operational surface. Three machines minimum per ledger, or a shared Raft group per placement unit. | A one-machine deployment. Cheap writes. | Months. A genuine second implementation of `Ledger`. |
| **E. Global consensus / sequencer (FDB-shaped)** | One global transaction version; cross-ledger snapshots become atomic and cross-node ones trivially so. | Every read takes a read version from a central component — the exact round trip doctrine 7 refuses. The whole design's reason for existing goes away. | Doctrine 7. | Quarters. A different database. |

A note on option D and doctrine 18 ("prefer what we do not maintain"). `ra` is
maintained by the RabbitMQ team and is the right library if Raft is the answer —
that is not the objection. The objection is that adopting it means *we* maintain
per-ledger Raft cluster lifecycle, membership changes, and a recovery path, and
doctrine 18's own corollary asks what happens the year they stop. The library is
cheap; the operational surface it implies is not.

---

## 4. What a partition does

Assume option B/B2 (placement, no replication) unless stated. "Owner side" is
the side of the partition holding the ledger's owning node.

| | Owner side | Other side | Correct behaviour |
|---|---|---|---|
| **`ask` at a name** | Answers normally. | Cannot answer. | Refuse, naming the unreachable ledger and its owner. **Never** a partial fact set — a partial answer at a name is cached forever. |
| **`open`** | Returns a current name. | Cannot produce a name. | Refuse. Do not fall back to opening a fresh local ledger under that name — which is what `Ledger.open/2` does today when `:global` says nobody owns it, and under partition `:global` says exactly that (§1.1). This is the single most dangerous line of code in a distributed Lazy River. |
| **`write`** | Appends normally. | Cannot append. | Refuse with a repair. Under B this is guaranteed only by good luck; under B2 the stale token makes it structural. |
| **`watch`** | Keeps pushing. | Stops pushing. | Must **terminate the subscription with a reason** the client receives. A watch that goes quiet is indistinguishable from data that stopped changing (§1.3), and that is the failure shape this repo has already decided it will not ship. |
| **Keyring** | Can destroy locally; cannot reach the other side's KEK store or its 15-minute DEK cache. | Cannot reconcile against `$erasures` if that ledger is on the far side; fails silently today (§1.5). | Erasure must be refused, not partially performed, when any node that could answer for the subject is unreachable — and the refusal must say which. A partial erasure that reports success is a compliance failure, not an availability one. |
| **Backup** | Runs, and copies its own view. | Runs, and copies its own view, over the same `keys/keks` object (§1.6). | Cluster-singular, or namespaced per node **and** per node in the restore path. Whichever is chosen, `verify/1` compares one node's disk against the whole bucket today and would have to learn what a complete cluster backup even is. |
| **Authorization** | Works if `$authority` is here. | Every operation fails closed. | Failing closed is right. But it means one ledger's node is a cluster-wide availability floor, so `$authority` should be split per tenant and co-placed (§5.2). |

The general shape: under placement, a partition is an **availability** event for
the tenants on the far side and nothing more — *provided* the claim is a fenced
lease rather than a `:global` registration. With `:global`, a partition is a
**correctness** event, because both sides will happily open the ledger.

---

## 5. What would have to change

### 5.1 The four operations

**`open`** stops being "start a process locally" and becomes "resolve the owner,
and address it". Three changes:

- A resolver: name → owning node, from the placement map rather than from
  `:global.whereis_name/1`. `:global` answers "who has it running"; placement
  must answer "whose is it", which is a different question and the only one that
  is safe under partition.
- Refusal rather than local start when the owner is unknown or unreachable
  (§4).
- The C1 bound (a `tx` above the ledger's current one is refused) and the
  session floor from §2.2. Both are worth doing at n = 1.

**`ask`** needs no protocol change *if* a tenant's ledgers are co-placed
(§2.4) — the snapshot is entirely on one node, the evaluator runs there, and
the caller's node forwards a question and receives an answer, which is one hop
rather than a fan-out. If co-placement is rejected, `ask` becomes scatter-gather
and doctrine 7 needs amending first.

**`watch`** is the easiest of the four, because the BEAM does the work: run the
subscription process on the *owning* node and let it `send/2` to the
subscriber's pid, which is location-transparent. What has to be added is the
teardown story — a monitor across the node boundary and an explicit termination
message on `:nodedown`, so silence is never the signal.

**`write`** routes to the owner, and under B2 carries the fencing token so that
an owner returning from a pause is refused rather than appending into a history
someone else has continued. Note that `Ledger.append/3` runs the vocabulary
check *before* the `GenServer.call` — that check reads the ledger's own
attributes, so it must move to the owning node with the write rather than run on
the caller's.

### 5.2 Authorization

`Authority.may_name?/2` reads `$authority`, one ledger, one owner. Two options,
and the second follows the design's own grain:

- **Replicate `$authority` read-only to every node.** Grants are facts, so a
  node can cache at a name and never invalidate. The problem is direction:
  staleness is safe for a grant and unsafe for a revocation, and this is a
  security boundary, so the unsafe direction is the one that matters. It would
  need a revocation with a bounded propagation time, which is a new
  guarantee to state and test.
- **One authority ledger per tenant, co-placed with that tenant's ledgers.** A
  caller's grants live on the node that owns what those grants name, so
  authorization is always local to the thing being authorized and a partition
  takes the grants and the data out together. This is doctrine 8 applied to
  authority, and it removes a cluster-wide single point of failure rather than
  replicating one.

The second also fixes something already awkward: `$authority` is currently a
single global ledger holding every tenant's grants, which is the shared table
doctrine 8 exists to avoid.

### 5.3 Erasure

The hard one, because doctrine 16 is a legal obligation and §1.4 shows it is
currently a per-node operation.

"A key destroyed on one node is destroyed everywhere" requires exactly one place
where the key lives. Three ways to get there:

1. **KEKs into KMS, one key version per subject.** Correct and priced out — the
   `Keyring.GCP` moduledoc already does this arithmetic (about six cents per key
   version per month, ~$600/month at ten thousand subjects). It also introduces
   a destruction *delay*: KMS key-version destruction is scheduled rather than
   immediate, so "erasure is now" becomes "erasure is scheduled", which is a
   different sentence and has to be the one the docs say.
2. **The keyring becomes a cluster singleton**, claimed the way a ledger is
   claimed, with every node calling it to wrap and unwrap. Destroy is then a
   single-node operation again and is correct. Costs: a cross-node call per
   unwrap (mitigated by the existing 15-minute DEK cache), and a
   cluster-wide single point of failure for reading any sealed fact.
3. **One keyring per placement unit**, co-placed with the tenant whose subjects
   it holds. Same argument as §5.2, same shape, and it keeps erasure local to
   the node that holds the facts being erased — which is the only arrangement
   where "destroy the key" and "the facts become noise" happen on one machine.

(3) is the consistent answer under co-placement. Whichever is chosen, two things
have to be stated and tested rather than assumed:

- **The DEK cache is the erasure latency, cluster-wide.** Today `destroy/1`
  drops the local cache and that is the whole of "makes it now". With more than
  one node, every node that has read a sealed fact holds plaintext data keys for
  up to fifteen minutes after the KEK is gone. Either the cache is invalidated
  cluster-wide on destroy, or the documented erasure latency is fifteen minutes
  and says so.
- **A backup of `KEY_DIR` from a node that has not erased is a resurrection
  vector.** The tombstone-reconciliation story covers a *rollback in time*; it
  does not cover a *copy from a peer* that never had the tombstone applied,
  because reconciliation runs at keyring open and only against the tombstones it
  can read (§1.5).

---

## 6. Availability or durability — what a second node actually buys

Worth doing as a list, because the answer changes the recommendation.

| Failure | What covers it today | What a second node adds |
|---|---|---|
| Process or ledger crash | OTP supervision; restart in milliseconds, replay from checkpoint. | Nothing. |
| Node crash / VM restart | Supervisor tree restart, or the platform restarting the container; `LEDGER_DIR` is a mounted volume. Seconds to tens of seconds. | Nothing, unless the ledger can *move*, which needs a lease and a store the other node can read. |
| Deploy | The node goes and comes back. Tens of seconds of unavailability, every deploy. | Zero-downtime deploys — **but only with a shared store.** With local disks, moving a ledger means moving a volume. |
| Disk death | The backup job. RPO = `BACKUP_EVERY` (900s default), and note `LEDGER_SYNC` is off by default, so a returned transaction survives a process death and not a power loss. | Nothing that a shorter cadence and `LEDGER_SYNC=true` do not do more cheaply. |
| Machine death | Backup covers durability, not availability. Recovery is a restore — minutes to hours, on the code path `failure-modes.md` names as the least-tested in the system. | This is the real one. Placement plus a shared store turns a restore into a lease handoff. |
| Region death | Nothing. | Nothing, unless placement is region-aware, which is a further step. |
| Load / capacity | One machine's. | This is the other real one, and it is where placement is unambiguously the right tool. |

Two conclusions fall out.

**The store is the bottleneck, not the cluster.** Five of the seven rows above
are gated on whether a ledger's bytes are reachable from more than one machine.
`LazyRiver.Store` is already a three-function behaviour designed for exactly this
— its moduledoc says "a file on disk and an LSM on object storage implement the
same three functions, which is what keeps the storage decision a configuration
line rather than a rewrite". Doing that work first makes the distribution work
smaller *and* makes several of its benefits available without it.

**Durability is already cheaper to fix than availability.** If the honest answer
to "what keeps you up at night" is losing data, the fixes are `LEDGER_SYNC=true`,
a shorter `BACKUP_EVERY`, and — most of all — a *tested* restore. None of those
is a second node.

---

## 7. Recommendation

**Do not build consensus. Do not build replication. Build placement, and build
the store first.** In this order:

**0 — Fix the name.** C1 (refuse a `tx` above the ledger's current, with a
repair rather than a clamp) and C2 (`Controller.named/2`). Add the session floor
from §2.2. These are prerequisites: designing distribution on a name that is
already wrong at one node is designing on sand. They are also worth doing
whatever the answer to distribution turns out to be.

**1 — Tell the truth about `:global`, today.** Change `LazyRiver.Cluster`'s
moduledoc to say what §1.1 measures: `:global` is same-partition mutual
exclusion, it does not prevent a fork under partition, and OTP's default
mitigation is to disconnect reachable nodes. Add the netsplit test — the script
in §1.1 is thirty lines and runs in ten seconds. A test that proves the
limitation is worth more than a comment that describes it, because the comment
currently reads as reassurance.

**2 — Move the store to object storage.** The single highest-leverage piece of
work on this list, and it is not a distribution project. It converts "move a
ledger" from a volume migration into a lease handoff, and it collapses five rows
of the §6 table.

**3 — Then placement, with a fenced lease (option B2).** Ledger → node, held as
a lease with a monotonic token, the token threaded through every append so a
returning owner is refused rather than accepted. Object storage with conditional
writes is a sufficient lease store and avoids introducing a consensus system to
hold a map of a few thousand entries. With it: routing in the four operations,
cross-node watch, cluster-singular (or per-placement-unit) keyring and jobs,
and a backup that knows what a cluster is.

**4 — Adopt co-placement as a rule, in writing.** A tenant's ledgers move
together; a snapshot never spans a placement unit. This is what keeps doctrine 7
true, and it should be a doctrine row rather than a comment in a router.

**5 — Never replicate a ledger asynchronously.** If per-ledger RPO-zero HA is
ever genuinely required, the answer is `ra` per placement unit and it is a
months-long project that changes what a transaction costs. It is not an
incremental step from B2, and pretending otherwise is how C gets built by
accident.

The smallest step that buys real availability, stated on its own because it was
asked for directly: **a shared store plus a fenced lease** — steps 2 and 3.
Everything before that is honesty work, and everything after it is a different
system.

---

## 8. What we would have to give up

**By choosing placement over consensus:**

- *RPO zero.* An acknowledged transaction on a node that then loses its disk
  costs whatever the backup cadence is. If that is unacceptable, D is the only
  option and it should be chosen deliberately.
- *Automatic failover.* A dead node's tenants are unavailable until the lease
  expires and the ledger is reopened elsewhere — seconds with a shared store,
  a restore without one.

**By choosing co-placement (§2.4):**

- *Cross-tenant snapshots.* A question can never span two placement units. In
  exchange, doctrine 7 stays literally true and `ask` stays one hop.
- *Free ledger placement.* Ledgers stop being independently placeable, which
  costs the ability to put one enormous ledger on its own machine unless it is
  also its own placement unit. That is a scheduling constraint to state, not a
  contradiction.

**By choosing a fenced lease over `:global`:**

- *Zero dependencies.* `:global` is in OTP and costs nothing. A lease means a
  store that is not the cluster, and a story for what happens when it is
  unreachable. Doctrine 18 cuts both ways here: the lease store is something
  else to keep alive, but so is a bespoke split-brain resolver.

**Regardless of option, we give up these, and they should be priced:**

- *Erasure as a local operation.* Section 5.3 — it becomes a distributed
  operation with a stated latency, or a singleton with a stated single point of
  failure. There is no version where it stays as simple as it is now.
- *`Job` as a per-node timer.* Jobs become cluster-singular, which is a lock,
  which is the first genuinely new mechanism on this list.
- *The backup job's naivety.* It currently assumes one machine's disk is the
  whole database. That assumption is load-bearing in `verify/1` and in the
  restore path.
- *"There is nothing to cohere."* `Formula.Engine`'s claim survives placement
  intact and only placement. It is worth knowing that this sentence is the
  canary: any option that requires qualifying it is an option that has taken the
  guarantee away.

---

## 9. Three questions only Shane can answer

**1. What is the SLA — in what units does an outage cost, and what RPO and RTO
are actually tolerable?** Today RPO is `BACKUP_EVERY` (900s by default, and
`LEDGER_SYNC` is off, so a power loss costs more than that), and RTO is a manual
restore of unmeasured duration on the least-tested path in the system. If those
numbers are fine, most of this document is optional. If RPO must be zero, option
D is the only honest answer and everything else on the list is a detour.

**2. How many nodes, and what is driving the number?** The four possible
drivers point at different systems: *capacity* (more tenants than one machine
holds) and *residency* (a tenant's facts must be in a named region) point at
placement; *blast radius* (one tenant must not be able to take another down)
points at placement plus per-unit resource limits; *zero-downtime deploys*
points at the store, not the cluster. Only the first two make distribution the
right project.

**3. Availability or durability?** The backup already covers "the disk died".
If the answer is durability, the cheapest real improvements are `LEDGER_SYNC`,
a shorter cadence, and a restore that has actually been run — none of which is a
second node. If the answer is availability, the work is a shared store and a
fenced lease, and consensus still never enters the picture. If the answer is
"both, and RPO zero", that is option D and it should be said out loud, because
it is a months-long project that changes what a transaction costs.

---

## Sources

*Filled in below from the research pass; every claim about another system is
cited, and claims about this tree are cited to the file and line.*
