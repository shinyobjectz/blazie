# Write throughput of one ledger

*Measured 2026-08-13. Every number here came out of `test/throughput_test.exs`;
nothing in this file was typed by hand.*

## Read this first: two revisions

The investigation started at **`26b7d3b`**. Halfway through it, a parallel
stream landed `03a3302` ("a ledger stopped getting slower the longer it ran")
and `75bdf3f`, which fixed the single biggest thing measured here. So every
table below has two columns, and they are labelled:

| | |
|---|---|
| **before** | `26b7d3b` — every append copied the whole fact list |
| **after** | `75bdf3f` — facts kept newest-first and prepended; checkpoints on geometric growth |

The "before" numbers are kept because they are the mechanism, not history: they
say what the ceiling of a serialised ledger is when the serialised work is
O(history), and that shape will come back the next time something is added to
the append path.

## The answer

**Before:** a single ledger sustained ~100,000 txn/s while small, falling
linearly with what it already held — 3 µs of service time per thousand resident
facts. 3,300 txn/s at 100k facts; 360 at a million.

**After:** append is flat. **2–5 µs per transaction at every size from a
thousand facts to two million**, a serial ceiling of 120,000–200,000 txn/s that
does not move as the ledger grows, and about 1.0–1.3 M facts/s at a batch of
100 or more.

Three things are true of both revisions and are the durable findings:

1. **Serialisation was never the problem.** 128 writers against one ledger cost
   nothing in throughput — before *or* after. A GenServer mailbox is a queue and
   it behaves like one: no convoy, no collapse, no starvation, and the p99/p50
   ratio *improves* as writers pile up. What cost anything was the service time
   inside the lock.
2. **Nothing ever timed out.** Not once, at any writer count, ledger size, or
   fsync setting, in seven full runs. Reaching the 5-second `GenServer.call`
   default needed ~16,700 concurrent writers before the fix and ~1,000,000
   after. An SLO breaks two orders of magnitude earlier than a timeout does.
3. **Memory did not change and is now the binding constraint.** 241 bytes per
   resident fact, flat, of which **87% is the three sort orders**. That is what
   decides how big a ledger can get, and the fix did not touch it.

---

## The machine

| | |
|---|---|
| Host | Apple M4, 10 cores (10 schedulers, 10 dirty-CPU) |
| Memory | 16 GB |
| OS | macOS 15.6 (Darwin 24.6.0) |
| Erlang | OTP 29, erts-17.0.5, JIT |
| Elixir | 1.20.3 |
| Disk | internal APFS SSD; ledger files under `System.tmp_dir!()` |

Both revisions were measured in detached worktrees, so a concurrent edit to
`lib/` could not move underneath a run. Times are microseconds unless labelled.
Every row is a percentile over the measured appends, never a mean — a mean
hides precisely the tail this was written to find. Each configuration discards
a warmup round.

Reported figures are from run 3 of 4 (before) and run 2 of 3 (after); where
runs disagreed by more than noise it is said so in the text. One earlier "after"
run was discarded outright: it was taken while another compile was running on
the same box and every latency in it is inflated.

## Reproducing

    export PATH="/opt/homebrew/opt/erlang/bin:$PATH"   # or run everything via `just`
    mix test --include throughput test/throughput_test.exs --seed 0 --trace

One section at a time:

    mix test --include throughput test/throughput_test.exs:166   # batch size, fsync
    mix test --include throughput test/throughput_test.exs:282   # growth
    mix test --include throughput test/throughput_test.exs:370   # concurrency
    mix test --include throughput test/throughput_test.exs:479   # many ledgers
    mix test --include throughput test/throughput_test.exs:541   # read while writing
    mix test --include throughput test/throughput_test.exs:617   # checkpoints, cliffs
    mix test --include throughput test/throughput_test.exs:730   # memory

`:throughput` is excluded by default in `test/test_helper.exs`, alongside
`:load`, `:crash` and `:object_storage`. The whole file takes 27 s at `75bdf3f`
and 75 s at `26b7d3b` — the difference is itself a result.

