# Distribution

*Design research, 2026-08-13. Nothing in this document is built.
`Blazie.Cluster.distributed?/0` returns false, there is one node, and this
exists so that stays a decision somebody took rather than a task that keeps
being postponed.*

## The short answer

**The unit of distribution is the ledger, and ledger-per-node placement is
enough.** A ledger is already an append-only sequence with exactly one writer,
and doctrine 8 already says a fact belongs where it was written. Nothing Lazy
River promises today needs consensus, and the reason is structural rather than
lucky: there is no operation that writes to two ledgers, so there is no
cross-ledger atomicity to preserve.

**But "one owner" is the wrong place to put the guarantee.** The single most
useful thing this research turned up: Jepsen showed that Datomic — the same
architecture, fifteen years older — runs two live transactors during a failover,
and that this is *safe*, because every commit is a compare-and-set on the
database's head. Datomic removed the single-writer claim from its safety
documentation as a result. Apache BookKeeper, whose unit is also called a
ledger, says it plainly: "leader election is really leader suggestion… **it is
the job of the log to guarantee that only one can write changes to the
system**." So the recommendation is not a better lock. It is **a conditional
append** — the writer states the head it believes is current, and the store
refuses if it is not. That is a day's work at one node and it makes every later
option safe rather than hopeful.

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

There is one more thing to say before the detail, because it changes how §1
should be read. **Today's position is not "one node, ready for a second."** A
ledger owned by another node cannot be read, written or watched from here at all
— `Blazie.Registry` is node-local and nothing routes. `watch` across nodes
would join, receive nothing and never error. Erasure destroys a key on one
machine. Two nodes running the backup job overwrite each other's keys in the
bucket. A second node added today would not be a distributed database; it would
be two databases sharing a name registry, and several of the ways that goes
wrong are silent.

---

## 1. Where the tree actually stands

Eight findings. The first was measured on this machine today; the rest are read
off the working tree as of 2026-08-13 — which is moving, so §1.8 records one
finding that was fixed while this was being written. They matter because most of them mean the current position is not
"one node, ready for a second" but "one node, and a second node would be a
second database sharing a name registry".

### 1.1 `:global` prevents a fork only *within* a partition — measured

`Blazie.Cluster`'s moduledoc says a claim exists so that "a claim somebody
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

This is documented behaviour, not a bug. OTP's `global` docs say that when a
name clash is discovered on heal, a `Resolve` function decides "which pid is
correct"; the default, `random_exit_name/3`, "randomly selects one of the pids
for registration and kills the other one".

Three things about that sentence are worth knowing before relying on it.

**It is not random.** The implementation in `lib/kernel/src/global.erl` —
unchanged from OTP 21 through OTP 28 — is `minmax/2` comparing *node names*:

```erlang
minmax(P1, P2) ->
    if node(P1) < node(P2) -> {P1, P2}; true -> {P2, P1} end.

random_exit_name(Name, Pid, Pid2) ->
    {Min, Max} = minmax(Pid, Pid2),
    logger:log(info, "global: Name conflict terminating ~tw\n", [{Name, Max}]),
    exit(Max, kill),
    Min.
```

The pid on the lexicographically **lower node name** always survives. The
function name and the docstring are both wrong. Which history survives a
netsplit is not a coin toss; it is whichever node was named earlier in the
alphabet.

**The kill is untrappable, and this tree depends on it being trappable.**
`exit(Max, kill)` cannot be caught. `Ledger.init/1` sets
`Process.flag(:trap_exit, true)` with the comment "so the store is closed on an
ordinary shutdown rather than only when the process is killed" — and
`terminate/2` is what calls `state.module.close(state.store)`. A `:global`
conflict resolution bypasses that entirely: the file handle is never closed, no
final checkpoint is taken, and the losing ledger's resident-but-unflushed state
goes with it.

**It is logged below the default log level.** `logger:log(info, ...)`, against
OTP's default primary level of `notice`. A silent fork resolved by killing a
ledger writer produces, by default, *no log line at all*.

**And the window is 45 to 75 seconds wide.** `:global` learns about a lost node
from `net_kernel`, whose `net_ticktime` defaults to 60 seconds with
`net_tickintensity` 4 — so a silently unreachable node is not declared down for
somewhere between 45 and 75 seconds. That is the floor on how long two ledgers
can both be appending before anything notices.

With the OTP 25+ default (`prevent_overlapping_partitions: true`), the first run
of the same script produced instead:

```
[warning] 'global' at node lr_a requested disconnect from node lr_c
          in order to prevent overlapping partitions
```

— `:global` responded to the partition by tearing down connections to nodes that
were perfectly reachable. The docs describe this as actively disconnecting "from
nodes that reports that they have lost connections to other nodes", advise
*strongly* against disabling it, and note the fix "has to be enabled on all
nodes in the network in order to work properly". That is the better of the two
behaviours and it should be understood for what it is: `:global` trades a fork
for a wider outage, and it makes that trade without being asked.

`:global` is a same-partition mutual exclusion. It is not a placement mechanism,
and it cannot become one, because it has no way to fence a process that comes
back. Kleppmann's argument applies exactly: a lock without a monotonically
increasing token cannot be made safe against a paused holder, because "GC can
pause a running thread at *any point*, including the point that is maximally
inconvenient for you (between the last check and the write operation)". A
`:global` claim is precisely a lock with no token.

One more `:global` property worth knowing before anyone proposes leaning on it
harder: registration takes **one cluster-wide lock, keyed by the single atom
`global`** — not one lock per name — across every node it knows about, with no
quorum. Contention backs off from 250 ms, doubling to 8 seconds. The EU RELEASE
project measured the consequence: "just 0.01% global commands limits scalability
to around 60 nodes", and "the latency of the global commands increases
dramatically with scale". `:global` is fine for claiming a ledger once per open,
which is exactly how this tree uses it, and it does not become the basis of
anything larger.

### 1.1a And no other BEAM registry fixes this

Worth settling now, because "swap `:global` for something better" is the
reflexive first suggestion and it is wrong.

| | Two nodes hold one name under partition? | How it resolves |
|---|---|---|
| `:global` | **Yes** | Kills the pid on the higher node name, untrappably, at `info` level |
| `syn` 3.x | **Yes**, documented | Higher `erlang:system_time/0` wins — its own docs call this "a very simple mechanism that can be imprecise, as system clocks are not perfectly aligned in a cluster" |
| `Swarm` (ring) | **Yes** — "network partitions result in all partitions running an instance" | Shuts down copies after heal. Dormant since 2021. |
| `Horde` | **Yes** — and **also without a partition**: two simultaneous `register/3` calls both return `{:ok, pid}`, and the CRDT picks a loser ~200 ms later | `{:name_conflict, …}` exit |
| `ra` | **No** — a minority cannot commit | n/a |

