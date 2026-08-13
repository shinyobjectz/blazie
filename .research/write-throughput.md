# Write throughput of one ledger

*Measured 2026-08-13 against `26b7d3b`. Every number here came out of
`test/throughput_test.exs`; nothing in this file was typed by hand.*

## What was asked and what the answer is

A ledger is a GenServer, so every append to one ledger serialises through one
process. Nobody had measured the ceiling. Here it is, in one line: **a single
ledger sustains roughly 100,000 transactions per second while it is small, and
that rate falls linearly with how many facts it is already holding — about
3 µs of service time per thousand resident facts.** At 100k facts it is
3,300 txn/s. At a million it is 360. Serialisation is not what limits it and
the 5-second `GenServer.call` timeout is never reached; **what limits it is
that the whole ledger is copied on every append**, and what eventually kills
it is memory.

The three things worth knowing before reading the tables:

1. **Concurrency is free and size is not.** 128 writers against a small ledger
   cost nothing in throughput. One writer against a 1M-fact ledger costs 2.8 ms
   per append. The queue is not the problem; the service time is.
2. **`resident:` bounds the ledger's memory but not the store's**, because
   `Store.File` keeps every fact it ever read in the same process. It saves
   63% of the bytes, not the 99% the setting suggests — and it makes an indexed
   read 800× slower.
3. **Not one caller timed out anywhere in this suite**, at any writer count, at
   any ledger size, with fsync on or off. A timeout would need ~16,700
   concurrent writers on a 100k-fact ledger.

## The machine

| | |
|---|---|
| Host | Apple M4, 10 cores (10 schedulers, 10 dirty-CPU) |
| Memory | 16 GB |
| OS | macOS 15.6 (Darwin 24.6.0) |
| Erlang | OTP 29, erts-17.0.5, JIT |
| Elixir | 1.20.3 |
| Disk | internal APFS SSD; ledger files under `System.tmp_dir!()` |
| Revision | `26b7d3b`, measured in a detached worktree so a concurrent edit to `lib/` could not move underneath the run |

Times are microseconds unless labelled. Every row is a percentile over the
measured appends, never a mean — a mean hides precisely the tail this was
written to find. Each configuration discards a warmup round.

## Reproducing

    export PATH="/opt/homebrew/opt/erlang/bin:$PATH"   # or run everything via `just`
    mix test --include throughput test/throughput_test.exs --seed 0 --trace

One section at a time:

    mix test --include throughput test/throughput_test.exs:166   # batch size
    mix test --include throughput test/throughput_test.exs:282   # growth
    mix test --include throughput test/throughput_test.exs:370   # concurrency
    mix test --include throughput test/throughput_test.exs:479   # many ledgers
    mix test --include throughput test/throughput_test.exs:541   # read while writing
    mix test --include throughput test/throughput_test.exs:730   # memory

`:throughput` is excluded by default in `test/test_helper.exs`, alongside
`:load`, `:crash` and `:object_storage`. The whole file takes about 75 seconds.

To pin the revision the way this run did:

    git worktree add --detach /tmp/bench HEAD
    cp test/throughput_test.exs test/test_helper.exs /tmp/bench/test/
    cd /tmp/bench && mix test --include throughput test/throughput_test.exs

---

## 1. Batch size, and what an fsync costs

10,000 facts written to a fresh ledger every time, so each row walks the ledger
through the same range of sizes and only the transaction count changes.

| store | facts/txn | txns | txn/s | facts/s | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|---|
| memory | 1 | 10000 | 53,686 | 53,686 | 10 | 70 | 122 | 754 |
| memory | 10 | 1000 | 33,471 | 334,706 | 17 | 106 | 188 | 280 |
| memory | 100 | 100 | 10,279 | 1,027,855 | 65 | 229 | 266 | 266 |
| memory | 1000 | 10 | 800 | 800,320 | 1199 | 2139 | 2139 | 2139 |
| file, sync:false | 1 | 10000 | 15,866 | 15,866 | 31 | 161 | 630 | 8959 |
| file, sync:false | 10 | 1000 | 19,535 | 195,347 | 39 | 127 | 176 | 540 |
| file, sync:false | 100 | 100 | 6,770 | 677,002 | 128 | 301 | 565 | 565 |
| file, sync:false | 1000 | 10 | 909 | 908,595 | 1094 | 1418 | 1418 | 1418 |