To pin a revision the way these runs did:

    git worktree add --detach /tmp/bench <rev>
    cp test/throughput_test.exs test/test_helper.exs /tmp/bench/test/
    cd /tmp/bench && mix test --include throughput test/throughput_test.exs

---

## 1. Batch size

10,000 facts written to a fresh ledger every time, so each row walks the ledger
through the same range of sizes and only the transaction count changes.

| store | facts/txn | txn/s before | txn/s after | facts/s before | facts/s after | p50 before | p50 after |
|---|---|---|---|---|---|---|---|
| memory | 1 | 53,686 | **369,031** | 53,686 | 369,031 | 10 | 2 |
| memory | 10 | 33,471 | **107,840** | 334,706 | 1,078,400 | 17 | 5 |
| memory | 100 | 10,279 | 13,135 | 1,027,855 | 1,313,543 | 65 | 65 |
| memory | 1000 | 800 | 1,230 | 800,320 | 1,229,710 | 1199 | 727 |
| file | 1 | 15,866 | **191,172** | 15,866 | 191,172 | 31 | 4 |
| file | 10 | 19,535 | **54,535** | 195,347 | 545,345 | 39 | 15 |
| file | 100 | 6,770 | 9,436 | 677,002 | 943,574 | 128 | 91 |
| file | 1000 | 909 | 1,010 | 908,595 | 1,009,999 | 1094 | 947 |

Peak fact rate is **1.0–1.3 M facts/s**, reached at a batch of 100 and flat
after that: the per-fact work (build the struct, seal it, three index updates)
dominates, and only the fixed per-transaction cost is being amortised. The fix
shows up almost entirely at batch 1, because that is the only column where the
ledger grows enough *during* the measurement for the old code to be paying for
it: 10,000 transactions to write 10,000 facts. The `file / 1` row is also the
noisiest cell in the suite — 15.9k–39.9k txn/s across "before" runs, max latency
0.4–9 ms — because 10,000 separate `:file.write/2` calls interact with
page-cache flushing.

`p99` at batch 1000 runs 1.3–2.7× the p50 in both revisions; large batches have
a wide spread because a thousand-fact append is long enough to be interrupted.

### What an fsync costs

2,000 facts per configuration, because at batch 1 this is one fsync per fact
and the fsync is the measurement rather than something to amortise.

| facts/txn | txn/s no sync | txn/s sync | **ratio** | p50 delta |
|---|---|---|---|---|
| **before** ||||
| 1 | 77,140 | 4,604 | **16.8×** | +129 µs |
| 10 | 39,635 | 5,437 | **7.3×** | +145 µs |
| 100 | 8,850 | 2,855 | **3.1×** | +238 µs |
| 1000 | 1,038 | 883 | **1.2×** | +199 µs |
| **after** ||||
| 1 | 201,207 | 5,436 | **37.0×** | +135 µs |
| 10 | 60,846 | 5,335 | **11.4×** | +155 µs |
| 100 | 10,173 | 2,383 | **4.3×** | +257 µs |
| 1000 | 1,176 | 895 | **1.3×** | +228 µs |

**An fsync on this SSD is 130–260 µs and it is a constant.** That is the whole
story: `sync: true` costs one fixed payment per *transaction*, so the ratio is
entirely a function of how much you put in each one. The synced throughput
column barely moved between revisions — at batch 1 it is 4,604 then 5,436,
because the ledger was never the cost. Making appends 12× faster made the fsync
ratio *worse* (16.8× → 37×) for exactly that reason.

**The operational reading:** durability is nearly free if you batch and brutal
if you do not. One fact at a time with `sync: true` gets 5,400 txn/s; the same
caller batching a hundred gets 238,000 facts/s. Nothing else in this document
has a 44× lever attached to a single caller-side decision.

---

## 2. What it costs at size — the headline