Horde's own README redirects singleton users elsewhere, and its docs say the
conflict exit "can be a common occurrence". Every CRDT- or gossip-based registry
on the BEAM is in the same class as `:global` on the only question that matters
here. The distinction is not `:global` versus a better registry; it is **a
registry versus a log that refuses a stale writer** (§2.2).

This is not a BEAM problem, either. Alquraan et al. studied 136
network-partitioning failures across 25 cloud systems and found the majority
"led to catastrophic effects, such as data loss, reappearance of deleted data,
broken locks", that "88% of the failures can occur by isolating a single node",
and that 29% came from *partial* partitions — "the majority of partial network
partitioning failures are due to design flaws. This indicates that developers do
not anticipate networks to fail in this way."

### 1.2 There is no routing, so a second node is a second database

`Ledger.via/1` and `Ledger.local/1` address `Blazie.Registry`, a plain
`Registry`, which is node-local. `Ledger.open/2` on node B for a ledger owned by
node A returns `{:error, :owned_elsewhere}` and there is no other path that
reaches it. `Snapshot.find/2` calls `Ledger.find_at/3` on a via-tuple pointing at
the local registry.

So one node is not currently a deployment choice among several. It is the only
configuration in which the system answers at all. Everything below is
green-field.

### 1.3 `watch` is silently node-local

`Ledger.announce/3` uses `Registry.dispatch(Blazie.Watchers, name, …)`. That
registry is node-local, so an announcement never crosses a node. A subscription
registered on another node would join successfully, receive nothing, and never
error.

That is the worst failure shape in this repository's own taxonomy: a watch that
has stopped pushing is indistinguishable from a watch over data that has stopped
changing. `failure-modes.md`'s second cross-cutting principle — "a value that
two different causes can produce cannot be evidence for either" — applies
directly.

### 1.4 The keyring is per-node, so erasure is per-node

`Blazie.Keyring` is a GenServer registered under a *local* `name: __MODULE__`.
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

### 1.8 One name bug is fixed; the other gets worse distributed

`failure-modes.md` names two defects in the snapshot name. Their status differs,
and the difference is instructive.

**C2 is fixed, and the fix is a prerequisite for everything below.** While this
was being written, `Snapshot.open/1` changed from keying on a ledger *reference*
to keying on `Ledger.name_of/1`, and `Controller.named/2` — which zipped
`Map.values/1` against the caller's argument order and so gave each ledger
somebody else's transaction — is gone. `Snapshot.reopen/1` now normalises an
address handed in where a name belongs.

That matters more than a bug fix. A name keyed by a via-tuple into a *local*
`Registry` is meaningless on another node by construction; a name keyed by the
ledger's own name is not. The snapshot name is now the portable, machine-
independent value §2.1 argues it always should have been. **Distribution just got
materially cheaper, and this is the change that did it.**

**C1 is not fixed.** A snapshot name is still client-writable and a transaction
above the ledger's current one is still accepted, silently meaning "everything,
so far" — there is no bound check in `Wire.snapshot_name/1`, `Snapshot.reopen/1`
or the controller. Distributed, a transaction number minted against one node's
counter is not merely unbounded; it is *ambiguous*, because nothing in the name
says which counter it came from. Fix it before routing exists, not after.

---

## 2. The crux: what does "read at a transaction" mean across nodes?

This is the question the whole design turns on, so it gets answered rather than
gestured at.

### 2.1 The name was never a point in time

A snapshot name is `%{ledger => tx}`. Two different properties get bundled
together in the prose around it:

1. **Stability** — the same name answers the same facts forever.
2. **Atomicity** — the ledgers in a name were read at one common instant.

blazie has (1). It has never had (2), and does not claim it anywhere in
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

This is the same answer Datomic gives, and Datomic is the closest relative this
design has. Datomic's ACID documentation says "the time basis of transactions is
a global ordering of transactions for a **particular system**" — one database —
and "a database value knows its time basis via `Database.basisT()`". There is no
cross-database basis-t and no documented cross-database consistency guarantee.
Datomic composes several databases in one query the same way `Snapshot` composes
several ledgers: as several independent points, each stable, with no claim that
they were taken together.

The rest of the Datomic comparison is worth having in front of you, because it
is the same architecture arrived at independently. Datomic Pro is "a distributed
database with arbitrary read scaling", with **"Writes (transactions): Single
transactor process"** and **"Write availability: Failover to standby
transactor"**, while "application processes have their own copy of the query
engine and database in local memory". That is: one writer per database, no
consensus in the write path, HA by a standby with a storage-level lock, and
readers that evaluate locally. Doctrine 7 and doctrine 8 describe the same
machine. Datomic Cloud reaches the same place by a different route, using
"conditional writes with DynamoDB" for the transaction log — a compare-and-swap
in storage, not a quorum.

The conclusion to draw is not "Datomic did it so it is fine". It is narrower and
stronger: **the shape blazie has chosen has a well-tested existence proof in
which consensus appears nowhere in the write path, and the single writer is
protected by a conditional write in the storage layer.** That is option B2 in
§3, fifteen years early.

Datomic's own multi-tenancy advice is the same conclusion from the other end:
"the Datomic transactor is designed and intended to serve a single primary
database… **if your architecture requirements necessitate multiple logical
databases, we suggest running an individual transactor per active database**."
That sentence is ledger-per-node placement, written by the people who built the
reference implementation of this shape.

### 2.2 The correction that matters most: the lock is not the safety property

This is the single most useful thing the research turned up, and it changes the
recommendation rather than decorating it.

Jepsen tested Datomic Pro in 2024 and found that during a transactor failover,
two transactors can be live at once:

> "During this window Datomic is not a single-writer system, but a multi-writer
> one! … Thankfully this doesn't matter: **Datomic's safety property follows
> directly from the Sequential consistency of the storage system's CaS
> operation. Any number of concurrent transactors ought to be safe.**"

Datomic agreed, and **removed the single-writer argument from its safety
documentation**. The actual mechanism is a conditional write, stated plainly in
its ACID docs: "Writes are strong serializable because they are fully
serialized. **Every successful transaction performs a storage CAS ensuring that
its basis is the previous transaction.**"