Peak fact rate is about **1.0 M facts/s**, reached anywhere between a batch of
100 and a batch of 1000. Batching past 100 buys little: the per-fact work
(build the struct, seal it, three index updates) dominates, and only the fixed
per-transaction cost — one file write, one term encode, one message round trip
— is being amortised.
The `file sync:false` batch-1 row is the noisiest cell in the whole suite
(15.9k–39.9k txn/s across runs, max latency 0.4–9 ms) because 10,000 separate
`:file.write/2` calls interact with page-cache flushing.

### fsync

2,000 facts per configuration, because at batch 1 this is one fsync per fact
and the fsync is the measurement rather than something to amortise.

| store | facts/txn | txn/s | facts/s | p50 | p99 | max |
|---|---|---|---|---|---|---|
| file, sync:false | 1 | 77,140 | 77,140 | 10 | 56 | 169 |
| file, sync:false | 10 | 39,635 | 396,354 | 17 | 99 | 129 |
| file, sync:false | 100 | 8,850 | 884,956 | 103 | 168 | 168 |
| file, sync:false | 1000 | 1,038 | 1,038,422 | 950 | 950 | 950 |
| file, sync:true | 1 | 4,604 | 4,604 | 139 | 851 | 3261 |
| file, sync:true | 10 | 5,437 | 54,370 | 162 | 382 | 431 |
| file, sync:true | 100 | 2,855 | 285,510 | 341 | 455 | 455 |
| file, sync:true | 1000 | 883 | 883,002 | 1149 | 1149 | 1149 |

**The fsync cost, as a ratio:**

| facts/txn | txn/s no sync | txn/s sync | ratio | p50 delta |
|---|---|---|---|---|
| 1 | 77,140 | 4,604 | **16.8×** | +129 µs |
| 10 | 39,635 | 5,437 | **7.3×** | +145 µs |
| 100 | 8,850 | 2,855 | **3.1×** | +238 µs |
| 1000 | 1,038 | 883 | **1.2×** | +199 µs |

An fsync on this SSD is about **130–200 µs**, and it is a constant. That is the
whole story: `sync: true` costs one fixed payment per *transaction*, so the
ratio is entirely a function of how much you put in each one. At one fact per
transaction it is a 17× tax; at a thousand it is 20%. Across runs the batch-1
ratio ranged 16.8–27.3×, tracking how fast the unsynced baseline happened to be.

**The operational reading:** durability is nearly free if you batch, and
brutal if you do not. A caller writing one fact at a time with `sync: true`
gets 4,600 txn/s; the same caller batching a hundred gets 285,000 facts/s.
Nothing else in this document has a 60× lever attached to a single caller-side
decision.

---

## 2. What it costs at size — the number that matters

One single-fact append, measured at each size, so the figure is
per-transaction overhead rather than per-fact work. 300 measured appends after
50 discarded.

| store | resident facts | txn/s | p50 | p95 | p99 | max | µs per 1k resident |
|---|---|---|---|---|---|---|---|
| memory | 1,000 | 163,399 | 4 | 15 | 19 | 65 | 4.0 |
| memory | 10,000 | 30,618 | 26 | 114 | 123 | 128 | 2.6 |
| memory | 100,000 | 2,782 | 279 | 906 | 981 | 985 | 2.79 |
| file, sync:false | 1,000 | 114,723 | 6 | 17 | 22 | 31 | 6.0 |
| file, sync:false | 10,000 | 18,972 | 48 | 132 | 146 | 253 | 4.8 |
| file, sync:false | 100,000 | 2,604 | 298 | 920 | 1019 | 1084 | 2.98 |
| file, checkpoint:1000 | 1,000 | 95,541 | 7 | 21 | 39 | 89 | 7.0 |
| file, checkpoint:1000 | 10,000 | 21,305 | 39 | 112 | 144 | 167 | 3.9 |
| file, checkpoint:1000 | 100,000 | 1,948 | 301 | 1006 | 1242 | **27,911** | 3.01 |

Extended out, single-writer, file store, no checkpoints:

| resident facts | service time p50 | p99 | serial txn/s | process heap |
|---|---|---|---|---|
| 10,000 | 48 µs | 278 µs | 20,833 | 3.9 MB |
| 50,000 | 159 µs | 641 µs | 6,289 | 15.8 MB |
| 100,000 | 300 µs | 1.08 ms | 3,333 | 32.8 MB |
| 250,000 | 586 µs | 6.94 ms | 1,706 | 68.0 MB |
| 500,000 | 1.44 ms | 7.48 ms | 693 | 141.0 MB |
| 1,000,000 | 2.78 ms | 26.9 ms | 360 | 350.9 MB |
| 2,000,000 | 6.11 ms | 42.1 ms | 164 | 606.3 MB |

**Appending one fact is O(facts already in the ledger), at a stable
2.9–3.0 µs per thousand.** Both stores do it and the constant is the same,
because it is the same line of code in both:

    # Store.Memory
    def append(facts, new), do: {:ok, facts ++ new}
    # Store.File
    state = %{state | facts: state.facts ++ facts, ...}

`list ++ new` copies the entire left spine. At 100k resident that is 100,000
cons cells rebuilt to add one, per append — 1.6 MB copied and immediately
garbaged for a single fact. Filling a ledger to *n* facts one at a time is
Θ(n²) work and Θ(n²) garbage. The `by_id` / `by_attribute` / `by_value` sort
orders are not the cause: those are map updates, O(log n), and the prepend
onto `state.facts` is O(batch).

The p99/p50 spread widens from 5.8× at 10k to 9.7× at 1M — that is the
garbage collector working through a heap made mostly of dead list spines. At
2M facts, one append in a hundred takes 42 ms.

**The `checkpoint:1000` row is the one to look at twice**, because it is what
production runs: `Ledger.default_store/0` sets `checkpoint_every: 1000`
whenever `:ledger_dir` is configured. See §6.

### One hot entity

Sealing asks who owns a fact's entity and answers by scanning `by_id[id]` for a
`"subject"` fact. Unique ids make that list one element long. An entity that
accumulates history makes it as long as its history — and when there is no
subject fact, the scan never short-circuits.

| shape | facts written | txn/s | p50 | p99 | max |
|---|---|---|---|---|---|
| unique ids | 1,000 | 244,978 | 3 | 13 | 36 |
| unique ids | 10,000 | 58,082 | 9 | 108 | 1290 |
| one id | 1,000 | 143,947 | 6 | 19 | 37 |
| one id | 10,000 | 19,581 | **48** | 164 | 489 |

A ledger where every fact is about the same entity is **5× slower** at 10k
facts than one where every fact is about a different entity, and the gap grows
linearly. This is a second O(n) term hiding in `seal/2` — separate from the
list copy, and it fires on the shape that a real workload most obviously has
(one Creator, thousands of posts about them). At 100k facts on one entity,
`owner_of/2` alone would be ~380 µs per fact.

---

## 3. Many writers, one ledger

The same 2,560 appends in every row, so the server does identical work and only
the queue in front of it changes. `GenServer.call` at its 5-second default.

| writers | resident before | txn/s | p50 | p95 | p99 | max | timeouts |
|---|---|---|---|---|---|---|---|
| 1 | 0 | 103,803 | 7 | 23 | 31 | 150 | **0** |
| 2 | 0 | 116,253 | 14 | 37 | 45 | 161 | **0** |
| 8 | 0 | 116,464 | 64 | 108 | 198 | 365 | **0** |
| 32 | 0 | 93,118 | 317 | 592 | 708 | 907 | **0** |
| 128 | 0 | 80,216 | 1,557 | 2,388 | 2,673 | 2,844 | **0** |
| 1 | 100,000 | 2,576 | 300 | 956 | 1,037 | 1,360 | **0** |
| 2 | 100,000 | 2,631 | 590 | 1,285 | 1,338 | 1,776 | **0** |
| 8 | 100,000 | 2,554 | 3,006 | 3,859 | 5,499 | 7,364 | **0** |
| 32 | 100,000 | 2,618 | 12,077 | 13,263 | 16,888 | 17,840 | **0** |
| 128 | 100,000 | 2,618 | **48,751** | 50,464 | 50,943 | 51,495 | **0** |

**This degrades gracefully, and it does so almost perfectly.** Throughput is
flat across a 128× change in writer count — 80–116k txn/s on an empty ledger,
2,554–2,631 txn/s on a 100k-fact one. There is no collapse, no thrash, no
convoy: a GenServer mailbox is a queue and it behaves like one. Latency is
exactly `writers × service time`, and the p99/p50 ratio *falls* as writers
climb (1.03 at 128 writers on a full ledger) because the queue becomes the
whole cost and the queue is uniform.