One single-fact append measured at each size, so the figure is
per-transaction overhead rather than per-fact work. 300 measured appends after
50 discarded.

| resident facts | p50 before | p50 after | serial txn/s before | serial txn/s after |
|---|---|---|---|---|
| 10,000 | 48 µs | **4 µs** | 20,833 | 250,000 |
| 50,000 | 159 µs | **5 µs** | 6,289 | 200,000 |
| 100,000 | 300 µs | **5 µs** | 3,333 | 200,000 |
| 250,000 | 586 µs | **5 µs** | 1,706 | 200,000 |
| 500,000 | 1.44 ms | **6 µs** | 693 | 166,667 |
| 1,000,000 | 2.78 ms | **5 µs** | 360 | 200,000 |
| 2,000,000 | 6.11 ms | **12 µs** | 164 | 83,333 |

**Before**, appending one fact was O(facts already in the ledger), at a stable
2.9–3.0 µs per thousand, in both stores, because it was the same line of code
in both:

    def append(facts, new), do: {:ok, facts ++ new}     # Store.Memory
    facts: state.facts ++ facts                          # Store.File

`list ++ new` copies the entire left spine. At 100k resident that is 100,000
cons cells rebuilt to add one — 1.6 MB copied and immediately garbaged for a
single fact. Filling a ledger to *n* facts one at a time was Θ(n²) work and
Θ(n²) garbage, and the p99/p50 spread widened from 5.8× at 10k to 9.7× at 1 M
as the collector worked through a heap made mostly of dead list spines.

**After**, facts are kept newest-first and prepended, so an append costs the
batch. The line is flat to 2 M facts and the p99 stays within 3× of the p50
everywhere except at 500k+ where a periodic collection shows through
(p99 3.1–4.8 ms against a 5 µs median, once per few hundred appends).

The three sort orders were never the cause: those are map updates, O(log n).

### The one cost that still grows with history

Sealing asks who owns a fact's entity and answers by scanning `by_id[id]` for a
`"subject"` fact. Unique ids make that list one element long. An entity that
accumulates history makes it as long as its history — and with no subject fact
present, the scan never short-circuits.

| shape | facts written | p50 before | p50 after |
|---|---|---|---|
| unique ids | 1,000 | 3 µs | 2 µs |
| unique ids | 10,000 | 9 µs | 2 µs |
| one id | 1,000 | 6 µs | 6 µs |
| one id | 10,000 | **48 µs** | **35 µs** |

**A ledger where every fact is about the same entity is 17× slower at 10k facts
than one where every fact is about a different entity, and the gap grows
linearly.** This survived the fix untouched, and it is now the *only*
per-append cost that grows with what the ledger already holds. It fires on the
shape a real workload most obviously has — one Creator, thousands of posts
about them. At 100k facts on one entity, `owner_of/2` alone extrapolates to
~330 µs per fact, which puts a hot-entity ledger back where the whole ledger
was before the fix.

---

## 3. Many writers, one ledger

The same 2,560 appends in every row, so the server does identical work and only
the queue in front of it changes. `GenServer.call` at its 5-second default.

**Empty ledger:**

| writers | txn/s before | txn/s after | p50 before | p50 after | p99 after | timeouts |
|---|---|---|---|---|---|---|
| 1 | 103,803 | 98,903 | 7 | 6 | 40 | **0** |
| 2 | 116,253 | 178,846 | 14 | 8 | 43 | **0** |
| 8 | 116,464 | 183,407 | 64 | 37 | 190 | **0** |
| 32 | 93,118 | 169,570 | 317 | 165 | 584 | **0** |
| 128 | 80,216 | 132,539 | 1,557 | 859 | 1,690 | **0** |

**100,000 facts already resident:**