Apply that here and the whole design gets simpler and stronger:

> **One owner per ledger is a liveness and throughput property, not a safety
> property. Safety should come from the append being a compare-and-set on the
> ledger's head: the writer supplies the transaction it believes is current, and
> the store refuses the append if that is not what it finds.**

With that in place, §1.1 stops being a correctness problem. Two nodes racing
during a partition cannot fork a ledger, because the second one's append is
refused by the store — the refusal carries its repair, like every other refusal
here. `:global`, or a lease, or a placement map then exists only to stop two
nodes wasting work and thrashing a cache, and getting it wrong costs throughput
rather than history.

This is also the *cheapest* fix available: it is a change to `Store`'s `append`
callback (take the expected head, return a refusal if it does not match), and it
is worth making at one node, where it costs nothing and is trivially testable.
`Store.File` already has the byte offset it would compare; SlateDB, the store
`mix.exs` names as the destination, already carries a `writer_epoch` in its
manifest — "a monotonically increasing `u64` that is transactionally incremented
by a writer on startup", where a fenced writer discovers it "has been fenced"
and "should halt", and a "zombie writer is a writer with an epoch that is less
than the `writer_epoch` in the current manifest". That is Kleppmann's fencing
token, already implemented, in the library already chosen.

Datomic Cloud went one step further and removed the failover window entirely by
leaning on the CAS rather than on a lock: transactions are routed to "a
preferred Node per database", but this is "a **performance optimization only:
any Primary Compute Node can handle any transaction**", and if that node cannot
be reached "any node can and will handle txes. **Consistency is ensured by CAS
at the DynamoDB level** … **This is all immediate, there are no
transfer/recovery intervals.**" Compare Datomic Pro's lock-based HA, where the
documented worst-case peer recovery is `2 × (heartbeat_msec / 1000) + 1` —
about **11 seconds** at the default 5-second heartbeat — followed by a
catch-up period in which transactions "experience unusually long latencies (up
to several seconds)".

A lock buys an eleven-second outage. A conditional write buys none.

The same conclusion has been reached independently by the system closest to this
one in vocabulary as well as shape. Apache BookKeeper — whose unit of storage is
also called a **ledger** — states the model as "a ledger has a single writer and
multiple readers (SWMR)", and then says the important part outright:

> "**In many cases, leader election is really leader suggestion. Multiple nodes
> could think that they are leader at any one time. It is the job of the log to
> guarantee that only one can write changes to the system.**"

Its mechanism is fencing: a new writer marks the ledger in-recovery in the
metadata store and fences the storage nodes, after which the old writer's
appends error out rather than being accepted and later reconciled. A sobering
coda worth carrying: even that had a data-loss bug found by TLA+ in 2021,
because fencing one read path was not enough — recovery reads had to be fenced
too. If this route is taken, the fence needs to be modelled, not assumed.

**So the corrected shape of the answer is:**

- The **log** enforces safety, by refusing an append whose expected head is not
  the current head (or whose writer epoch is stale).
- The **claim** — `:global`, a lease, a placement map — enforces only
  efficiency: it stops two nodes doing the same work and thrashing the same
  cache. Being wrong costs throughput.
- Which means `:global` is *adequate for the job it would actually have*, and
  the work is in `Store`, not in `Cluster`.

### 2.3 So what does distribution actually cost?

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

### 2.4 What actually breaks it: replication

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

### 2.5 The restriction that falls out of doctrine 7

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
| **B. Ledger placement, `:global` claims, no replication** | Capacity across machines. Blast radius per node. Placement is the only new concept. Snapshot guarantee untouched (§2.4). | A partition forks a ledger (§1.1) unless the claim is replaced by a real lease. Every cross-node hop is a doctrine-7 violation unless a tenant's ledgers are co-placed. A node's death makes its tenants unavailable until a restore. | Cross-tenant snapshots. Ledger mobility (moving a ledger means moving its disk). | Routing in four operations, cross-node watch, cluster-singular jobs and keyring, backup key namespacing. Weeks. |
| **B2. Placement with a conditional append and a writer epoch** | Everything B buys, plus a partition **cannot** fork: a returning owner's append is refused by the store because its epoch is stale. Ledger mobility, and with a shared store, seconds-not-minutes failover. No expiry to wait out. | The store participates in correctness: `Store.append/2` grows an expected-head argument, and the epoch has to live somewhere outside the cluster (object storage suffices). | Same as B. | The conditional append is a day. The epoch and the routing are weeks, and the store work in §6 comes first. |
| **C. Primary/replica per ledger (async)** | A warm copy. Reads could be served locally. Sounds like HA. | **Breaks the central claim on every failover** (§2.4). Read-your-writes needs the primary anyway. Replica lag is a new unbounded quantity. | Nothing — and that is the problem: it forbids nothing and quietly withdraws the guarantee everything rests on. | Weeks, for a negative. |
| **D. Raft per ledger (`ra`)** | RPO zero for an acknowledged transaction. Automatic failover with no lost-write window. The snapshot guarantee survives, because a tx is only returned after quorum. | A transaction becomes a network round trip plus remote fsyncs instead of a local write. `tx` stops being a cheap counter. Membership, snapshotting and recovery become operational surface. Three machines minimum per ledger, or a shared Raft group per placement unit. | A one-machine deployment. Cheap writes. | Months. A genuine second implementation of `Ledger`. |
| **E. Global consensus / sequencer (FDB-shaped)** | One global transaction version; cross-ledger snapshots become atomic and cross-node ones trivially so. | Every read takes a read version from a central component — the exact round trip doctrine 7 refuses. The whole design's reason for existing goes away. | Doctrine 7. | Quarters. A different database. |

Three notes on option D, because it is the one that deserves a fair hearing.

**In its favour.** `ra` is the right library if Raft is the answer: maintained by
the RabbitMQ team, "not tied to RabbitMQ", explicitly designed for exactly this
shape — "in a data store a data partition can be its own Raft cluster… any long
lived stateful entity that the user would like to replicate across cluster nodes
can use a Raft cluster" — and it is continuously tested with Jepsen, which
nothing else on this list is. Its shared WAL is the piece that makes
per-ledger Raft affordable at all: "it is not practical or performant to have
each server write log entries to their own log files", so all servers on a node
funnel through one WAL and one `fsync` per batch. Idle ledgers cost almost
nothing, because "leaders will not send append entries unless there is an update
to be sent". And the Raft **term is a fencing token for free** — §2.2's
requirement satisfied structurally rather than by us.