The 128-writer/empty-ledger row does lose ~30% of peak throughput — that is
scheduler and mailbox overhead, and it is the only sign of stress anywhere in
this table.

### Where the 5-second timeout actually arrives

Latency at the back of the queue is queue depth × service time, so the pair
that breaks is a curve, not a number.

| resident facts | service time p50 | writers before a 5 s timeout | writers before a 100 ms p50 |
|---|---|---|---|
| 10,000 | 48 µs | 104,167 | 2,083 |
| 50,000 | 159 µs | 31,447 | 629 |
| 100,000 | 300 µs | 16,667 | 333 |
| 250,000 | 586 µs | 8,532 | 171 |
| 500,000 | 1.44 ms | 3,463 | 69 |
| 1,000,000 | 2.78 ms | 1,799 | 36 |
| 2,000,000 | 6.11 ms | 818 | 16 |

**The `GenServer.call` timeout is not a real limit.** Nothing timed out in any
run of this suite. Reaching one requires 16,667 simultaneous writers on a
100k-fact ledger, or 818 on a 2M-fact one — and a node with 818 processes all
blocked on one ledger has a design problem that a timeout is not the symptom
of. The right number to hold is the last column: **an SLO breaks two orders of
magnitude before a timeout does.**

---

## 4. Many ledgers, in parallel

1,000 appends of 10 facts to each ledger, all concurrently, memory store.

| ledgers | facts | wall ms | facts/s total | facts/s per ledger | speedup |
|---|---|---|---|---|---|
| 1 | 10,000 | 38 | 262,992 | 262,992 | 1.0× |
| 2 | 20,000 | 48 | 410,139 | 205,069 | 1.6× |
| 4 | 40,000 | 85 | 467,333 | 116,833 | 1.8× |
| 8 | 80,000 | 70 | 1,139,195 | 142,399 | 4.3× |
| 16 | 160,000 | 90 | 1,777,699 | 111,106 | 6.8× |
| 64 | 640,000 | 469 | 1,361,792 | 21,278 | 5.2× |

This is the noisiest table in the document; across three runs the 64-ledger
speedup landed at 6.6×, 4.6× and 5.2×, and the mid rows swing by a factor of
two. The shape is stable even so: **the design does scale horizontally by
ledger, to roughly 5–7× on a 10-core box, saturating between 8 and 16 ledgers
and gaining nothing after that.** Aggregate peak is about 1.8 M facts/s.

5–7× rather than 10× on 10 cores is the list-copy tax again — the appends are
memory-bandwidth-bound and GC-bound, not CPU-bound, so more schedulers stop
helping before they run out. The claim "one ledger is serial but ledgers are
independent" holds; the claim "N ledgers give N× throughput" does not, past the
core count.

---

## 5. Reading while writing

20,000-fact ledger, file store. Writers hammer single-fact appends in a loop
while a reader takes 200 timed `find_at/3` calls.

| read | writers | read p50 | read p95 | read p99 | read max |
|---|---|---|---|---|---|
| by id (1 fact) | 0 | **2** | 3 | 5 | 8 |
| by id (1 fact) | 1 | **73** | 204 | 225 | 283 |
| ↳ the writers, meanwhile | 1 | 73 | 205 | 225 | 528 |
| by id (1 fact) | 8 | **647** | 813 | 883 | 888 |
| ↳ the writers, meanwhile | 8 | 647 | 816 | 871 | 980 |
| by id (1 fact) | 32 | **3,134** | 4,182 | 7,271 | 17,199 |
| ↳ the writers, meanwhile | 32 | 3,123 | 4,106 | 6,916 | 17,623 |
| by attribute (all 20k) | 0 | 1,234 | 1,582 | 1,742 | 1,750 |
| by attribute (all 20k) | 1 | 1,508 | 2,370 | 9,047 | 9,983 |
| ↳ the writers, meanwhile | 1 | 1,247 | 1,816 | 4,917 | 9,543 |
| by attribute (all 20k) | 8 | 2,130 | 3,018 | 4,747 | 5,978 |
| ↳ the writers, meanwhile | 8 | 2,016 | 2,806 | 3,421 | 8,247 |
| by attribute (all 20k) | 32 | 4,562 | 5,646 | 6,576 | 6,687 |
| ↳ the writers, meanwhile | 32 | 4,427 | 5,403 | 6,107 | 6,976 |