| writers | txn/s before | txn/s after | p50 before | p50 after | p99 after | timeouts |
|---|---|---|---|---|---|---|
| 1 | 2,576 | **174,947** | 300 | 5 | 11 | **0** |
| 2 | 2,631 | **113,169** | 590 | 9 | 40 | **0** |
| 8 | 2,554 | **204,849** | 3,006 | 34 | 70 | **0** |
| 32 | 2,618 | **163,161** | 12,077 | 171 | 1,083 | **0** |
| 128 | 2,618 | **116,147** | 48,751 | 891 | 2,775 | **0** |

**This degrades gracefully, and it did so even at its worst.** Throughput is
flat across a 128× change in writer count in every configuration measured —
2,554–2,631 txn/s before, 113k–205k after. There is no collapse, no thrash, no
convoy. Latency is exactly `writers × service time`, and the p99/p50 ratio
*falls* as writers climb (1.03 at 128 writers before the fix) because the queue
becomes the whole cost and the queue is uniform.

The 128-writer rows lose ~25% of peak throughput to scheduler and mailbox
overhead. That is the only sign of stress anywhere in this table.

The fix's effect is the second table read across: **a 100k-fact ledger under
128 writers went from 48.8 ms per append to 891 µs, and from 2,618 txn/s to
116,147.** A 44× throughput change with no change to the concurrency model at
all.

### Where the 5-second timeout arrives

Latency at the back of the queue is queue depth × service time, so the pair
that breaks is a curve, not a number.

| resident facts | writers for a 5 s timeout, before | after | writers for a 100 ms p50, before | after |
|---|---|---|---|---|
| 10,000 | 104,167 | 1,250,000 | 2,083 | 25,000 |
| 100,000 | 16,667 | 1,000,000 | 333 | 20,000 |
| 500,000 | 3,463 | 833,333 | 69 | 16,667 |
| 1,000,000 | 1,799 | 1,000,000 | 36 | 20,000 |
| 2,000,000 | 818 | 416,667 | 16 | 8,333 |

**The `GenServer.call` timeout is not a real limit and never was.** Nothing
timed out in any run. Even before the fix, reaching one required 16,667
simultaneous writers on a 100k-fact ledger — and a node with 16,667 processes
blocked on one ledger has a problem that a timeout is a symptom of rather than
a cause. After the fix the number is a million, which is to say: not a limit.

---

## 4. Many ledgers, in parallel

1,000 appends of 10 facts to each ledger, all concurrently, memory store.

| ledgers | facts/s total before | after | speedup before | after |
|---|---|---|---|---|
| 1 | 262,992 | 960,892 | 1.0× | 1.0× |
| 2 | 410,139 | 1,165,433 | 1.6× | 1.2× |
| 4 | 467,333 | 1,852,881 | 1.8× | 1.9× |
| 8 | 1,139,195 | **3,972,984** | 4.3× | 4.1× |
| 16 | 1,777,699 | **4,229,112** | 6.8× | 4.4× |
| 64 | 1,361,792 | 3,367,358 | 5.2× | 3.5× |

This is the noisiest table in the document — the 64-ledger speedup landed at
6.6×, 4.6× and 5.2× across three "before" runs and 4.2×, 3.5×, 3.6× across
three "after" ones. The shape is stable even so: **the design does scale
horizontally by ledger, saturating between 8 and 16 ledgers on a 10-core box
and gaining nothing after that.** Aggregate peak went from 1.8 M facts/s to
**4.2 M facts/s**.

The *speedup ratio* got worse after the fix purely because the single-ledger
baseline got 3.7× faster; absolute throughput more than doubled at every count.
4× rather than 10× on 10 cores is memory-bandwidth and GC, not CPU. The claim
"one ledger is serial but ledgers are independent" holds; the claim "N ledgers
give N× throughput" does not, past the core count.

---

## 5. Reading while writing

20,000-fact ledger, file store. Writers hammer single-fact appends in a loop
while a reader takes 200 timed `find_at/3` calls.