**Against, specific to this tree.** A `ra` server id is `{atom(), node()}`.
RabbitMQ's own runtime docs warn that "in environments with very large numbers of
quorum queues, the [atom] limit may need a bump. Such workloads are recommended
against." This tree has already made the opposite decision and written it down
twice — `Ledger`'s moduledoc: "a ledger's name is any term, not an atom. Tenants
arrive at runtime, and atoms are never collected — a name taken from a request
would leak the atom table until the node fell over." One `ra` cluster per ledger
reintroduces, at the library's boundary, precisely the leak this design refuses.
That is not a detail; it is a collision between a documented decision here and a
documented constraint there, and it has no clean workaround if ledgers are
created from tenant input.

Two more to price: `ra` effects are neither at-least-once nor at-most-once —
"there is also a chance that effects will never be issued or reach their
recipients. Ra makes no allowance for this" — which means `announce`/`watch`
must be derived by a reader from the log rather than emitted as an effect. And
the shared WAL cuts both ways: if the segment writer crashes it takes the whole
`ra` supervision tree with it, so the blast radius is every ledger on the node.

**And doctrine 18 cuts sideways, not for or against.** "Prefer what we do not
maintain" favours the library; its own corollary — "name who else would have to
keep it alive, and what happens to us the year they stop" — is answered well
(RabbitMQ is not going anywhere). What doctrine 18 does not cover is that
adopting `ra` means *we* maintain per-ledger Raft cluster lifecycle, membership
changes, snapshotting policy and a recovery path. The library is cheap; the
operational surface it implies is not. RabbitMQ's own guidance is to review the
topology past ~5000 quorum queues, and a benchmark of 10,000 across three nodes
measured a rolling cluster restart at **267–285 seconds**. That is the recovery
cost of ledger-per-Raft-cluster at four figures of ledgers.

### 3.1 There is a theorem here, and it says option B2 is enough

The intuition in §2.2 — that safety belongs in the log and the claim is only an
optimisation — is not folklore. It has been stated formally twice.

**Vertical Paxos** (Lamport, Malkhi & Zhou, PODC 2009) separates the steady-state
protocol from reconfiguration: "the use of a configuration master allows… a
state-machine implementation to tolerate *k* failures using only *k* + 1
processors instead of the 2*k* + 1 processors required without it", and "the
configuration master need be called upon… only for reconfiguration". Its own
summary of the special case is the design being proposed here: "if we call the
leader the primary and all other acceptors backups, then we have a traditional
primary-backup system."

**Delos** (Facebook, OSDI 2020) sharpens it to the exact primitive:

> "The Loglet does not have to support fault-tolerant consensus… it is not
> required to provide high availability for append calls. Instead, the Loglet
> provides a highly available `seal` command."
>
> "**A seal bit does not require fault-tolerant consensus… It can be implemented
> via a fault-tolerant atomic register, which in turn is weaker than consensus
> and not subject to the FLP impossibility result.**"

And Delos's reconfiguration store is, in its own words, "simply a versioned
register supporting a conditional write" — which is exactly what S3's `If-Match`
became in November 2024.

**Aurora** (SIGMOD 2018) is the production proof, and its scope is stated as
"single-writer databases with read replicas". Its LSN space is "common across the
database volume, monotonically increasing, and allocated by the database
instance", and "**this is the key invariant that allows Aurora to avoid
distributed consensus for most operations**". Storage nodes have no say: "storage
nodes do not have a vote in determining whether to accept a write, they must do
so." Fencing is by epoch, and their sentence about it is the best argument
against a plain lease that anyone has written:

> "Storage nodes will not accept requests at stale volume epochs. This boxes out
> old instances with previously open connections… **Some systems use leases to
> establish short term entitlements to access the system, but leases introduce
> latency when one needs to wait for expiry. Aurora, rather than waiting for a
> lease to expire, just changes the locks on the door.**"

That changes the recommendation in one place: **prefer an epoch to a lease.** An
epoch bumped in the store and validated on every append needs no expiry wait, no
clock assumption and no `net_ticktime`; a new owner takes over the instant it can
write, and the old one discovers it is fenced at its next append.

The known counterweight, and it should be recorded: a fence is weaker than
consensus but not therefore easier to get right. BookKeeper's fencing protocol
carried a data-loss bug for roughly a decade until a TLA+ model found it in 2021
— fencing the LAC read path was not sufficient; recovery reads had to be fenced
too. If this route is taken, the fence gets modelled, not eyeballed.

---

## 4. What a partition does

Assume option B/B2 (placement, no replication) unless stated. "Owner side" is
the side of the partition holding the ledger's owning node.

| | Owner side | Other side | Correct behaviour |
|---|---|---|---|
| **`ask` at a name** | Answers normally. | Cannot answer. | Refuse, naming the unreachable ledger and its owner. **Never** a partial fact set — a partial answer at a name is cached forever. |
| **`open`** | Returns a current name. | Cannot produce a name. | Refuse. Do not fall back to opening a fresh local ledger under that name — which is what `Ledger.open/2` does today when `:global` says nobody owns it, and under partition `:global` says exactly that (§1.1). This is the single most dangerous line of code in a distributed blazie. |
| **`write`** | Appends normally. | Cannot append. | Refuse with a repair. Under B this holds only by good luck; under B2 the stale epoch makes it structural — the far side may *try*, and the store refuses it. |
| **`watch`** | Keeps pushing. | Stops pushing. | Must **terminate the subscription with a reason** the client receives. A watch that goes quiet is indistinguishable from data that stopped changing (§1.3), and that is the failure shape this repo has already decided it will not ship. |
| **Keyring** | Can destroy locally; cannot reach the other side's KEK store or its 15-minute DEK cache. | Cannot reconcile against `$erasures` if that ledger is on the far side; fails silently today (§1.5). | Erasure must be refused, not partially performed, when any node that could answer for the subject is unreachable — and the refusal must say which. A partial erasure that reports success is a compliance failure, not an availability one. |
| **Backup** | Runs, and copies its own view. | Runs, and copies its own view, over the same `keys/keks` object (§1.6). | Cluster-singular, or namespaced per node **and** per node in the restore path. Whichever is chosen, `verify/1` compares one node's disk against the whole bucket today and would have to learn what a complete cluster backup even is. |
| **Authorization** | Works if `$authority` is here. | Every operation fails closed. | Failing closed is right. But it means one ledger's node is a cluster-wide availability floor, so `$authority` should be split per tenant and co-placed (§5.2). |