**Yes, `find_at/3` contends with writers, completely.** It is a
`GenServer.call` on the same process, so a read does not contend for a lock —
it takes a turn. An indexed read that costs 2 µs of server time takes **73 µs
wall with one writer running and 3.1 ms with 32**, having done no more work.
The reader is not slow; it is waiting.

Note how tightly the read and write rows track each other — 3,134 vs 3,123 at
32 writers. There is exactly one queue, and everyone in it is equal. That is
worth stating positively: there is no priority inversion, no starvation, and a
reader cannot be starved by writers or vice versa.

The corollary is the expensive direction. A wide read is server time nobody
else can use:

| facts in ledger | `find_at(attribute:)` p50 | p99 | appends it displaces |
|---|---|---|---|
| 10,000 | 651 µs | 974 µs | 16 |
| 100,000 | 6,992 µs | 8,558 µs | 22 |
| 500,000 | 34,501 µs | 41,514 µs | 28 |

**One whole-attribute read of a 500k-fact ledger stops every writer for 34 ms.**
Reads and writes draw on one budget, and a dashboard that polls a wide query is
a write outage on a schedule.

---

## 6. Two cliffs

### The checkpoint stalls the ledger for as long as it takes to write everything

`Ledger.default_store/0` sets `checkpoint_every: 1000` whenever `:ledger_dir`
is configured, which is every production deployment. A checkpoint serialises
**every fact ever written** and writes it to a sidecar — inside `handle_call`,
so the ledger is stopped for the duration and every queued writer waits.

| resident facts | p50 | p99 | max | stall vs p50 | checkpoint file | rewritten per txn |
|---|---|---|---|---|---|---|
| 10,000 | 43 µs | 144 µs | **3.96 ms** | 92× | 1.1 MB | 1.2 KB |
| 100,000 | 322 µs | 1.21 ms | **30.5 ms** | 95× | 10.0 MB | 10.2 KB |
| 500,000 | 1.48 ms | 6.30 ms | **113 ms** | 76× | 48.7 MB | 49.9 KB |

The checkpoint file is the same size as the log it exists to avoid re-reading
(~96 bytes per fact, both). So at 500k facts the deployment writes 48.7 MB
every thousand transactions — **50 KB of write amplification per transaction**
— to save time on a restart that may never happen. At 2M facts the stall
extrapolates past 450 ms and the sidecar past 190 MB.

This is the only place in the whole suite where the tail is more than 10× the
median. It is also, unlike everything else here, purely a configuration
default: `checkpoint_every: nil` removes it entirely at the cost of a slower
open.

### Bounding memory unbounds reads

`resident:` evicts old facts from the ledger's list and sort orders. What was
evicted is then answered by `evicted/3`, which calls
`state.module.replay(state.store)` and filters the result — and
`Store.File.replay/1` hands back a list of every fact it ever loaded, with no
index at all.

| resident bound | facts | actually resident | `find_at(id:)` p50 | p99 | max |
|---|---|---|---|---|---|
| `:unbounded` | 100,000 | 100,001 | **2 µs** | 3 | 3 |
| `1_000` | 100,000 | 5,001 | **1,622 µs** | 1,822 | 1,822 |

**Bounding a ledger to 1% of its facts makes its most selective read 800×
slower** — and since that read runs inside the same call queue as the writes,
it costs the writers too. The setting that exists to make a large ledger
affordable is the setting that makes reading one unaffordable.

---

## 7. Memory

Process heap is what the VM reserved, not what is live: it grows in steps and a
collection does not return the slack. The live figure has to be taken *inside*
the ledger, because the five references to each fact (`facts`, `by_id`,
`by_attribute`, `by_value`, `store.facts`) share one copy there — and
`:sys.get_state/1` copies the state out, flattening exactly the sharing being
counted.

| facts | live in process | live B/fact | of which the 3 sort orders | process heap | heap/live | B/fact once copied out |
|---|---|---|---|---|---|---|
| 1,000 | 239,320 | **239.3** | 206,928 (86%) | 372,600 | 1.56 | 527.3 |
| 10,000 | 2,409,176 | **240.9** | 2,088,784 (87%) | 6,665,432 | 2.77 | 528.9 |
| 100,000 | 24,087,320 | **240.9** | 20,886,928 (87%) | 34,387,008 | 1.43 | 528.9 |