| read | writers | read p50 before | read p50 after | writers' own p50 after |
|---|---|---|---|---|
| by id (1 fact) | 0 | 2 | 2 | — |
| by id (1 fact) | 1 | 73 | **6** | 6 |
| by id (1 fact) | 8 | 647 | **47** | 49 |
| by id (1 fact) | 32 | 3,134 | **170** | 171 |
| by attribute (all 20k) | 0 | 1,234 | 1,262 | — |
| by attribute (all 20k) | 1 | 1,508 | 1,297 | 5 |
| by attribute (all 20k) | 8 | 2,130 | 1,324 | 44 |
| by attribute (all 20k) | 32 | 4,562 | 1,571 | 1,433 |

**Yes, `find_at/3` contends with writers, completely, in both revisions.** It is
a `GenServer.call` on the same process, so a read does not contend for a lock —
it takes a turn. An indexed read costing 2 µs of server time takes 170 µs wall
with 32 writers running, having done no more work. The reader is not slow; it
is waiting.

Note how tightly the read and write rows track each other — 170 vs 171 at 32
writers. There is exactly one queue and everyone in it is equal: no priority
inversion, no starvation, and a reader cannot be starved by writers or vice
versa. That is worth stating positively.

The expensive direction is unchanged, and relatively it got much worse:

| facts in ledger | `find_at(attribute:)` p50 before | after | appends it displaces, before | after |
|---|---|---|---|---|
| 10,000 | 651 µs | 657 µs | 16 | **131** |
| 100,000 | 6,992 µs | 7,149 µs | 22 | **1,430** |
| 500,000 | 34,501 µs | 33–115 ms | 28 | **6,598** |

**A whole-attribute read of a 500k-fact ledger still stops every writer for
33 ms or more, and now that appends cost 5 µs it displaces 6,598 of them
instead of 28.** Reads and writes draw on one budget; the fix made writes cheap
and left reads exactly where they were, so wide reads went from 3% of the
problem to essentially all of it. A dashboard that polls a wide query is a
write outage on a schedule.

The 500k figure is also newly unstable — 33 ms, 73 ms and 115 ms across three
runs, against a rock-steady 34 ms before. The list is now built by prepending
into a heap that is collected rarely, so how fast 500,000 cons cells traverse
depends on where the last collection left them.

---

## 6. Two cliffs

### The checkpoint stalls the ledger for as long as it takes to write everything

A checkpoint serialises **every fact ever written** to a sidecar, inside
`handle_call`, so the ledger is stopped for the duration and every queued
writer waits.

| resident facts | p50 before | max before | p50 after | max after | sidecar size |
|---|---|---|---|---|---|
| 10,000 | 43 µs | **3.96 ms** | 7 µs | **3.09 ms** | 1.1 MB |
| 100,000 | 322 µs | **30.5 ms** | 5 µs | **31.1 ms** | 10.0 MB |
| 500,000 | 1.48 ms | **113 ms** | 5 µs | **302 ms** | 48.7 MB |

The sidecar is the same size as the log it exists to avoid re-reading — ~96
bytes per fact, both. `03a3302` changed *when* one is written: from a fixed
count of transactions (`checkpoint_every: 1000`, which
`Ledger.default_store/0` still sets for every production deployment) to a
geometric rule — write one when the un-checkpointed tail reaches half of what
is already checkpointed. Total checkpoint bytes went from O(n²) to O(n).

The p99 column tells that story: **6,299 µs before, 22–48 µs after**, because
checkpoints are now rare. Counted directly, with `checkpoint_every: 1000` set
throughout:

| workload | checkpoints written | old policy would have written |
|---|---|---|
| 16,000 single-fact appends from empty | **7** | 16 |
| 4,000 single appends onto 100k facts loaded in 5,000-fact batches | **1** | 4 |
| 4,000 single appends onto 100k facts loaded in 100-fact batches | **0** | 4 |

But each individual stall is as bad or worse — 216–302 ms at 500k facts, up to
60,000× the median append. It is the only tail in this document more than 10×
its median, and it is now a rare enormous pause rather than a frequent large
one, which is the better trade and still a real one. At 2 M facts the stall
extrapolates past 1.2 s.