The general shape: under placement, a partition is an **availability** event for
the tenants on the far side and nothing more — *provided* the claim is a fenced
conditional append rather than a bare `:global` registration. Without it, a partition is a
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
  session floor from §2.3. Both are worth doing at n = 1.

**`ask`** needs no protocol change *if* a tenant's ledgers are co-placed
(§2.5) — the snapshot is entirely on one node, the evaluator runs there, and
the caller's node forwards a question and receives an answer, which is one hop
rather than a fan-out. If co-placement is rejected, `ask` becomes scatter-gather
and doctrine 7 needs amending first.

**`watch`** is the easiest of the four, because the BEAM does the work: run the
subscription process on the *owning* node and let it `send/2` to the
subscriber's pid, which is location-transparent. What has to be added is the
teardown story — a monitor across the node boundary and an explicit termination
message on `:nodedown`, so silence is never the signal.

**`write`** routes to the owner, and under B2 carries the writer epoch so that
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

1. **KEKs into KMS, one key version per subject.** Priced out, and — this is new
   — also *worse*, not merely dearer. The `Keyring.GCP` moduledoc already does
   the arithmetic (about six cents per key version per month, ~$600/month at ten
   thousand subjects). What it does not say is what KMS destruction actually
   means:
   - Cloud KMS key versions spend a **default 30 days** in
     `DESTROY_SCHEDULED`, restorable throughout. The minimum is 24 hours, the
     maximum 120 days, and it is settable **only at key creation**. (The
     often-repeated "24 hours by default" is wrong.)
   - After that, "**key material can remain in Google systems for up to 45 days
     from the scheduled destruction time**", covering "both active systems and
     data center backups". **So the honest floor is about 45 days and the
     default path is about 75** — from the API call to gone.
   - Destroy is **per-location**. Key material "is confined to the selected
     region while at rest and in use"; there is no cross-location destruction.
   - And the consistency model runs the wrong way for this: "enabling a key
     version is a strongly consistent operation", while "**disabling** a key
     version is an **eventually consistent** operation… in exceptional cases the
     key version remains usable for several hours after it is disabled." The
     docs say nothing at all about destroy propagation. The mechanism is
     visible: "when you create or read key versions, consensus is always
     required among the datacenters storing the key material… when you perform
     cryptographic operations… **consensus is not required**." The decrypt path
     never asks the quorum that knows the key is dead.

   NIST SP 800-88r1 §2.6.3 states the general form of the objection —
   "sanitization using CE should not be trusted on devices that have been
   backed-up or escrowed the key(s)" — and its fourth precondition, *be able to
   verify it*, is simply unsatisfiable against a cloud KMS: you cannot verify
   Google's 45-day backup expiry, you accept it on contract.

   **This inverts the usual reading of the current design.** Holding
   per-subject KEKs in a local store with the KMS holding only a master is not
   a compromise made for price; on latency, verifiability and blast radius it
   is the *better* architecture, and the doc should say so in those terms. What
   the local store lacks is irreversibility against a restore — which is what
   the tombstone reconciliation is for, and which §1.5 shows breaks in a
   cluster.
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
  can read (§1.5). This is NIST's escrow objection with a peer node playing the
  part of the escrow, and it compounds with §1.6, where two nodes write the same
  `keys/keks` object.

And one thing worth recording even though it is not a distribution question,
because it changes what the erasure claim can honestly say. The regulatory
position on crypto-shredding has moved and is more specific than the README's
framing:

- WP29 Opinion 05/2014 classifies "deterministic encryption or keyed-hash
  function with deletion of the key" as **pseudonymisation, not anonymisation**,
  and names "believing that a pseudonymised dataset is anonymised" as a common
  mistake. Anyone citing WP29 *for* crypto-shredding is misreading it.
- EDPB Guidelines 02/2025 on blockchain ¶51 is the closest thing to an
  endorsement, and it is conditional: on key deletion "the encrypted data will
  be unintelligible, **at least until the algorithm is broken**, the decryption
  techniques advance sufficiently… or if the key had already been compromised or
  leaked", and "encrypted personal data is still personal data". ¶96 adds a
  standing reassessment duty, naming quantum computers. **A crypto-shred is a
  claim that has to be maintained, not a ticket that closes.**
- ¶53 is the interesting one for a fact log: a **perfectly hiding cryptographic
  commitment** is strictly stronger, because once the data and witness are
  deleted the commitment is "neither possible to recover nor to recognise" —
  information-theoretically, with no "until the algorithm is broken" clause.
  "Commitment on the log, data off-log, delete the witness" dominates
  "ciphertext on the log, delete the key" on exactly the axis regulators care
  about.
- And the road not taken is worth naming, because someone else took it with the
  same constraints: Amazon QLDB faced an immutable ledger plus Article 17 and
  did **not** crypto-shred. It built **redaction** — a physical delete-in-place
  that "deletes only the user data in the specified revision, and leaves the
  journal sequence and the document metadata unchanged", so the hash chain still
  verifies. That is structurally what EDPB ¶53 blesses, and it is a live
  alternative to doctrine 16's mechanism, though not to its intent.

---

## 6. Availability or durability — what a second node actually buys

Worth doing as a list, because the answer changes the recommendation.

| Failure | What covers it today | What a second node adds |
|---|---|---|
| Process or ledger crash | OTP supervision; restart in milliseconds, replay from checkpoint. | Nothing. |
| Node crash / VM restart | Supervisor tree restart, or the platform restarting the container; `LEDGER_DIR` is a mounted volume. Seconds to tens of seconds. | Nothing, unless the ledger can *move*, which needs an epoch and a store the other node can read. |
| Deploy | The node goes and comes back. Tens of seconds of unavailability, every deploy. | Zero-downtime deploys — **but only with a shared store.** With local disks, moving a ledger means moving a volume. |
| Disk death | The backup job. RPO = `BACKUP_EVERY` (900s default), and note `LEDGER_SYNC` is off by default, so a returned transaction survives a process death and not a power loss. | Nothing that a shorter cadence and `LEDGER_SYNC=true` do not do more cheaply. |
| Machine death | Backup covers durability, not availability. Recovery is a restore — minutes to hours, on the code path `failure-modes.md` names as the least-tested in the system. | This is the real one. Placement plus a shared store turns a restore into an epoch bump. |
| Region death | Nothing. | Nothing, unless placement is region-aware, which is a further step. |
| Load / capacity | One machine's. | This is the other real one, and it is where placement is unambiguously the right tool. |