**A resident fact costs 241 bytes, flat, and 87% of that is the three sort
orders.** The two list spines holding it are 32 bytes exactly — two cons cells;
the fact itself plus the price of being findable three ways is the other 209.
Process heap runs 1.4–2.8× live depending on where the last collection landed —
for capacity planning, **budget 500 B/fact of RSS**, not 241.

The last column is the one nobody plans for: the same state weighs **529
bytes/fact** once copied out of the process, because five shared references
become five facts. Every reply a ledger sends pays a version of that. This is
why `find_at/3` filters server-side, and it is why `facts_at/2` on a large
ledger is a bad idea independent of how long the server takes.

### What `resident:` actually saves

| resident bound | facts written | ledger's list | store's list | live | live B/fact written | txn/s |
|---|---|---|---|---|---|---|
| `:unbounded` | 100,000 | 100,000 | 100,000 | 22.97 MB | 240.8 | 2,744 |
| `10_000` | 100,000 | 13,300 | **100,000** | 10.31 MB | 108.1 | 2,202 |
| `1_000` | 100,000 | 1,000 | **100,000** | 8.54 MB | 89.5 | 2,864 |

**`resident: 1_000` on a 100,000-fact ledger holds 100,000 facts.** It trims
the ledger's own list and rebuilds the sort orders, which is 63% of the bytes —
but `Store.File` never drops anything, so memory still grows linearly with
everything ever written, at 89.5 B/fact instead of 240.8. The floor is the
store, and there is no setting for it.

---

## Where this breaks

Stated plainly, in the order the failures actually arrive.

### Facts per ledger

**A single ledger stops working somewhere between 500,000 and 1,000,000
facts, and the symptom is latency, not memory and not timeouts.**

| facts/ledger | append p50 | serial ceiling | verdict |
|---|---|---|---|
| ≤ 10,000 | 48 µs | 21,000 txn/s | comfortable |
| 100,000 | 300 µs | 3,300 txn/s | **the practical working limit** |
| 250,000 | 586 µs | 1,700 txn/s | usable, tail already 6.9 ms |
| 500,000 | 1.44 ms | 690 txn/s | degraded; a wide read stops writers for 34 ms |
| 1,000,000 | 2.78 ms | 360 txn/s | **broken for a write-heavy ledger** |
| 2,000,000 | 6.11 ms | 164 txn/s | one append in a hundred takes 42 ms |
| ~5,000,000 | ~14.5 ms (extrapolated) | ~70 txn/s | unusable long before memory runs out |

Below 100k facts the design is genuinely fast and nothing about the GenServer
being serial is visible. Past ~500k the linear service time dominates
everything else and the ledger becomes a fixed-cost bottleneck: adding writers,
batching, or turning fsync off changes nothing, because the cost is a full list
copy that happens once per transaction regardless.

**On a 4 GB box.** At 500 B/fact of RSS (241 live × observed heap slack, and a
copying major GC needs room to allocate the new heap alongside the old), 3 GB
of usable space is about **6 million facts total across every ledger on the
node**. But a *single* ledger holding 6 M facts has a 17 ms append and pauses
for hundreds of milliseconds on every full sweep of its multi-gigabyte heap.
**Memory
is not the constraint that bites; latency is, by roughly an order of
magnitude.** The 4 GB box will be visibly unusable at around 1 M facts per
ledger and will not OOM until six times that.

### Writers per ledger

**There is no writer count at which this collapses, and no realistic writer
count at which anyone times out.** Throughput is flat from 1 to 128 writers.
What degrades is per-caller latency, linearly and predictably:

| ledger size | 8 writers | 32 writers | 128 writers | writers for a 5 s timeout |
|---|---|---|---|---|
| empty | 64 µs | 317 µs | 1.56 ms | — |
| 100,000 facts | 3.0 ms | 12.1 ms | 48.8 ms | 16,667 |
| 1,000,000 facts | 22 ms (calc.) | 89 ms | 356 ms | 1,799 |
| 2,000,000 facts | 49 ms (calc.) | 196 ms | 782 ms | 818 |

Pick the limit from an SLO, not from the timeout. **For a 100 ms p50 budget:
2,083 writers at 10k facts, 333 at 100k, 36 at 1 M, 16 at 2 M.** Zero callers
timed out anywhere in this suite, under any combination measured.

### The three sharpest edges