### Bounding memory unbounds reads

`resident:` evicts old facts from the ledger's list and sort orders. What was
evicted is then answered by `evicted/3`, which calls
`state.module.replay(state.store)` and filters the result — and
`Store.File.replay/1` hands back every fact it ever loaded, with no index at
all.

| resident bound | facts | actually resident | `find_at(id:)` before | after |
|---|---|---|---|---|
| `:unbounded` | 100,000 | 100,001 | **2 µs** | **2 µs** |
| `1_000` | 100,000 | 5,001 | **1,622 µs** | **2,074 µs** |

**Bounding a ledger to 1% of its facts makes its most selective read 1,000×
slower**, and since that read runs in the same call queue as the writes, it
costs the writers too. The setting that exists to make a large ledger
affordable is the setting that makes reading one unaffordable. It got slightly
worse after the fix, because `replay/1` now reverses the list on every call.

---

## 7. Memory — unchanged, and now the binding constraint

Process heap is what the VM reserved, not what is live: it grows in steps and a
collection does not return the slack. The live figure has to be taken *inside*
the ledger, because the five references to each fact (`facts`, `by_id`,
`by_attribute`, `by_value`, `store.facts`) share one copy there — and
`:sys.get_state/1` copies the state out, flattening exactly the sharing being
counted.

| facts | live in process | live B/fact | of which the 3 sort orders | heap/live | B/fact once copied out |
|---|---|---|---|---|---|
| 1,000 | 239,920 | **239.9** | 207,504 (86%) | 1.55 | 527.9 |
| 10,000 | 2,410,672 | **241.1** | 2,090,256 (87%) | 1.71 | 529.1 |
| 100,000 | 24,068,592 | **240.7** | 20,868,176 (87%) | 0.99–1.43 | 528.7 |

Identical to three significant figures before and after the fix; nothing in
`03a3302` touched what a fact costs.

**A resident fact costs 241 bytes, flat, and 87% of that is the three sort
orders.** The two list spines holding it are 32 bytes exactly — two cons cells;
the fact itself plus the price of being findable three ways is the other 209.
Heap runs 1.0–2.8× live depending on where the last collection landed — for
capacity planning, **budget 500 B/fact of RSS**, not 241.

The last column is the one nobody plans for: the same state weighs **529
bytes/fact** once copied out of the process, because five shared references
become five facts. Every reply a ledger sends pays a version of that. It is why
`find_at/3` filters server-side, and why `facts_at/2` on a large ledger is a bad
idea independent of how long the server takes.

### What `resident:` actually saves

| resident bound | facts written | ledger's list | store's list | live | live B/fact written |
|---|---|---|---|---|---|
| `:unbounded` | 100,000 | 100,000 | 100,000 | 22.97 MB | 240.8 |
| `10_000` | 100,000 | 13,300 | **100,000** | 10.32 MB | 108.2 |
| `1_000` | 100,000 | 1,000 | **100,000** | 8.54 MB | 89.5 |

**`resident: 1_000` on a 100,000-fact ledger holds 100,000 facts.** It trims the
ledger's own list and rebuilds the sort orders — 63% of the bytes — but
`Store.File` never drops anything, so memory still grows linearly with
everything ever written, at 89.5 B/fact instead of 240.8. The floor is the
store, and there is no setting for it.

---

## Where this breaks

Stated plainly, in the order the failures arrive. Everything here is `75bdf3f`
unless it says otherwise.

### Facts per ledger

**A single ledger now stops working somewhere around 5–6 million facts, and the
symptom is memory. Before the fix it was 500,000–1,000,000 and the symptom was
latency.** The fix moved the ceiling by roughly an order of magnitude and
changed which wall you hit.