Two conclusions fall out.

**The store is the bottleneck, not the cluster.** Five of the seven rows above
are gated on whether a ledger's bytes are reachable from more than one machine.
`Blazie.Store` is already a three-function behaviour designed for exactly this
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

**Do not build consensus. Do not build replication. Put the guarantee in the log,
not in the registry — and build the store before the cluster.** In this order:

**0 — Finish the name.** C2 landed while this was being written — a snapshot
name is now keyed by ledger name rather than by a node-local registry reference,
which is what makes it portable at all (§1.8). What remains is C1: refuse a `tx`
above the ledger's current one, with a repair rather than a clamp. Add the
session floor from §2.3 while you are there. These are prerequisites: designing
distribution on a name that is already wrong at one node is designing on sand,
and both are worth doing whatever the answer to distribution turns out to be.

**0b — Make `append` conditional.** Add an expected-head argument to `Store`'s
`append/2` and refuse, with a repair, when it does not match. This is the
`writer_epoch`/CAS of §2.2 and §3.1, it is a day's work at one node, and it is
what makes every later option safe rather than hopeful. Do it before anything
else on this list, because it is the only item that is both cheap now and
load-bearing later.

**1 — Tell the truth about `:global`, today.** Change `Blazie.Cluster`'s
moduledoc to say what §1.1 measures: `:global` is same-partition mutual
exclusion, it does not prevent a fork under partition, and OTP's default
mitigation is to disconnect reachable nodes. Add the netsplit test — the script
in §1.1 is thirty lines and runs in ten seconds. A test that proves the
limitation is worth more than a comment that describes it, because the comment
currently reads as reassurance.

**2 — Move the store to object storage.** The single highest-leverage piece of
work on this list, and it is not a distribution project. It converts "move a
ledger" from a volume migration into an epoch bump, and it collapses five rows
of the §6 table.

**3 — Then placement, with an epoch rather than a lease (option B2).** Ledger →
node, with a monotonically increasing epoch bumped in the store on takeover and
validated on every append. **Prefer the epoch to the lease**, for Aurora's
reason: a lease has to be waited out, an epoch does not — "rather than waiting
for a lease to expire, just changes the locks on the door." Put the epoch **in
the object key**, as Neon's generation numbers and SlateDB's writer epochs both
do, so a stale writer and the current one cannot collide on one object at all
rather than racing for it.

Object storage is a sufficient home for that epoch and avoids introducing a
consensus system to hold a map of a few thousand entries: S3 has had
`If-None-Match` (put-if-absent) since August 2024, `If-Match` (compare-and-swap)
since November 2024, and conditional deletes since September 2025, and AWS's own
position is that these address concurrent writes "without needing external
coordination systems". Two caveats to design around, both load-bearing:

- **Conditional writes are only sound if every writer uses them.** AWS says so
  directly: "non-conditional operations can bypass conditional logic… True
  concurrency control requires all requests to follow identical rules." Enforce
  it with the `s3:if-match` / `s3:if-none-match` bucket-policy condition keys,
  not by convention.
- **The rate ceiling is roughly 10–15 conditional writes per second on one hot
  key.** That is fine for an epoch bumped on takeover and a lease renewed every
  few seconds. It is nowhere near enough for a CAS per transaction, so the
  per-append conditional check belongs in the store's local write path, not in a
  round trip to the bucket.

With placement: routing in the four operations, cross-node watch,
cluster-singular (or per-placement-unit) keyring and jobs, and a backup that
knows what a cluster is.

**4 — Adopt co-placement as a rule, in writing.** A tenant's ledgers move
together; a snapshot never spans a placement unit. This is what keeps doctrine 7
true, and it should be a doctrine row rather than a comment in a router.

**5 — Never replicate a ledger asynchronously.** If per-ledger RPO-zero HA is
ever genuinely required, the answer is `ra` per placement unit and it is a
months-long project that changes what a transaction costs. It is not an
incremental step from B2, and pretending otherwise is how C gets built by
accident.

**6 — And do not go the other way either.** The temptation, when consensus looks
expensive, is eventual consistency with merge-on-read. That road is thoroughly
mapped and it ends badly for a system making this system's promises. Jepsen
measured Riak losing **71% of acknowledged writes on a fully-connected, healthy
cluster with no partitions**, and **92% with `PR=PW=R=W=quorum`** — because
last-write-wins over wall-clock timestamps has no reliable notion of "last".
Basho's own engineer wrote it best in 2013: "Last write wins, except when it
doesn't, but even then it does… there is no reliable definition of 'last write';
because system clocks across multiple servers are going to drift." The industry
converged away from it: Amazon's 2022 paper says DynamoDB "shared most of the
name of the previous Dynamo system but little of its architecture", uses
Multi-Paxos, and that "**only the leader replica can serve write and strongly
consistent read requests**". Immutability makes this worse here, not better — a
merged wrong answer would be cached under a name forever.

The smallest step that buys real availability, stated on its own because it was
asked for directly: **a conditional append, a shared store, and an epoch** —
steps 0b, 2 and 3. Everything before that is honesty work, and everything after
it is a different system.

---

## 8. What we would have to give up

**By choosing placement over consensus:**

- *RPO zero.* An acknowledged transaction on a node that then loses its disk
  costs whatever the backup cadence is. If that is unacceptable, D is the only
  option and it should be chosen deliberately.
- *Automatic failover.* A dead node's tenants are unavailable until another node
  bumps the epoch and reopens the ledger — seconds with a shared store, a
  restore without one. (With an epoch rather than a lease there is no expiry to
  wait out, which is the point of §3.1.)

**By choosing co-placement (§2.5):**

- *Cross-tenant snapshots.* A question can never span two placement units. In
  exchange, doctrine 7 stays literally true and `ask` stays one hop.
- *Free ledger placement.* Ledgers stop being independently placeable, which
  costs the ability to put one enormous ledger on its own machine unless it is
  also its own placement unit. That is a scheduling constraint to state, not a
  contradiction.

**By choosing an epoch in the store over `:global` alone:**

- *Zero dependencies.* `:global` is in OTP and costs nothing. An epoch means a
  store that participates — `Store.append/2` grows an argument, and object
  storage becomes load-bearing for correctness rather than only for bytes.
  Doctrine 18 cuts both ways: the store is something else to keep alive, but so
  is a bespoke split-brain resolver.