1. **A checkpoint at 500k facts stops the ledger for 113 ms** and writes 48.7 MB.
   This is on by default in production (`checkpoint_every: 1000` whenever
   `:ledger_dir` is set) and is the only tail in this document worse than 10×
   the median.
2. **A wide read is a write outage.** `find_at(attribute: …)` on a 500k-fact
   ledger occupies the process for 34 ms, during which no append can proceed.
3. **A ledger whose facts are mostly about one entity is 5× slower at 10k
   facts** and degrades linearly from there, because `seal/2` scans that
   entity's whole history per fact.

### The one-line cause

    def append(facts, new), do: {:ok, facts ++ new}     # Store.Memory
    facts: state.facts ++ facts                          # Store.File

Every append copies the entire fact list. Filling a ledger to *n* facts is
Θ(n²). Every ceiling in this document is downstream of those two lines; a store
that appended in O(1) — a reversed list, a queue, a chunked vector — would move
the facts-per-ledger limit by roughly the factor by which the ledger has grown.

---

## What turned up in `lib/` along the way

Found while measuring. **Reported, not fixed**, per the terms of this work.

### 1. A malformed read pattern kills the ledger and its facts — `ledger.ex:330`, `fact.ex:51`

`Fact.matches?/2` does `Map.fetch!(fact, key)`, so a pattern key that is not a
`Fact` field raises `KeyError` — inside `handle_call`, which takes the
GenServer down.

    Ledger.find_at(ledger, tx, subject: "someone")   # "subject" is an attribute, not a field

    ** (KeyError) key :subject not found in: %LazyRiver.Fact{...}
       lib/lazy_river/fact.ex:51: LazyRiver.Fact."-matches?/2-fun-0-"/2
       lib/lazy_river/ledger.ex:330: LazyRiver.Ledger.handle_call/3

Verified: the ledger process is dead 50 ms later and, with `Store.Memory`,
every fact is gone. **A read destroys a writer's data**, and the confusion that
triggers it is an easy one — `"subject"` is a real attribute name in `Erasure`,
just not a field of `Fact`. This also contradicts the house rule that errors
are data with the repair attached: the boundary rejects by crashing.

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

### 3. `Store.File` is a memory store that also writes to disk — `store.ex:127-145`

`append/2` keeps `state.facts ++ facts` and `replay/1` returns the whole list.
The file is written but never read again after open. Consequences, all measured
above: `resident:` saves 63% rather than 99% (§7); a bounded ledger's indexed
read costs 1.6 ms instead of 2 µs because `evicted/3` re-scans everything (§6);
and the moduledoc's *"it only saves anything when the facts are durable
somewhere else"* is only two-thirds true — durability is not the missing piece,
a store that can forget is.

### 4. `Θ(n²)` fills — `store.ex:45` and `store.ex:136`

Both stores append with `++`. See "The one-line cause" above. Flagging it
separately because it is the single highest-leverage change available and it is
confined to two lines behind an interface designed to hide exactly this.

### 5. A checkpoint newer than its log crashes `open/2` — `store.ex:208`

    binary |> binary_part(offset, byte_size(binary) - offset)

If the checkpoint's recorded offset exceeds the current file size — a log
restored from an older backup, or truncated — the length goes negative and
`binary_part/3` raises `ArgumentError` from inside `Ledger.init/1`, so the
ledger cannot start. Verified by truncating a log with a live sidecar:

    ** (ArgumentError) errors were found at the given arguments: ... -5250
       lib/lazy_river/store.ex:208: LazyRiver.Store.File.read_from/2
       lib/lazy_river/store.ex:101: LazyRiver.Store.File.open/2

`read_checkpoint/1` carefully falls back when the sidecar is missing or
corrupt, but this failure happens after it returns, so the fallback never
fires. A `min(offset, byte_size(binary))` would degrade it to the intended
"read from the start, just slower".

### 6. Smaller things

- `Ledger.resident/1` is `length(state.facts)` — an O(n) public read that runs
  inside the ledger. At 2 M facts it stalls every writer for the length of a
  list walk.
- `maybe_checkpoint/1` computes `at` with `Enum.map(facts, & &1.tx) |> Enum.max()`
  over every fact, on top of the `term_to_binary` of every fact. The list is
  already ordered; `List.last/1` would do.
- `evicted/3` ignores the pattern's index entirely and full-scans. The moduledoc
  calls this "honest rather than good", which it is — the number is in §6.