| facts/ledger | append p50 | serial ceiling | live | verdict |
|---|---|---|---|---|
| 10,000 | 4 µs | 250,000 txn/s | 2.4 MB | comfortable |
| 100,000 | 5 µs | 200,000 txn/s | 24 MB | comfortable |
| 500,000 | 6 µs | 167,000 txn/s | 120 MB | **wide reads now cost 33–115 ms** |
| 1,000,000 | 5 µs | 200,000 txn/s | 241 MB | writes fine; a checkpoint stalls ~600 ms |
| 2,000,000 | 12 µs | 83,000 txn/s | 482 MB | writes fine; everything else is not |
| ~6,000,000 | ~15 µs | ~70,000 txn/s | ~1.4 GB | **the memory wall on a 4 GB box** |

The write path no longer degrades. What degrades is everything that touches the
whole ledger: a wide `find_at`, a checkpoint, a full GC of a multi-gigabyte
heap, and `Ledger.resident/1`. Each of those runs inside the same call, so each
is a stall for every writer.

**On a 4 GB box.** At 500 B/fact of RSS (241 live, times observed heap slack,
and a copying major GC needs room to allocate the new heap alongside the old),
3 GB of usable space is about **6 million facts across every ledger on the
node**. A single ledger holding 6 M still appends in ~15 µs — but it pauses for
hundreds of milliseconds on every full sweep of its heap, its checkpoint sidecar
is 570 MB and takes over a second to write, and one `find_at(attribute:)`
against it stops the world for something on the order of half a second.

**So: the practical per-ledger limit is ~1 M facts, set by the stalls, and the
absolute limit is ~6 M, set by RAM.** Before the fix both numbers were
500k–1 M and set by the append itself.

### Writers per ledger

**There is no writer count at which this collapses, and no realistic writer
count at which anyone times out.** Throughput is flat from 1 to 128 writers in
every configuration measured, before and after. What degrades is per-caller
latency, linearly and predictably:

| ledger size | 8 writers | 32 writers | 128 writers | writers for a 5 s timeout |
|---|---|---|---|---|
| empty | 37 µs | 165 µs | 859 µs | ~1,000,000 |
| 100,000 facts | 34 µs | 171 µs | 891 µs | ~1,000,000 |
| 2,000,000 facts | 96 µs (calc.) | 384 µs | 1.5 ms | ~417,000 |

Pick the limit from an SLO, not from the timeout. **For a 100 ms p50 budget:
about 20,000 writers per ledger at any size up to a million facts** — which is
to say, more writers than a node will have processes. Zero callers timed out
anywhere in this suite, in seven full runs.

The honest framing after the fix: **writers-per-ledger is no longer a limit
worth tracking.** Facts-per-ledger is.

### The four sharpest edges that remain

1. **A wide read is a write outage, and now it is the dominant cost.**
   `find_at(attribute: …)` on a 500k-fact ledger occupies the process for
   33–115 ms, during which no append can proceed — 6,598 appends' worth. Before
   the fix it displaced 28. This is the single largest remaining item.
2. **A checkpoint at 500k facts stops the ledger for 302 ms** and writes
   48.7 MB. Rarer than it was (p99 fell from 6.3 ms to 24 µs) but individually
   worse, and it extrapolates past 1.2 s at 2 M facts.
3. **A ledger whose facts are mostly about one entity is 17× slower at 10k
   facts** and degrades linearly, because `seal/2` scans that entity's whole
   history per fact. This is now the *only* per-append cost that grows with
   history, and it fires on the most obvious real-world shape.
4. **`resident:` makes reads 1,000× slower and only saves 63% of the memory**,
   because `Store.File` never forgets. The lever for the memory wall is the
   lever that breaks reads.

---

## What turned up in `lib/` along the way

Found while measuring. **Reported, not fixed**, per the terms of this work. All
five were verified against `75bdf3f` and all five are still present there.

### 1. A malformed read pattern kills the ledger and its facts — `ledger.ex:330`, `fact.ex:83`