- *Nothing else.* Note what is **not** on this list: `:global` does not have to
  be removed. Once the log refuses a stale writer, `:global` is doing a job it is
  good at. This is the cheapest part of the whole proposal and it should not be
  confused for the expensive part.

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
second node. If the answer is availability, the work is a conditional append,
a shared store and an epoch, and consensus still never enters the picture. If the answer is
"both, and RPO zero", that is option D and it should be said out loud, because
it is a months-long project that changes what a transaction costs.

---

## Sources

Claims about this tree are cited to the module in the text. Everything else is
below. Where a fact was measured rather than read, it says so.

**Measured here, 2026-08-13**

- The `:global` netsplit transcript in §1.1: OTP 29 / erts 17.0.5, three nodes
  via `:peer`, `prevent_overlapping_partitions` disabled to keep the observer
  connected. Script at
  `<scratchpad>/global_split.exs` and `split2.exs`; it is thirty lines and runs
  in ten seconds, which is why §7 step 1 asks for it as a test.

**`:global`, OTP and the BEAM**

- `global` module reference, incl. `Resolve`, `random_exit_name/3`,
  `random_notify_name/3`, `notify_all_name/3`, and
  `prevent_overlapping_partitions` (OTP 25+) —
  <https://www.erlang.org/doc/apps/kernel/global.html>
- `random_exit_name/3` / `minmax/2` implementation (the "not random" finding) —
  `lib/kernel/src/global.erl`, unchanged OTP 21 → OTP 28
- `net_ticktime` (60 s) and `net_tickintensity` (4), giving the 45–75 s
  detection window — <https://www.erlang.org/doc/apps/kernel/kernel_app.html>