`Fact.matches?/2` does `Map.fetch!(fact, key)`, so a pattern key that is not a
`Fact` field raises `KeyError` — inside `handle_call`, which takes the
GenServer down.

    Ledger.find_at(ledger, tx, subject: "someone")   # "subject" is an attribute, not a field

    ** (KeyError) key :subject not found in: %Blazie.Fact{...}
       lib/blazie/fact.ex:51: Blazie.Fact."-matches?/2-fun-0-"/2
       lib/blazie/ledger.ex:330: Blazie.Ledger.handle_call/3

*(trace taken at `26b7d3b`; at `75bdf3f` the same line is `fact.ex:83`.)*

Verified: the ledger process is dead 50 ms later and, with `Store.Memory`,
every fact is gone. **A read destroys a writer's data**, and the confusion that
triggers it is an easy one — `"subject"` is a real attribute name in `Erasure`,
just not a field of `Fact`. It also contradicts the house rule that errors are
data with the repair attached: this boundary rejects by crashing.

### 2. `check:` does not run on the serialised path — `ledger.ex:203-215`

The docstring says: *"The ledger applies the check without knowing what one is
— it holds the one serialized path every write goes through, and that is the
only reason the check belongs here."* It does not. `checked_append/3` calls
`check.(assertions)` in the **caller's** process and only then makes the
`GenServer.call`.

Verified two ways. The check reports `self() != ledger_pid`. And a uniqueness
check that should admit exactly one of two concurrent writers admits both:

    both writers: [ok: 1, ok: 2]
    facts that got through a one-at-a-time check: 2

Any check that reads the ledger to decide is a TOCTOU race. The fix is
mechanical — send the function with the append and apply it in `handle_call` —
and the current placement means the one guarantee the docstring is selling does
not exist.

### 3. `Store.File` is a memory store that also writes to disk — `store.ex:150-175`

`append/2` keeps every fact in `state.facts` and `replay/1` returns the whole
list. The file is written but never read again after open. Consequences, all
measured above: `resident:` saves 63% rather than 99% (§7); a bounded ledger's
indexed read costs 2.1 ms instead of 2 µs because `evicted/3` re-scans
everything (§6); and the moduledoc's *"it only saves anything when the facts are
durable somewhere else"* is two-thirds true — durability is not the missing
piece, a store that can forget is.

This is the direct cause of the memory wall in "Where this breaks", and it is
the one remaining structural item of the same class as the `++` that
`03a3302` fixed.

### 4. A checkpoint newer than its log crashes `open/2` — `store.ex:269`

    binary |> binary_part(offset, byte_size(binary) - offset)

If the checkpoint's recorded offset exceeds the current file size — a log
restored from an older backup, or truncated — the length goes negative and
`binary_part/3` raises `ArgumentError` from inside `Ledger.init/1`, so the
ledger cannot start. Verified by truncating a log with a live sidecar:

    ** (ArgumentError) errors were found at the given arguments: ... -5250
       lib/blazie/store.ex:208: Blazie.Store.File.read_from/2
       lib/blazie/store.ex:101: Blazie.Store.File.open/2

*(trace taken at `26b7d3b`; at `75bdf3f` the same line is `store.ex:269`.)*

`read_checkpoint/1` carefully falls back when the sidecar is missing or corrupt,
but this failure happens after it returns, so the fallback never fires. A
`min(offset, byte_size(binary))` would degrade it to the intended "read from the
start, just slower".

### 5. Smaller things

- `Ledger.resident/1` is `length(state.facts)` — an O(n) public read that runs
  inside the ledger (`ledger.ex:314`). At 2 M facts it stalls every writer for
  the length of a list walk, and it is called by the load suite.
- `evicted/3` ignores the pattern's index entirely and full-scans. The moduledoc
  calls this "honest rather than good", which it is — the number is in §6.
- `Store.File.replay/1` and `Store.Memory.replay/1` now reverse the whole list
  on every call (`store.ex:51`, `store.ex:172`). Correct, and cheap next to what
  the caller then does with it, but it makes `evicted/3` two passes instead of
  one and it is called per read on every bounded ledger.