- Global-operation scalability ("0.01% global commands limits scalability to
  around 60 nodes") — RELEASE project, *Improving the Scalability of the Erlang
  Distributed Actor Model*,
  <https://www.dcs.gla.ac.uk/research/sd-erlang/release-summary-arxiv.pdf>
- Horde: CAP statement, duplicate processes, `{:name_conflict, …}`, and the
  README's redirect for singletons — <https://horde.hexdocs.pm/readme.html>,
  <https://hexdocs.pm/horde/eventual_consistency.html>
- `syn` conflict resolution by system time — <https://github.com/ostinelli/syn>
- `Swarm` partition behaviour — <https://github.com/bitwalker/swarm>
- Mnesia `{inconsistent_database, running_partitioned_network, Node}` and "what
  data to keep after a communication failure is outside the scope of Mnesia" —
  <https://www.erlang.org/doc/apps/mnesia/mnesia_chap7.html>
- `ra`: multi-Raft model, shared WAL rationale, `wal_sync_method`, "thousands of
  ra clusters", server id `{atom(), node()}`, Jepsen testing —
  <https://github.com/rabbitmq/ra>,
  <https://github.com/rabbitmq/ra/blob/main/docs/internals/INTERNALS.md>
- `ra` effects: "there is also a chance that effects will never be issued or
  reach their recipients. Ra makes no allowance for this" — INTERNALS, above
- Atom-table warning for large numbers of quorum queues —
  <https://www.rabbitmq.com/docs/runtime>
- ~5000 quorum-queue guidance — <https://www.rabbitmq.com/docs/quorum-queues>;
  10,000-queue restart benchmark (267–285 s) —
  <https://www.rabbitmq.com/blog/2025/09/01/6-khepri-default>
- Khepri: why RabbitMQ left Mnesia, majority requirement, whole dataset in
  memory — <https://github.com/rabbitmq/khepri>,
  <https://www.rabbitmq.com/docs/metadata-store>

**Datomic — the closest relative**

- "No per-db write scaling… only one transaction can occur at a time in a given
  database"; peers hold the query engine and database in local memory —
  <https://docs.datomic.com/overview/architecture.html>
- "Every successful transaction performs a storage CAS ensuring that its basis is
  the previous transaction"; "the time basis of transactions is a global ordering
  of transactions for a particular system" —
  <https://docs.datomic.com/transactions/acid.html>
- Single transactor process, failover to standby, `heartbeat-interval-msec`
  5000, `2 × (hb/1000) + 1` ≈ 11 s recovery, post-failover latency cliff —
  <https://docs.datomic.com/operation/ha.html>
- **Jepsen: two transactors can be live at once, and it is safe because of the
  CAS** — <https://jepsen.io/analyses/datomic-pro-1.0.7075>; Datomic's response,
  including removing the single-writer safety argument —
  <https://blog.datomic.com/2024/05/Jepsen-tests-Datomic.html>
- Cloud: consistent hash ring is "a performance optimization only"; "any node can
  and will handle txes. Consistency is ensured by CAS at the DynamoDB level…
  there are no transfer/recovery intervals" —
  <https://docs.datomic.com/glossary.html>,
  <https://docs.datomic.com/operation/cloud-ha.html>
- Cross-database: peers may join across databases, clients may not —
  <https://docs.datomic.com/reference/clients-and-peers.html>. **No cross-database
  point-in-time guarantee is documented anywhere; the conclusion in §2.1 is
  inferential** (per-database `basisT`, per-connection `sync` and `transact`) —
  <https://docs.datomic.com/javadoc/datomic/Database.html>,
  <https://docs.datomic.com/transactions/client-synchronization.html>
- "Run an individual transactor per active database" —
  <https://forum.datomic.com/t/multi-tenancy-databases/238>

**The theorem: consensus in the control plane, a fence in the data plane**

- Vertical Paxos — Lamport, Malkhi & Zhou, PODC 2009 —
  <https://lamport.azurewebsites.net/pubs/vertical-paxos.pdf>
- Delos — "a seal bit does not require fault-tolerant consensus… weaker than
  consensus and not subject to FLP", OSDI 2020 —
  <https://www.usenix.org/system/files/osdi20-balakrishnan.pdf>
- Aurora — "storage nodes do not have a vote… they must do so"; "rather than
  waiting for a lease to expire, just changes the locks on the door", SIGMOD 2018
  — <https://pages.cs.wisc.edu/~yxy/cs839-s20/papers/aurora-sigmod-18.pdf>
- CORFU — the sequencer "is merely an optimization… not required for either
  safety or progress", NSDI 2012 —
  <https://www.usenix.org/system/files/conference/nsdi12/nsdi12-final30.pdf>
- Apache BookKeeper — "a ledger has a single writer and multiple readers";
  "leader election is really leader suggestion… it is the job of the log to
  guarantee that only one can write changes to the system" —
  <https://bookkeeper.apache.org/docs/development/protocol/>; the 2021 TLA+
  data-loss finding — <https://github.com/apache/bookkeeper/issues/2614>
- FoundationDB — Active Disk Paxos for coordinators only; singletons "are not
  performance bottlenecks"; "consistent reads do require obtaining a read version
  from the primary data center"; median recovery 3.08 s, p90 5.28 s over 289
  production reconfigurations — <https://www.foundationdb.org/files/fdb-paper.pdf>
- CockroachDB — HLC, 500 ms `--max-offset`, self-termination at 80% skew against
  half the cluster, serializable but explicitly **not** strictly serializable —
  <https://www.cockroachlabs.com/docs/stable/architecture/transaction-layer>,
  <https://www.cockroachlabs.com/blog/consistency-model/>

**Fencing, leases and object storage**

- Kleppmann, *How to do distributed locking* — the GC-pause argument, "you cannot
  fix this problem by inserting a check on the lock expiry just before writing
  back to storage", and "this requires the storage server to take an active role
  in checking tokens" —
  <https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html>
- Chubby's *sequencer* and lock generation number, the same idea in 2006 —
  <https://static.googleusercontent.com/media/research.google.com/en//archive/chubby-osdi06.pdf>
- Gray & Cheriton, *Leases*, SOSP 1989 —
  <https://web.stanford.edu/class/cs240/readings/leases.pdf>
- SlateDB `writer_epoch` — "a monotonically increasing u64 that is
  transactionally incremented by a writer on startup"; "a zombie writer is a
  writer with an epoch that is less than the `writer_epoch` in the current
  manifest" —
  <https://raw.githubusercontent.com/slatedb/slatedb/main/rfcs/0001-manifest.md>
  (SlateDB is the store named in this repo's own `mix.exs` deps comment)
- Neon generation numbers — "enables strong anti-split-brain properties… without
  implementing a consensus mechanism directly in the pageservers" —
  <https://github.com/neondatabase/neon/pull/4919>
- S3 conditional writes: `If-None-Match` (2024-08-20) —
  <https://aws.amazon.com/about-aws/whats-new/2024/08/amazon-s3-conditional-writes/>;
  `If-Match` (2024-11-25) —
  <https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-s3-functionality-conditional-writes/>;
  the "non-conditional operations can bypass conditional logic" caveat —
  <https://aws.amazon.com/blogs/storage/building-multi-writer-applications-on-amazon-s3-using-native-controls/>
- The ~10–15 conditional writes/sec ceiling on a hot key — Chris Douglas,
  *Conditional Operations in Object Stores*, 2026-01-30 —
  <https://cdouglas.github.io/posts/2026/01/conditional>

**Why not eventual consistency**

- Jepsen on Riak: 71% of acknowledged writes lost on a healthy, fully-connected
  cluster; 92% at `PR=PW=R=W=quorum` — <https://aphyr.com/posts/285-jepsen-riak>
- "Last write wins, except when it doesn't, but even then it does… there is no
  reliable definition of 'last write'" — Basho, 2013 —
  <https://riak.com/posts/technical/clocks-are-bad-or-welcome-to-distributed-systems/>
- DynamoDB "shared most of the name of the previous Dynamo system but little of
  its architecture"; Multi-Paxos; "only the leader replica can serve write and
  strongly consistent read requests", USENIX ATC 2022 —
  <https://www.usenix.org/system/files/atc22-elhemali.pdf>
- Alquraan et al., *An Analysis of Network-Partitioning Failures in Cloud
  Systems*, OSDI 2018 — 88% reachable by isolating one node, 29% partial
  partitions — <https://www.usenix.org/system/files/osdi18-alquraan.pdf>

**Erasure, keys and the law**

- Cloud KMS key states: default 30 days scheduled-for-destruction, minimum 24 h,
  maximum 120 days, set at creation only —
  <https://cloud.google.com/kms/docs/key-states>
- "Key material can remain in Google systems for up to 45 days from the scheduled
  destruction time" — <https://cloud.google.com/kms/docs/destroy-restore>
- Enable is strongly consistent, **disable is eventually consistent**; "when you
  perform cryptographic operations… consensus is not required" —
  <https://cloud.google.com/kms/docs/consistency>,
  <https://cloud.google.com/kms/docs/locations>
- NIST SP 800-88r1 §2.6, §2.6.3 — Cryptographic Erase, and "sanitization using CE
  should not be trusted on devices that have been backed-up or escrowed the
  key(s)" —
  <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r1.pdf>
- WP29 Opinion 05/2014 — key-deletion encryption is **pseudonymisation, not
  anonymisation** —
  <https://ec.europa.eu/justice/article-29/documentation/opinion-recommendation/files/2014/wp216_en.pdf>
- EDPB Guidelines 02/2025 ¶51 (unintelligible "at least until the algorithm is
  broken"), ¶53 (perfectly hiding commitments), ¶96 (standing reassessment) —
  <https://www.edpb.europa.eu/system/files/2026-07/edpb_guidelines_202502_blockchain_v2_en.pdf>
- Amazon QLDB redaction — physical delete-in-place preserving the journal hash
  chain, chosen instead of crypto-shredding —
  <https://docs.aws.amazon.com/qldb/latest/developerguide/what-is.html>

**Within this repo**

- `.research/failure-modes.md` — C1 (client-writable name, future-pinned
  transaction), C2 (`Controller.named/2` permutation), C4 (eviction stops
  sealing), C5 (`:erased` is indistinguishable from corruption), C10 (formula
  cache serves plaintext after erasure), and finding 5 (backup retention makes
  crypto-shredding reversible by the controller). Every "gets worse distributed"
  note in §1.8 refers to those entries.
- `.monty/ontology.db` — doctrine 6, 7, 8, 16, 17, 18, 20; words `led`, `snp`,
  `snp.name`, `opn`, `wrt`, `wch`.

**Not found, and recorded as gaps**

- No official Datomic statement, either way, on cross-database point-in-time
  consistency. §2.1's conclusion is inference from documented per-database
  scoping, not a quotable denial.
- No published per-operation latency figures for `ra` as a library; everything
  quantitative comes from RabbitMQ quorum-queue benchmarks.
- No Jepsen analysis of Mnesia, `:global`, or Horde exists. Do not attribute one.
- The ICO's 2025 encryption guidance addresses encryption-with-key-retained and
  is silent on the destroyed-key case — neither for nor against.
