# Failure modes for an immutable fact log

*Research compiled 2026-08-13, for a claims-based testing framework.*

## What this is

A catalogue of things that are known to go wrong in databases and stateful
backend infrastructure, written so that each one can become an assertion. The
bias throughout is toward **falsifiable claims**: not "be careful about fsync"
but "a write that returned success is present after an uncoordinated restart",
which is a sentence a test can fail.

Every item has the same shape.

| Field | What it holds |
|---|---|
| **What goes wrong** | The mechanism, not the symptom |
| **Conditions** | What has to be true for it to fire |
| **Claim** | The assertion, phrased so that a counterexample is unambiguous |
| **Test** | How to set the counterexample up — the fault-injection point |
| **Source** | Primary where one exists |
| **Applicability** | `single-node now` · `only if distributed` · `n/a` |

## How to read it

The system this was written for is a single-node, immutable, append-only fact
log in Elixir — Datomic-shaped, one row shape, ledgers of facts, snapshots
named by `{ledger => transaction}`, formulas that are pure, jobs that are the
only thing allowed outside, envelope encryption with erasure by key
destruction, and incremental byte-range backup to object storage. Roughly a
third of what follows applies to it today, a third would apply if it ever
distributes, and a third is here because knowing the shape of a bug in
somebody else's system is how you recognise your own.

**The applicability tags matter more than the section headings.** A
single-node system is not exempt from the isolation taxonomy — it is exempt
from the *distributed* half of it. Read skew across two ledgers read at two
different instants is a single-node anomaly, and Section 2 explains why.

One wrinkle to know before reading: the eight sections here each cover one to
three of the thirteen topic areas that were researched, so a section's own
sub-numbering (`### 1.`, `## Topic 3`, `## (7)`) refers to the topic area, not
to the section it sits in. The Contents table below is the map.

Section 0 is different from the rest: it is the subset of this catalogue that
was **reproduced against the working tree** while the research was being done.
Those twelve are not risks. They are the current behaviour.

### Contents

| | Section | Covers |
|---|---|---|
| **0** | Confirmed against this tree | Twelve findings reproduced on 2026-08-13, with the script that reproduces each |
| **1** | Durability and crash consistency | fsync semantics and the lies beneath them, page cache, torn writes, directory fsync, filesystem differences, SSD power-loss behaviour, bitrot, fsyncgate; then append-only log, WAL and LSM pitfalls — recovery ambiguity, checkpoint/log interaction, offset bookkeeping |
| **2** | Isolation anomalies and caching | The formal taxonomy (G0, G1a/b/c, G2, G-single, P4, write skew, read skew) with an executable schedule for each; what snapshot isolation does and does not give; Elle and Hermitage; then what actually breaks "a name answers the same forever" |
| **3** | Backup, restore, encryption and erasure | Silent partial restores, incremental-chain gaps, ransomware and credential compromise, retention; crypto-shredding limits, envelope-encryption mistakes, AEAD misuse, nonce reuse, KMS as a dependency, and what regulators actually require for deletion |
| **4** | Jobs, clocks and tenancy | At-least-once vs at-most-once, missed and duplicate runs, fencing, thundering herd, poison jobs; monotonic vs wall clock, NTP steps, leap seconds, DST; confused deputy, enumeration, cross-tenant leakage through caches and derived data |
| **5** | Sandboxing and operations | Sandbox escape classes and why in-process language sandboxes keep failing, resource exhaustion, non-determinism leaking into "pure" code; dead config, components never started, on-disk format skew, capacity cliffs, volume and shutdown hazards |
| **6** | Testing methodology | Jepsen and Elle, Maelstrom, deterministic simulation testing and whether it is feasible on the BEAM, PropCheck/StreamData/PropEr state machines, Concuerror, crash-consistency explorers, fuzzing, TLA+, coordinated omission, metamorphic and differential testing — each with a verdict on practicality here |
| **7** | Incident postmortems | Roughly forty sourced incidents grouped by root-cause family, each reduced to the assertion that would have caught it |

Sections 1 through 7 were compiled by parallel research passes and are
presented close to as written, so the density and the citation count are
uneven between them by design — the postmortems are terse because an incident
is its own argument, and the isolation taxonomy is long because each anomaly
needs its schedule spelled out to become a test.

## Five findings that should change the test plan

If nothing else survives from this document, these five should.

**1. The system's central claim is false today, and the test that catches it
is four lines long.** "A name answers the same answer forever" is the load
bearing guarantee — it is what makes client caches safe, what makes formulas
cacheable, and what the absence of a cache-coherence protocol rests on. A
snapshot name is a client-writable map, transactions are not bounds-checked
against the ledger, and a name pinned to a future transaction therefore means
"everything, so far". Its answer changes on every write. See **C1**.

**2. The failure modes that matter most here are the ones that are
indistinguishable from success.** A corrupted answer reads as `:erased`, which
is also what a lawful GDPR deletion reads as (**C5**). An over-restored backup
reports `incomplete: []` (**C8**). A permutation bug in `open` is invisible
whenever the ledgers happen to be at the same transaction (**C2**). Eviction
silently stops encrypting (**C4**). The general rule this suggests, and the
one worth building the framework around: **for every sentinel value or success
report, ask what else could produce it, and assert the two are
distinguishable.** That single question generated half of Section 0.

**3. Recovery and restore are the least-tested code in every system in this
document, and this one is no exception.** GitLab's 2017 incident is famous
because five backup mechanisms all failed *and nobody knew*, not because any
one of them was badly written. The cheapest high-yield test here is exhaustive
prefix-truncation of the log — a few thousand cases, under a second, and it
already finds an unopenable-ledger bug (**C3**). The second cheapest is a
property test over generated segment sets in the restore path (**C8**).

There is a specific blind spot worth naming here, because it explains why the
existing suite is clean. `mix test --include crash` SIGKILLs a *process*, and
the page cache survives a process death — so it always produces a cleanly
truncated tail, which is the one damage shape the recovery code already handles.
It cannot produce a zero-filled tail, and a zero-filled tail makes the ledger
refuse to open, permanently, because `:erlang.crc32(<<>>) == 0` means eight zero
bytes are a *valid* record (**C12**). The crash suite is testing the easy case
and reporting it as coverage of the hard one. Damage shape is a dimension the
tests do not currently vary, and varying it costs a `for` loop.

**4. Two doctrines in the repository contradict each other, and the code
implements the wrong one.** `Formula.Engine` says "a cache keyed by a name
cannot go stale… there is no cache-coherence protocol, because there is nothing
to cohere." The README says "an old name still answers — it answers `:erased`."
Erasure is exactly the operation that makes a name answer differently, so there
*is* something to cohere. Reproduced: after erasing a subject, the raw fact
reads `:erased` and the formula cache still serves the plaintext under the same
name (**C10**). The client half is worse — clients are told to cache forever and
never invalidate, and no channel exists to tell them otherwise, so an erasure
request cannot be completed for any client that followed the documented advice.
This is not a bug to fix so much as a doctrine to settle, and settling it is
prior to writing tests, because the tests encode whichever answer is chosen.

**5. Two of the design's own recommendations are in direct conflict, and the
conflict is a compliance gap rather than a bug.** Backup copies the key files
*whole, every run* — that is `master.wrapped` and the per-subject key store.
Separately, and correctly, the design says versioning and a retention window
belong on the bucket, "out of reach of a node that has been taken over". Put
those two together and every pre-erasure version of the subject key store is
retained in the bucket for the length of the retention window. The README's
answer — "an old key store cannot resurrect an erased subject because the
keyring reconciles against erasure tombstones every time it opens" — protects a
key store *this system opens*, and does nothing about one read out of the bucket
directly. It is true that bucket access alone is not enough, since the store is
encrypted under a master the KMS holds; but the deployment holds both the bucket
credentials and the KMS credentials, which means **crypto-shredding here is
reversible by the controller for the length of the retention window**. For
GDPR the relevant question is whether the *controller* can restore the data, not
whether an outsider can. Section 3 has the regulator citations, including the
ICO's explicit position that erasure extends to backups and the EDPB's
Guidelines 02/2025 on what key destruction does and does not achieve. The claim
to test: for every retained version of the key store in the target, unwrapping
an erased subject's key fails.

## The cross-cutting principles

Distilled from the thirteen sections. These are the assertions worth making
about *any* claim, and they are what a claims framework should make easy.

1. **Acknowledgement must be issued by the thing that made it true.** Not by
   something that scheduled it. This is fsyncgate, Redis, MongoDB, Elasticsearch
   and RabbitMQ in one sentence.
2. **A value that two different causes can produce cannot be evidence for
   either.** Assert distinguishability, not just the happy path.
3. **A test whose inputs are all equal cannot detect a permutation.** Vary
   every dimension you claim not to depend on.
4. **Anything a client can construct, a client will construct wrongly and an
   attacker will construct deliberately.** Bound it at the boundary, refuse
   rather than clamp.
5. **A configuration flag that no test sets is an untested code path,
   regardless of how carefully it was written.** Durability defaults off here,
   and every test runs with it off.
6. **Derived and cached data does not inherit the guarantees of its source.**
   Erasure destroys a key; it does not reach into a cache holding the plaintext
   that key once protected.
7. **A backup is a claim about a restore.** Until the restore has run, the
   backup has not been tested — only the upload has.
8. **Duration is monotonic; timestamps are not.** Every `now - then >= interval`
   computed on a wall clock is an outage waiting for an NTP step.
9. **Recovery code runs least and matters most.** Budget test effort by
   consequence, not by frequency.
10. **The fence has to be structural.** A rule that can be forgotten will be.
    (This one the system already gets right, in `Formula.Sandbox`.)

---




## Section 0 — Confirmed against this tree

Twelve of the failure modes catalogued below are not hypothetical here. Each was
reproduced against the working tree on 2026-08-13 with a short script; the
reproduction is given so it can become a test verbatim. They are listed first
because a claims framework that cannot express these seven is not yet earning
its keep.

---

#### C1. The central claim is false: the same snapshot name answers differently over time

**Claim under test.** "An answer at a named snapshot is the same answer forever,
so a client caches on `{name, question}` and never invalidates." (README;
`Snapshot` moduledoc.)

**What goes wrong.** A snapshot name is `%{ledger => tx}` and
`Snapshot.reopen/1` accepts any map. `Ledger.facts_at(ledger, tx)` returns every
fact *at or before* `tx`, so a name that pins a transaction which has not
happened yet is not refused — it silently means "everything, so far".
`Wire.snapshot_name/1` validates only `is_integer(tx) and tx >= 0`; it never
compares `tx` against the ledger's current transaction.

**Reproduced.**

```elixir
{:ok, l} = Ledger.open(n)
{:ok, _} = Ledger.append(l, [{1, "height", 10}])
future = %{l => 99}                                    # a name written by hand
Snapshot.answer(Snapshot.reopen(future), 1, "height")  #=> 10
{:ok, _} = Ledger.append(l, [{1, "height", 20}])
Snapshot.answer(Snapshot.reopen(future), 1, "height")  #=> 20   ← same name
```

**Why it is worse than a bug.** It is a cache-poisoning primitive. A caller who
may name a ledger can mint a name at `tx = 2^60`, hand it to any client that
follows the documented "never invalidate" advice, and that client's cache entry
is now permanently wrong in a direction the attacker controls. It also removes
the only defence the design has against read skew, because a "snapshot" pinned
to the future is not a snapshot.

**Falsifiable claim.** For all `name`, `question`, and all sequences of writes
`W` performed after the first answer: `ask(name, question)` before `W` equals
`ask(name, question)` after `W`.

**Test.** Property test. Generate a name, answer a question, apply an arbitrary
generated write sequence, answer again, assert equality. It fails immediately
on a future-pinned name. Then add the boundary check and re-run.

**Repair shape.** `Wire.snapshot_name/1` and `Snapshot.reopen/1` must refuse a
`tx` greater than the ledger's current transaction — refuse, with a repair,
rather than clamp. Clamping reintroduces the same bug at the clamp.

**Applicability.** Single-node now. Gets worse distributed: a name minted
against one node's transaction counter is meaningless on another.

---

#### C2. `open` pairs each ledger with another ledger's transaction

**What goes wrong.** `LazyRiver.Surface.Controller.named/2`:

```elixir
defp named(internal, names) do
  internal |> Map.values() |> Enum.zip(names) |> Map.new(fn {tx, name} -> {name, tx} end)
end
```

`internal` is a map keyed by ledger reference. `Map.values/1` yields values in
map iteration order — term order for maps of 32 keys or fewer, hash order above
that — and neither is the caller's argument order. Zipping the two produces a
name that assigns each ledger somebody else's transaction.

**Reproduced.**

```
open(["zulu", "alpha"])  with zulu at tx 7 and alpha at tx 3
  returns  %{"alpha" => 7, "zulu" => 3}     ← transactions swapped

open(40 ledgers)  →  40 of 40 ledgers got the wrong transaction
```

**Why it hides.** Every ledger in a fresh test is at the same transaction, so
the wrong pairing is indistinguishable from the right one. The bug is invisible
to any test that does not first advance two ledgers by *different* amounts.
This is the general shape worth stealing for the framework: an assertion whose
inputs are all equal cannot detect a permutation.

**Falsifiable claim.** For every list of ledger names `L`,
`open(L)[name] == Ledger.tx(name)` for each `name` in `L`.

**Test.** Open `n` ledgers, append a different number of transactions to each,
call `open`, assert the returned map is exactly `Map.new(L, &{&1, tx(&1)})`.
Run it at `n = 2` and at `n = 40` — the representation change at 32 keys means
small-map and large-map behaviour differ and both need covering.

**Applicability.** Single-node now.

---

#### C3. A checkpoint ahead of the log makes the ledger unopenable

**What goes wrong.** `Store.File.maybe_checkpoint/1` writes `state.bytes` — the
number of bytes it believes are in the log — into the checkpoint sidecar, and
swaps it in with `File.rename!`. Neither the log nor the checkpoint is fsynced
in the default configuration (`sync: false`), and the sidecar is a different
file from the log, so writeback order between them is not constrained. On
reopen, `read_from/2` does:

```elixir
binary |> binary_part(offset, byte_size(binary) - offset)
```

If the log is shorter than the recorded offset, the length argument is negative
and this raises.

**Reproduced.**

```
log bytes: 206; checkpoint exists: true
truncated log to 103 bytes; reopening...
REOPEN RAISED: ArgumentError — 2nd argument: out of range
```

**Conditions.** Any of: power loss with `LEDGER_SYNC` unset (the default) where
the checkpoint reached disk and the log tail did not; a restore that produced a
shorter ledger beside a surviving checkpoint (checkpoints are deliberately not
backed up, but they are also not removed); a `Backup.restore(only: :ledgers)`
into a directory that still holds an old checkpoint; a filesystem that pads a
short write with zeros.

**Severity.** This is not data loss, it is unavailability, and of the
unrecoverable-without-an-operator kind: the ledger will not open, so the process
crashes, the supervisor restarts it, and it crashes again. The moduledoc's
promise — "No checkpoint, or one that did not survive. The log is whole either
way, so reading from the start is always correct — just slower" — holds only for
a checkpoint that fails its CRC, not for one that is valid and stale.

**Falsifiable claim.** For every log prefix length `p` and every checkpoint
written at any earlier point, `Store.File.open/2` returns `{:ok, _}` and replays
exactly the records wholly contained in the first `p` bytes.

**Test.** Exhaustive, not sampled: write `n` transactions with
`checkpoint_every: 1`, then for every `p` in `0..byte_size(log)` truncate a copy
to `p` bytes and assert `open/2` succeeds and replays the right prefix. That is
a few thousand cases and runs in under a second — the cheapest high-yield test
in this list. It is the ALICE/CrashMonkey idea reduced to one file.

**Repair shape.** Treat `offset > file_size` as a stale checkpoint and fall back
to a full scan; better, refuse to trust any checkpoint whose offset is not
exactly a record boundary in the present log.

**Applicability.** Single-node now.

---

#### C4. Eviction silently turns off encryption, and with it erasure

**What goes wrong.** `Ledger.seal/2` asks `owner_of/2` for the entity's subject,
and `owner_of/2` reads `state.by_id`. `trim/1` rebuilds `by_id` from resident
facts only. So once an entity's `subject` fact has been evicted, every
subsequent fact about that entity is written **in plaintext**, and destroying
the subject key will not erase it.

**Reproduced.** With `resident: 3`:

```
before eviction:  [{:PLAINTEXT, "person-7"}, :SEALED]
answer written AFTER the subject fact was evicted: "SHOULD-BE-SEALED"   ← plaintext
```

**Why it is the worst kind of bug.** It is silent at write time, silent at read
time, and only observable after an erasure — at which point the observation is
"we told a regulator we deleted this and we did not". The stated limit in the
`Erasure` moduledoc ("a fact written before its subject was declared is not
covered") is a *different* limit; this one is a fact written long *after* the
subject was declared and still not covered.

**Falsifiable claim.** For every entity `e` for which a `subject` fact exists
anywhere in the ledger's history, every fact about `e` written after that fact
is sealed — regardless of `resident:`, of how many facts have been written
since, or of whether the ledger has been reopened.

**Test.** Property test with `resident:` as a generated parameter: declare a
subject, write `k` filler transactions for generated `k`, write another fact
about the entity, assert `raw_at/2` shows it sealed. Also assert it after a
close/reopen cycle, since replay rebuilds the index from the store and the
`oldest`/`resident` interaction differs on that path.

**Repair shape.** Subject ownership is a property of the entity for all time, so
it must be tracked in a structure that eviction does not touch — a
subject-per-entity map that is never trimmed, rather than a lookup into the fact
index. That map is small: one entry per entity that has a subject.

**Applicability.** Single-node now.

---

#### C5. Corruption and lawful deletion are the same answer

**What goes wrong.** `Erasure.reveal/1` returns `:erased` on AEAD tag failure:

```elixir
case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, cipher, <<>>, tag, false) do
  :error -> :erased
  plain  -> :erlang.binary_to_term(plain)
end
```

Tag failure means *the ciphertext did not authenticate*. Key destruction is only
one of its causes. The others — a flipped bit in a sealed answer, a truncated
blob, an unwrap that returned the wrong key, a keyring restored under a
different master, a KMS returning a stale key version — are all reported to the
caller as a completed GDPR erasure.

**Reproduced.**

```
clean reveal: "secret-value"
1-bit-flipped ciphertext reveals as: :erased
```

**Falsifiable claim.** `reveal/1` answers `:erased` if and only if an erasure
tombstone exists for the subject. Any other decryption failure is corruption and
must raise or return a distinguishable `{:error, :unreadable}`.

**Test.** Two directions, and both matter. (a) Corrupt a sealed answer with no
tombstone present and assert the read does *not* answer `:erased`. (b) Destroy a
key with a tombstone present and assert it *does*. A test that only checks (b)
passes today and proves nothing.

**Why this belongs in the framework.** It is the general pattern of a failure
mode that is invisible because it is *indistinguishable from a success*. Every
sentinel value that can be produced by two causes — one benign, one a data-loss
event — is a place to write this pair of assertions.

**Applicability.** Single-node now.

---

#### C6. Sealed answers carry no context, so they can be moved between facts

**What goes wrong.** `Erasure.protect/2` encrypts with empty additional
authenticated data:

```elixir
{cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plain, <<>>, true)
```

The sealed tuple binds the *subject* (the wrapped key is unwrapped under it) but
nothing else. It does not bind the ledger, the entity id, the attribute, or the
transaction. Any sealed answer belonging to a subject is therefore a valid
sealed answer for any other fact belonging to that subject.

**Reproduced.**

```
fact 99's answer after splicing in another fact's sealed blob: "alice-salary-1000000"
```

Relabelling to a different subject correctly fails, so the fence holds *between*
subjects and not *within* one.

**Conditions.** Requires an attacker who can write bytes into a ledger file or
into the backup bucket. That is exactly the threat model the README already
takes seriously — "no target can delete, but the credentials a deployment holds
usually can" — so the bucket is assumed reachable.

**Falsifiable claim.** A sealed answer taken from fact A and placed on fact B
fails to decrypt, for every A ≠ B.

**Test.** Round-trip property: seal `k` answers for one subject, then for every
ordered pair `(i, j)` with `i ≠ j`, splice `i`'s blob onto `j`'s fact and assert
the read fails. Passing requires binding `{ledger, id, attribute, tx}` into the
AAD.

**Applicability.** Single-node now. Becomes more urgent with any replication,
since a replicated blob crosses more boundaries.

---

#### C7. Restored bytes reach `binary_to_term/1` without `:safe`

**What goes wrong.** Four call sites decode terms from bytes that can originate
outside the node:

| Site | Source of bytes |
|---|---|
| `store.ex:158` | ledger log payload — **restored from the backup bucket** |
| `store.ex:189` | checkpoint sidecar |
| `erasure.ex:129` | decrypted answer |
| `keyring/local.ex:90` | decrypted key store |

`:erlang.binary_to_term/1` without `[:safe]` creates atoms. Atoms are never
garbage collected and the default limit is 1,048,576, so a crafted payload is a
permanent-until-restart denial of service; the same call also constructs funs
and pids. The `Ledger` moduledoc already states the principle for the write path
— "a name taken from a request would leak the atom table until the node fell
over" — and the replay path does not follow it.

**Falsifiable claim.** No byte sequence read from disk or from a backup target
can increase `:erlang.system_info(:atom_count)`.

**Reproduced, with numbers.** A single well-framed record with a correct CRC,
789 KB of payload, appended to a ledger file:

```
atoms created by opening one ledger file: 50000 (limit 1048576)
```

Twenty-one such records — about 16 MB in a bucket — exhaust the atom table.
The exhaustion happens *during `open`*, so the node dies, the supervisor
restarts it, it opens the same file and dies again. A restore from a
compromised backup target is therefore a permanent brick, not an outage.

**Test.** Craft the record, append it, open the ledger, assert `atom_count` is
unchanged — and note that the test must write the file from a *different* VM
than the one that reads it, or the atoms already exist and the test passes
vacuously. (That vacuous pass is itself worth keeping as a cautionary example:
the first version of this check reported zero atoms created.)

**`[:safe]` is only half the repair, and this surprised me enough to check it.**
The option is widely described as making `binary_to_term` safe against hostile
input. It blocks atom creation; it does **not** block function terms:

```
safe decode of a fun:         #Function<0.27337837 in file:/tmp/safe.exs>
safe decode of &:os.cmd/1:    &:os.cmd/1
```

Both decoded under `[:safe]`. So the correct claim is not "use `:safe`" but
**the decoded term conforms to the expected shape** — a list of `%Fact{}` whose
answers are drawn from the permitted set of types. That is a stronger assertion,
it is the one a fact log can actually make, and it is checkable in one function.
`:safe` should be there too, for the atom half.

**Applicability.** Single-node now. Note that this is the *restore* path, which
is the path with the fewest tests everywhere, in every system — see the GitLab
and backup-verification material below.

---

#### C8. Overlapping backup segments restore as a corrupt file, reported as a clean success

**What goes wrong.** `Backup.fetch_segments/3` sorts segments by start offset and
handles two of the three relationships a segment can have with the bytes already
assembled: a hole (`from > at` — halt, correct) and a full duplicate (`to <= at`
— skip, correct). The third, a **partial overlap** (`from < at < to`), falls
through to the general case and concatenates the segment *whole*, duplicating
every byte in `from..at`.

**How the overlap arises.** From the gap the README already names: "a run copies
and *then* records what it copied". A crash between the successful PUT and the
`held_bytes` fact means the next run recomputes `from` from the stale record and
uploads a longer range starting at the same offset. Now `0-100.segment` and
`0-250.segment` both exist. This is the ordinary consequence of the ordinary
crash, not an exotic one.

**Reproduced.**

```
restore reported: %{incomplete: [], keys: 0, bytes: 350, ledgers: 1}
bytes actually on disk: 350   (should be 250)
```

The `incomplete` check cannot catch it: it tests `byte_size(bytes) < furthest(segments)`,
and 350 is not less than 250. Over-restoring is invisible to a check that only
looks for under-restoring.

**What the corruption does.** The 100 duplicated bytes shift every subsequent
record out of frame. `Store.File.scan/2` stops at the first record whose CRC
fails — which is now the second record — so the ledger opens successfully,
reports no error, and has silently lost everything after byte 100. A silent
partial restore presented as a complete one is precisely the failure the module
says it exists to prevent.

**Falsifiable claim.** For every set of segment ranges, the restored file is
either exactly the contiguous prefix those ranges cover, or the restore refuses.
Equivalently: after sorting by start offset, consecutive kept segments satisfy
`from(i+1) == to(i)`, and any segment that does not is a refusal rather than a
concatenation.

**Test.** Property test over generated segment sets. Generate a true byte string,
cut it into ranges, then apply generated perturbations — drop one, duplicate one,
extend one backwards, extend one forwards, upload one twice with different
ranges — and assert the restore either reproduces a prefix of the true string
exactly, or refuses. This one property covers the hole case, the duplicate case
and the overlap case at once, and it is the single highest-value test in the
backup module.

**Applicability.** Single-node now.

---

#### C9. The sandbox fences reach, not resources — a tenant formula runs forever

**What goes wrong.** `Formula.Sandbox` is a genuinely good structural fence for
*data access*: `imports/0` returns `%{}`, so a module naming any import fails to
instantiate, and the moduledoc's claim — "there is no rule being enforced, so
there is no rule anyone can forget" — is true as written. It says nothing about
CPU or memory, and nothing limits either. `Wasmex.Store.new()` is called with no
arguments, so no `StoreLimits` and no fuel.

**Reproduced.** A four-line module exporting `apply`:

```wat
(module (func (export "apply") (param i32) (result i32)
  (loop $l (br $l)) (i32.const 0)))
```

```
module accepted at build time (an infinite loop is not a build error)
RESULT: run/2 did not return in 4s — no fuel/epoch limit is configured
processes still alive after killing the caller: 484 (was 486)
```

Killing the caller does not stop the guest. Wasmex executes the guest on a dirty
NIF scheduler thread, and the BEAM has a fixed number of those — by default one
per core. So `N` such formulas, where `N` is the core count, permanently starve
every dirty-NIF operation on the node, and no supervisor restart recovers it
because nothing has crashed.

**Two more defects on the same path.** The compute closure calls
`Wasmex.Module.compile/2` on *every evaluation*, so the compile cost is paid per
read rather than per formula; and it calls `Wasmex.start_link/1` without a
matching stop, so each evaluation leaks a process.

**Falsifiable claims, three of them.**
1. A formula that does not terminate is refused or aborted within a bounded
   time, and the abort leaves no thread running.
2. A formula cannot allocate more than a stated memory bound.
3. Evaluating the same formula `k` times costs one compilation, not `k`, and
   leaves no processes behind.

**Test.** The looping module above with a hard deadline; a module that grows
memory in a loop; and a loop of `k` evaluations asserting on
`length(Process.list())` and on elapsed time. All three are a few lines and all
three fail today.

**Repair shape.** Wasmex exposes both mechanisms already —
`Wasmex.EngineConfig` with `consume_fuel: true` for a reduction budget, and
`Wasmex.StoreLimits` for memory. The design instinct in this module is right;
it needs to be applied to the second resource dimension.

**Applicability.** Single-node now. This is also the one place where the general
literature is unusually emphatic: in-process language sandboxes have failed
repeatedly (Java's SecurityManager, Python's `rexec`, Ruby's `$SAFE`, Node's
`vm2`), and WebAssembly is the current best answer *precisely because* it fences
both capability and resource — using only half of it gives up much of why it was
chosen.

---

#### C10. Erasure does not reach the formula cache, and cannot reach a client's

**What goes wrong.** `Formula.Engine` caches an answer under `{formula,
snapshot name}` and its moduledoc gives the reason: "A cache keyed by a name
cannot go stale… there is no cache-coherence protocol, because there is nothing
to cohere." That reasoning is sound for immutability and unsound for erasure,
which is the one operation the system has that makes an old name answer
differently — a fact the README states plainly two paragraphs later: "an old
name still answers — it answers `:erased`."

Both statements are in the repository. They cannot both be true, and the cache
implements the wrong one.

**Reproduced.**

```
answer before erasure (cached under this name): {:ok, [{1, "echoed", "THE-SECRET", "echo"}]}
raw facts after erasure:                        [:erased]
SAME name asked again, after erasure:           {:ok, [{1, "echoed", "THE-SECRET", "echo"}]}
```

The key is destroyed. The plaintext is still being served.

**The worse half.** The engine's cache is at least reachable — it is a map in a
process, and erasure could sweep it. The *client's* cache is not. The README
tells every client to cache on `{name, question}` and never invalidate, and
there is no channel by which a client could be told otherwise. Any client that
followed the documented advice holds the erased plaintext indefinitely, and the
system has no way to know which clients those are or what they hold. An erasure
request cannot be completed.

**Falsifiable claims.**
1. After `Erasure.erase(s)`, no cache inside the system returns a value derived
   from a fact sealed under `s`, for any snapshot name, old or new.
2. Erasure produces a record of what was served under which names before it, or
   the caching guarantee is documented as not surviving erasure — one or the
   other, stated rather than left to the reader.

**Test.** Exactly the script above, asserting the third line differs from the
first. Then the harder version: register `k` formulas, answer them across `m`
snapshot names, erase, and assert every cache entry is gone — which requires
the engine to know which subjects contributed to each entry, and that
provenance does not exist today.

**Repair shape.** Three honest options, and the choice is a doctrine decision
rather than an implementation one. (a) Key formula cache entries by the set of
subjects they read, and drop entries on erasure — costs a read-set extension,
and `Snapshot.track_reads/1` is already the right hook. (b) Do not cache
anything derived from sealed answers. (c) Narrow the published caching
guarantee to "the same answer forever, or `:erased`", and give clients a
channel that says a name has been erased — which is a cache-coherence protocol,
and admitting that is better than not having one and claiming not to need one.

**Applicability.** Single-node now, and the client half is unfixable by any
single-node change — it is a protocol gap.

---

#### C11. Changing a formula's code does not change its answers

**What goes wrong.** `Formula.Engine` keys its cache on `{formula id, snapshot
name}`. The formula's *body* is not part of the key. `Engine.register/2`
replaces a formula in place. So after a code change, every snapshot name that
was already answered keeps returning the old code's answer — forever, since
nothing invalidates.

**Reproduced.**

```
v1 (doubling):                          {:ok, [{1, "out",  20, "f"}]}
v2 (x100) at the SAME snapshot name:    {:ok, [{1, "out",  20, "f"}]}
```

The second formula multiplies by 100. It returns 20.

**Why the design invites it.** The cache is correct on its own terms: a name
plus a question determines an answer. But "the question" was taken to be the
formula's *name*, and the actual question is the formula's *code*. This is the
same defect as a build cache that omits the compiler version from its key — the
class that produced Bazel's remote-cache poisoning and Go's missing-toolchain
-version bug. It is a general rule worth stating in the framework: **a cache key
must cover every input the value depends on, and code is an input.**

**Falsifiable claim.** For all formulas `f`, snapshots `s`, and code changes
that alter `f`'s output: `answer(f, s)` after the change differs from
`answer(f, s)` before it.

**Test.** The six lines above. It fails today.

**Repair shape.** Include a content hash of the formula body in the cache key —
for a WASM formula the module bytes hash cleanly; for a native closure,
`:erlang.fun_info(f, :uniq)` or an explicit version the author supplies. Note
that `:erlang.term_to_binary` is **not** a valid content address here: EEP-18
allows map pair order to change between OTP releases, so the same formula can
hash differently after an upgrade and the same bytes can mean different things.

**Applicability.** Single-node now. Compounds with **C10**: the client cache is
also keyed on the name, so a formula fix cannot be pushed to any client that
already asked.

---

#### C12. A zero-filled tail is a valid record, and it makes the ledger unopenable

**What goes wrong.** `:erlang.crc32(<<>>)` is `0`. So eight zero bytes parse as
`size = 0`, `crc = 0`, `payload = <<>>` — and the CRC *matches*. `scan/2`
accepts the record and calls `:erlang.binary_to_term(<<>>)`, which raises.

**Reproduced.**

```
crc32 of empty binary: 0
appended 64 zero bytes (a zero-filled tail, as ext4 can leave)
OPEN RAISED: ArgumentError — invalid external representation of a term
```

**Why this is the important one in Section 1.** The moduledoc states the
recovery contract: "a record whose length runs past the end or whose checksum
does not match is where reading stops — a process killed mid-write leaves a torn
tail… Discarding it loses exactly the transaction that never completed." That
contract is false for the *most likely physical form* of a torn tail. ext4 with
delayed allocation is well known for leaving zero-filled tails after a crash —
the behaviour behind Ted Ts'o's 2009 exchange with the desktop developers — and
a zero-filled tail does not merely fail to stop the scan, it prevents the ledger
from opening at all. Supervisor restart does not help: the bytes are still
there.

**Why the existing crash test cannot find it.** `mix test --include crash`
SIGKILLs a *process*. The page cache survives a process death, so the file is
left cleanly truncated at a write boundary — a short tail, never a zero-filled
one. The suite tests the one form of tail damage that the code already handles.
Producing the other form requires losing the *machine*, not the process:
`dm-flakey`, LazyFS, or simply appending zeros as above.

**Falsifiable claim.** For every byte string `T` appended to a valid log,
`Store.File.open/2` returns `{:ok, _}` and replays exactly the records wholly
contained in the valid prefix. `T` must include the zero-filled, the
garbage-filled and the truncated cases — not just the truncated one.

**Test.** Extend the exhaustive prefix-truncation test in **C3** with a second
dimension: for each prefix length, append each of `<<0>>*k`, random bytes, and a
repeat of earlier bytes. It stays under a second and it now covers three damage
shapes instead of one.

**Repair shape.** Reject `size == 0` explicitly, and — the change that closes
several of these at once — fold the record's own byte offset and a per-file
generation into the CRC rather than checksumming the payload alone. That makes a
zero record invalid, makes a misplaced or duplicated record invalid (which is
**C8**), and makes a record from a previous generation of the file invalid.
SQLite's WAL does exactly this with its salt and cumulative checksum. Note also
that the `size` field is currently *outside* the CRC, so a corrupted length is
undetectable by design.

**Applicability.** Single-node now.

---

#### Two more worth a line, observed but not separately reproduced

- **`$erasures` and `$backup` are nameable.** `Authority.may_name?/2` structurally
  refuses only `"$authority"`. A caller granted `"$erasures"` can read who has
  exercised a deletion right — itself personal data — and can *write* forged
  `erased_at` tombstones. Since `Keyring` reconciles against tombstones every
  time it opens, that is a remote key-destruction primitive: a caller with a
  grant to one ledger can cause irreversible data loss in others. **Claim:** the
  set of structurally unnameable ledgers equals the set of ledgers whose
  contents change authorization or key state.
- **Restore writes ledger files with `File.write!` and no atomic rename.** A
  crash mid-restore leaves a short file which, by the log format's own rule,
  opens cleanly as a shorter history. A partial restore is therefore
  indistinguishable from a successful one. **Claim:** an interrupted restore
  leaves either no ledger file or a complete one, never a short one that opens.

---



---


## Section 1 — Durability, crash consistency, and append-only log pitfalls

**System under test (for APPLICABILITY tags):** single-node Elixir/OTP immutable fact-log DB.
Append-only file, one record per transaction framed `<<size::32, crc32::32, payload>>`.
Replay scans forward and stops at the first torn/bad-CRC record. `fsync` optional, **off by default**.
Periodic checkpoint sidecar files holding facts + a byte offset. Incremental backup to S3-compatible
storage as byte-range segments, restored by sorting and concatenating.

---

### 1. Durability and crash consistency

#### 1.1 — `fsync()` reports a writeback error exactly once, then clears it

**WHAT GOES WRONG.** The Linux page cache marks a page *clean* when it hands it to the block layer,
not when the device acknowledges it. If writeback fails, the page stays clean and an error flag is
recorded. The first `fsync()` after the failure returns `EIO`; the flag is then consumed. A retried
`fsync()` returns **success** while the data is gone from both cache and disk. PostgreSQL's checkpointer
did exactly this: retry the checkpoint, get a successful `fsync()`, advance the redo pointer, discard
the WAL that could have rebuilt the lost pages. Craig Ringer's formulation: "When fsync() returns
success it means all writes since the last fsync have hit disk, but we assume it means all writes since
the last **successful** fsync have hit disk."

**CONDITIONS.** Any transient write error: a failing sector, a thin-provisioned volume hitting its
backing limit, an iSCSI/NBD/EBS volume that blips, a USB disk yanked, `dm-flakey` in error mode.
Present on ext4 and XFS. FreeBSD/Illumos re-dirty the pages and are retry-safe; NetBSD/OpenBSD/Darwin
invalidate like Linux.

**FALSIFIABLE CLAIM + TEST.** *Claim: after any `:file.sync/1` or `:file.datasync/1` returning
`{:error, _}`, the ledger process must not accept further writes to that file and must not advance the
checkpoint offset; it must escalate (crash the ledger, PostgreSQL-style PANIC).*
Test: mount the ledger on `dm-flakey` (or `dm-error`) configured to fail writes for one interval;
write N transactions with fsync on; assert the first `sync` returns `{:error, :eio}`, assert the second
`sync` **also** fails or the process has already terminated. Then reboot-simulate (drop caches, remount)
and assert no transaction that got an `:ok` reply is missing. Tooling: `dmsetup create ... flakey`,
or `CuttleFS` (FUSE, from the ATC'20 paper) which can emulate each filesystem's fsync-failure reaction.

**SOURCE.** https://danluu.com/fsyncgate/ · https://wiki.postgresql.org/wiki/Fsync_Errors ·
https://lwn.net/Articles/752093/

**APPLICABILITY.** single-node now. *Sharpened by the fact that fsync is off by default: there is no
error to ignore because there is no fsync — see 1.3.*

---

#### 1.2 — `errseq_t` (Linux ≥ 4.13) narrowed the hole but did not close it

**WHAT GOES WRONG.** Since 4.13 a 32-bit error-and-sequence counter lives on the inode's
`address_space`, so a writeback error is reported to **every** descriptor open at the time of the error,
not just the first to call `fsync()`. Three residual holes remain: (a) kernels 4.13–4.15 only report
errors that occurred after *your* `open()`; (b) the error state is lost if the inode is evicted from
cache; (c) `syncfs()` error reporting was separately broken. Jeff Layton's summary of the invariant
that survives all of it: "a lack of an error doesn't tell you anything about the data. It just tells you
that writeback hasn't hit an error *yet*."

**CONDITIONS.** Long-lived process, file opened before an error; or a file closed and reopened across
the error; or memory pressure evicting the inode between the error and the `fsync()`.

**FALSIFIABLE CLAIM + TEST.** *Claim: the ledger holds one long-lived fd for the life of the file and
never closes/reopens across a write, so an error cannot be lost to the open-after-error window; and the
recovery path never treats "fsync succeeded" as proof that earlier unsynced writes landed.*
Test: assert via `:erlang.port_info`/process state that the ledger fd is opened once at start; a static
test that no code path reopens the append file mid-life. For (b): inject an error, then force inode
eviction (`echo 2 > /proc/sys/vm/drop_caches`), then `fsync` — assert the system does not conclude
"durable".

**SOURCE.** https://lwn.net/Articles/725277/ · https://lwn.net/Articles/752613/ ·
https://www.kernel.org/doc/html/latest/filesystems/vfs.html (Handling errors during writeback)

**APPLICABILITY.** single-node now.

---

#### 1.3 — `fsync` off by default means "committed" means "in the page cache"

**WHAT GOES WRONG.** With no `fsync`, `write()` returning success only means the bytes are in the
kernel's dirty page cache. Linux flushes dirty pages on a timer governed by `dirty_expire_centiseconds`
(default 30 s) and `dirty_writeback_centiseconds` (default 5 s). A power loss or host reset loses every
transaction still in that window — potentially 30 seconds of committed facts — with **no torn record and
no CRC failure**, because the log simply ends earlier than the caller was told. A clean process crash
(BEAM exits, `kill -9`) loses nothing; only a kernel/power event does. This distinction is the single
most common source of "it passed my crash tests" false confidence: killing the OS process tests nothing
about durability.

**CONDITIONS.** Power loss, host reset, hypervisor kill, `echo b > /proc/sysrq-trigger`, cloud instance
stop. Not triggered by SIGKILL of the BEAM.

**FALSIFIABLE CLAIM + TEST.** *Claim: with `fsync: false`, transactions acknowledged within the last
`dirty_expire_centiseconds` are NOT durable across a machine-level crash; with `fsync: true`, zero
acknowledged transactions are lost.* Test both directions: (a) run in a VM (qemu), acknowledge K
transactions, `echo b > /proc/sysrq-trigger`, reboot, replay, assert loss > 0 when fsync is off
(this is a claim the docs must state, not a bug to fix) and assert loss == 0 when fsync is on;
(b) `kill -9` the BEAM and assert loss == 0 in **both** modes — proving the test suite distinguishes
process crash from machine crash.

**SOURCE.** https://www.evanjones.ca/durability-filesystem.html ·
https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html

**APPLICABILITY.** single-node now. **Highest-leverage item in this document.**

---

#### 1.4 — `fsync()` on the file does not persist the directory entry

**WHAT GOES WRONG.** `fsync(fd)` flushes the file's data and inode. It does not flush the *directory
entry* that names the inode. After a crash, a freshly created ledger file, checkpoint sidecar, or
segment file can be fully durable on disk and simultaneously **not exist** — no name points to it, so it
is unreachable (and gets reaped to `lost+found` by fsck). man 2 fsync: "Calling fsync() does not
necessarily ensure that the entry in the directory containing the file has also reached disk. For that
an explicit fsync() on a file descriptor for the directory is also needed." ALICE found six of eleven
studied applications required a directory fsync they did not perform; LevelDB does not persist the
directory entries of `.ldb` files, and ZooKeeper does not persist the directory entries of its log files
— both lead to files vanishing after a crash.

**CONDITIONS.** Every `create` + `fsync` + crash. Every `rename`-into-place + crash. Also on `unlink`
during compaction/GC — an unlink that is not directory-fsynced can be undone by a crash, resurrecting a
file you believed deleted.

**FALSIFIABLE CLAIM + TEST.** *Claim: after creating a checkpoint sidecar or a new log segment and
fsyncing it, the code fsyncs the containing directory before treating the file as existing.*
Test: strace/`fatrace` the checkpoint path and assert the syscall sequence is
`open(tmp) … write … fsync(tmp) … rename(tmp, final) … open(dir, O_RDONLY|O_DIRECTORY) … fsync(dir)`.
Crash test: `dm-log-writes` records the block trace; replay every prefix and assert that for each prefix
where the checkpoint is "visible" it is also complete. Or CrashMonkey/ACE.

**SOURCE.** https://man7.org/linux/man-pages/man2/fsync.2.html ·
https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf (§4.4.3, §4.4.4) ·
https://www.postgresql.org/message-id/E1adrDx-0001No-3p%40gemulon.postgresql.org

**APPLICABILITY.** single-node now.

---

#### 1.5 — `rename()` is atomic, but "atomic" ≠ "ordered" and ≠ "durable"

**WHAT GOES WRONG.** POSIX `rename()` is atomic with respect to *visibility*: readers see old or new,
never neither. It says nothing about whether the renamed file's **contents** are on disk when the
rename becomes visible. ALICE's Table 1 shows `[Append, rename] → Any op` ordering **fails** on
ext2, ext3-writeback, ext4-writeback and btrfs configurations: after a crash you can see the new name
pointing at a zero-length or garbage-filled file. ext4 later added the `auto_da_alloc` heuristic that
forces delayed-allocation blocks out before the rename commits — but that is a heuristic, is
configuration-dependent, and does not exist on other filesystems.

**CONDITIONS.** Checkpoint written to `foo.tmp`, renamed to `foo.ckpt`, without an intervening
`fsync(foo.tmp)`. Any "write-new-then-rename" idiom. Amplified on btrfs, which ALICE found "aggressively
persists directory operations" ahead of data.

**FALSIFIABLE CLAIM + TEST.** *Claim: the checkpoint publish path never renames a file whose data has
not been fsynced first; and a crash between fsync and rename leaves the previous checkpoint intact and
usable.* Test: ALICE-style — trace the syscalls of one checkpoint publish, enumerate all reorderings
permitted by the weakest APM (ext2/writeback), reconstruct each crash state, run recovery on each, and
assert the invariant "every acknowledged fact is present" holds in every state.

**SOURCE.** https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf (Table 1) ·
https://www.kernel.org/doc/html/latest/admin-guide/ext4.html (`auto_da_alloc`) ·
https://github.com/npm/write-file-atomic/issues/64

**APPLICABILITY.** single-node now.

---

#### 1.6 — Appends are not content-atomic: the tail can contain *garbage*, not zeros

**WHAT GOES WRONG.** An append updates two things (inode size, data block). If the size lands and the
data does not, the file grows into blocks holding **whatever was previously on that disk region** —
random old data, not zeros. ALICE distinguishes *size-atomicity* (file size updated without data) from
*content-atomicity* (the appended range contains real data). Table 1 marks `Single sector append`,
`Single block append`, `Multi-block append` and `Multi-block prefix append` as failing on ext2,
writeback modes of ext3/ext4/reiserfs, and others. The paper's conclusion is exactly the shape of this
system's risk: *"Applications have careful mechanisms to detect and repair failures in the actual data,
but overlook the presence of garbage content in the log."* LevelDB's log-append vulnerability is this
bug: "A crash can result in the appended portion of the file containing garbage; LevelDB's recovery code
does not properly handle this situation."

**CONDITIONS.** ext2, `data=writeback`, `nodelalloc` off/on interactions, reiserfs writeback, and any
filesystem without data journaling. Also on ext4 `data=ordered` if the block was preallocated
(`fallocate`) — ordering is only guaranteed for newly allocated blocks.

**FALSIFIABLE CLAIM + TEST.** *Claim: a record whose payload bytes are stale garbage from a previous
file lifetime is rejected by the frame check.* Test: build a log file, note the block offsets, `unlink`,
create a new log in the same place (or use `fallocate` to grab recycled blocks), write a partial record,
then splice in old-file bytes at the tail. Assert replay rejects it. **Stronger test:** generate the
crash states directly with ALICE's `writeback`/`ext2` APM rather than by hand.

**SOURCE.** https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf (§2.2.1, §4.2.1, §4.4.2)

**APPLICABILITY.** single-node now.

---

#### 1.7 — An all-zero region parses as a valid empty record: `crc32(<<>>) == 0`

**WHAT GOES WRONG.** zlib's CRC-32 (which `:erlang.crc32/1` uses) returns **0** for the empty binary.
Verified on this machine against the actual runtime — `erl -noshell -eval 'io:format("~p", [erlang:crc32(<<>>)])'`
prints `0`, and `python3 -c "import zlib; print(zlib.crc32(b''))"` prints `0`. Therefore the 8-byte sequence
`<<0,0,0,0, 0,0,0,0>>` decodes under the framing `<<size::32, crc32::32, payload>>` as
*size = 0, crc = 0, payload = <<>>*, and `crc32(<<>>) == 0` **matches**. A zero-filled tail — the single
most common post-crash artifact on ext4 with delayed allocation, and exactly what etcd operators see in
their WAL after a hard reboot ("many of the final entries in the WAL were zeroes") — therefore does not
terminate replay at the first bad CRC. It parses as an unbounded run of legitimate empty transactions.
Whether that is harmless or catastrophic depends on whether an empty transaction is meaningful and on
whether the replay loop terminates; at minimum it silently converts "torn tail" into "clean log", which
destroys the ability to detect truncation at all.

**CONDITIONS.** Any zero-filled region: ext4 delayed-allocation zero-fill after crash, a sparse hole
from `fallocate(FALLOC_FL_PUNCH_HOLE)` or a seek-past-EOF write, a preallocated segment, an S3 restore
that concatenated a missing byte-range as zeros, a filesystem that zeroes an unwritten extent.

**FALSIFIABLE CLAIM + TEST.** *Claim: eight zero bytes at the end of the log are rejected, not accepted
as a record.* Test (deterministic, no fault injection needed):
```elixir
File.write!(path, log_bytes <> <<0::64>>)
assert {:error, _} = Ledger.replay(path)   # currently: likely {:ok, ...}
```
Also assert `replay(<<0::size(4096)>>)` does not produce 512 empty transactions and does not loop
forever. Fix shape: a nonzero magic/type byte in the frame, a length ≥ 1 invariant, or seeding the CRC
with a nonzero constant and including the size field in the CRC.

**SOURCE.** verified locally against zlib; framing semantics per
https://github.com/google/leveldb/blob/main/doc/log_format.md (LevelDB's trailer "must consist entirely
of zero bytes and must be skipped by readers" — i.e. LevelDB explicitly reserves zeros as *not a
record*) · https://github.com/etcd-io/etcd/issues/11488

**APPLICABILITY.** single-node now. **Highest-leverage item in this document.**

---

#### 1.8 — The CRC does not cover the size field, so a corrupted length is undetectable

**WHAT GOES WRONG.** In `<<size::32, crc32::32, payload>>` the natural reading is that `crc32` covers
only `payload`. A single bit flip in the `size` field then cannot be caught: the reader takes `size`
bytes, computes a CRC over the wrong span, and either (a) fails CRC and stops replay early, silently
discarding every valid record that follows, or (b) — for a corruption that shortens `size` — consumes a
prefix whose CRC coincidentally matches nothing and desynchronizes the frame stream permanently.
LevelDB avoids this by checksumming *"type and data"*, i.e. the header fields are inside the CRC.

**CONDITIONS.** Any bit flip in the first four bytes of a frame: bitrot, DRAM error before the write,
a shorn write boundary landing mid-header, an FTL misdirected write.

**FALSIFIABLE CLAIM + TEST.** *Claim: flipping any single bit anywhere in the file — including the
size field — is detected.* Test: property test. For a log of R records and B bytes, for each of the
`8*B` single-bit flips (or a random sample), assert `replay/1` either returns the exact original fact
set or returns an error; assert it **never** returns a different-but-successful fact set. Today, bit
flips in `size` will fail this.

**SOURCE.** https://github.com/google/leveldb/blob/main/doc/log_format.md ·
https://www.sqlite.org/atomiccommit.html §6.2 (checksums "don't guarantee correctness, only reduce
probability of undetected corruption")

**APPLICABILITY.** single-node now.

---

#### 1.9 — A corrupted 32-bit length is an unbounded allocation request

**WHAT GOES WRONG.** `size::32` unsigned admits values up to 4 GiB. Replay reads `size` and allocates
or reads that many bytes *before* it can check the CRC — the CRC is over data you have not read yet.
A single flipped high bit in the length turns a 200-byte record into a 2 GiB read. On the BEAM this is
a binary allocation that can exceed the VM's memory and take down the node, and because it happens
during *recovery*, it is a crash loop: the supervisor restarts, replay runs again, OOM again. This is
the classic "attacker-controlled length prefix" bug class, reachable here without an attacker — bitrot
suffices.

**CONDITIONS.** Any corruption of the length field; a truncated file where the last length field
straddles EOF; a restored S3 segment set with a gap.

**FALSIFIABLE CLAIM + TEST.** *Claim: replay never allocates more than `min(declared_size,
bytes_remaining_in_file, max_record_size)` and rejects any frame whose declared size exceeds the file's
remaining bytes.* Test: craft a log with a final frame declaring `0xFFFFFFFF`; assert replay returns
`{:error, :bad_frame}` within a bounded time and with bounded memory. Measure with
`:erlang.memory(:binary)` before/after, assert delta < 10 MB. Add a fuzz test: random single-byte
mutations over the whole file × 10k iterations, assert no OOM, no infinite loop, no unbounded runtime.

**SOURCE.** https://github.com/google/leveldb/blob/main/doc/log_format.md (LevelDB bounds records to a
32 KiB block and uses a 16-bit length for exactly this reason) ·
https://github.com/facebook/rocksdb/wiki/WAL-Recovery-Modes

**APPLICABILITY.** single-node now.

---

#### 1.10 — "Stop at the first bad CRC" silently discards committed data after a hole

**WHAT GOES WRONG.** Forward-scan-until-bad-CRC is correct only if corruption can only ever be at the
tail. It cannot be assumed: a latent sector error, a misdirected FTL write, or an `fsync`-less
out-of-order writeback can corrupt a record in the **middle** of the log while everything after it is
intact and was acknowledged to clients. Replay then stops at record k and silently drops records
k+1…n — no error, no warning, a shorter but internally consistent database. This is the exact failure
RocksDB documents: with `kPointInTimeRecovery` "the DB can contain nothing for a key that was written
earlier, while it contains a value for a supposedly newer key". RocksDB's whole four-mode taxonomy
(`kAbsoluteConsistency`, `kTolerateCorruptedTailRecords`, `kPointInTimeRecovery`,
`kSkipAnyCorruptedRecords`) exists because *"the system cannot differentiate between corruption at the
tail of the log and incomplete write"* — and this system has silently picked one mode with no way to
distinguish the safe case from the dangerous one.

**CONDITIONS.** Corruption anywhere but the last record. Guaranteed reachable in an fsync-less system
because writeback order is not append order.

**FALSIFIABLE CLAIM + TEST.** *Claim: if a record in the middle of the log fails CRC but valid records
follow it, replay reports an error rather than returning a truncated success.* Test: write 1000
transactions, flip one byte in record 500's payload, replay. Assert the result is `{:error, ...}` or a
loud `{:ok, facts, [truncated_at: 500, valid_records_after: 500]}` — **not** a silent `{:ok, facts_1_499}`.
Second assertion: replay must be able to *report* how many bytes past the stopping point look like
well-framed records, so an operator can tell "torn tail" from "hole".

**SOURCE.** https://github.com/facebook/rocksdb/wiki/WAL-Recovery-Modes ·
https://github.com/facebook/rocksdb/pull/6351

**APPLICABILITY.** single-node now. **Highest-leverage item in this document.**

---

#### 1.11 — Erlang's `delayed_write` has its own fsyncgate: the error is reported once, on an operation that is then not executed

**WHAT GOES WRONG.** OTP's `file:open/2` `{delayed_write, Size, Delay}` option buffers writes in the
BEAM's file driver. The docs are explicit: *"the result of `write/2` calls can prematurely be reported
as successful, and if a write error occurs, the error is reported as the result of the next file
operation, which is not executed."* So the failing operation is *also* skipped, and a naive
`with :ok <- ...` chain that retries or ignores will drop it. The docs further warn that
*"`close/1` can return `{error, enospc}`, as there is not enough space on the disc for previously
written data. `close/1` must probably be called again, as the file is still open."* This is the
PostgreSQL bug reproduced inside the runtime, one layer above the kernel.

**CONDITIONS.** Ledger opened with `:delayed_write` (a natural choice for append throughput), plus any
write error: ENOSPC, EIO, quota.

**FALSIFIABLE CLAIM + TEST.** *Claim: the ledger does not use `:delayed_write`; or, if it does, every
`file:write/2` result is checked, the error path terminates the ledger, and `close/1` is retried.*
Test: open with `delayed_write` on a tiny tmpfs/loopback filesystem, write past capacity, assert the
error surfaces and the transaction that "succeeded" is not reported as durable. Assert `close/1` is
called twice. Also a static test: grep the open-options for `:delayed_write`.

**SOURCE.** https://www.erlang.org/doc/apps/kernel/file.html

**APPLICABILITY.** single-node now.

---

#### 1.12 — Erlang's `sync/1`, `datasync/1` and the `sync` open mode "might have no effect"

**WHAT GOES WRONG.** OTP documents `file:sync/1` as "Ensures that any buffers kept by the operating
system … are written to disk" but adds *"On some platforms, this function might have no effect."* Same
for `datasync/1`. For the `sync` open mode (O_SYNC) it warns *"the exact semantics of this flag differ
from platform to platform. For example, none of Linux or Windows guarantees that all file metadata are
also written before the call returns."* A durability claim built on `:file.sync/1` is therefore a claim
about the platform, not about the API, and must be tested per-platform. On macOS specifically,
`fsync()` — which is what OTP calls — does **not** flush the drive's write cache; only
`fcntl(F_FULLFSYNC)` does, and OTP does not expose it.

**CONDITIONS.** macOS/APFS development machines. Windows. Any platform where OTP's NIF degrades to a
no-op.

**FALSIFIABLE CLAIM + TEST.** *Claim: on macOS, `:file.sync/1` does not make data survive power loss;
therefore the durability test suite must be marked as unverifiable on Darwin and must run on Linux in
CI.* Test: a build-time/boot-time assertion that refuses to advertise `durable: true` on `:darwin`
unless an explicit F_FULLFSYNC NIF is present. Empirical test: measure `:file.sync/1` latency on an NVMe
device — a real cache flush costs hundreds of microseconds to milliseconds; a no-op costs a few
microseconds. Assert `p50 > 100µs` as a smoke test that the sync is real.

**SOURCE.** https://www.erlang.org/doc/apps/kernel/file.html ·
https://www.sqlite.org/atomiccommit.html §9.2 (`PRAGMA fullfsync` on macOS) ·
https://bonsaidb.io/blog/acid-on-apple/

**APPLICABILITY.** single-node now.

---

#### 1.13 — macOS `F_BARRIERFSYNC` orders but does not persist

**WHAT GOES WRONG.** Apple offers three levels: `fsync()` (page cache → device, no cache flush),
`F_BARRIERFSYNC` (device honours ordering relative to later writes, but data may still be in volatile
cache), and `F_FULLFSYNC` (actual flush to media). Apple's own SQLite build silently reimplements
`PRAGMA fullfsync` in terms of `F_BARRIERFSYNC`, so a documented-durable pragma is not durable — "a
feature that's documented to be specific to macOS doesn't behave as documented on macOS." A test suite
that validates durability on a Mac laptop validates ordering, not persistence.

**CONDITIONS.** Any macOS host, including CI runners on Apple silicon.

**FALSIFIABLE CLAIM + TEST.** *Claim: the durability test suite fails closed on Darwin rather than
passing vacuously.* Test: the crash-consistency suite asserts `:os.type() == {:unix, :linux}` (or that
a genuine `F_FULLFSYNC` path is in use) and otherwise skips with an explicit "durability unverified on
this platform" marker that CI treats as a failure for release builds.

**SOURCE.** https://bonsaidb.io/blog/acid-on-apple/ ·
https://mjtsai.com/blog/2022/02/17/apple-ssd-benchmarks-and-f_fullsync/ ·
https://sqlite.org/forum/info/b94afa45dda82aae8cbf49f9d511a00b332870fc926cba18954acd889bbfb7cd

**APPLICABILITY.** single-node now.

---

#### 1.14 — Filesystem data mode changes what a crash can produce, and `data=writeback` exposes stale data

**WHAT GOES WRONG.** ext4's three modes give three different post-crash worlds. `data=journal`: data
goes through the journal, so appends are effectively content-atomic and ordered. `data=ordered`
(default): data is forced to the main filesystem before its metadata commits — so a grown file size
implies the data landed, but only for *newly allocated* blocks. `data=writeback`: no ordering at all;
the kernel docs warn it "can potentially leave stale data exposed in recently written files in case of
an unclean shutdown, which could be a security exposure." A test suite that only runs on ext4 default
is testing the *friendliest* configuration and will not reproduce garbage-tail bugs.

**CONDITIONS.** Anyone running the DB on `data=writeback` (chosen for performance), on ext2, on XFS
(no data journaling at all), or on a container image layer.

**FALSIFIABLE CLAIM + TEST.** *Claim: recovery invariants hold on ext4 `data=journal`, ext4
`data=ordered`, ext4 `data=writeback`, XFS, and btrfs.* Test: parameterize the whole crash-consistency
suite over loopback-mounted filesystems: `mkfs.ext4` + `mount -o data=writeback`, `mkfs.xfs`,
`mkfs.btrfs`. This is exactly ALICE's finding — "testing applications on only a few file systems does
not work."

**SOURCE.** https://www.kernel.org/doc/html/latest/admin-guide/ext4.html ·
https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf

**APPLICABILITY.** single-node now.

---

#### 1.15 — Disk write caches, barriers, and `nobarrier`

**WHAT GOES WRONG.** Drives acknowledge writes into a volatile DRAM cache. `fsync()` translates to a
cache-flush (or FUA) command; the kernel docs describe barriers as what "enforce proper on-disk ordering
of journal commits, making volatile disk write caches safe to use, at some performance penalty."
Mounting `nobarrier` (or `barrier=0`), or running on a controller whose flush is a no-op, makes every
`fsync()` in the system a lie — including the filesystem's own journal commits, so metadata can be
reordered too. RHEL's guidance is that `nobarrier` is only safe with a non-volatile, battery-backed
cache or with the drive cache disabled.

**CONDITIONS.** `nobarrier` mount; RAID controllers with write-back cache and a dead BBU; VM images on
a host that caches (`cache=writeback` in qemu/libvirt); some virtualization stacks that swallow flush.

**FALSIFIABLE CLAIM + TEST.** *Claim: the runtime detects and refuses/warns when its mount has barriers
disabled.* Test: parse `/proc/mounts` for `nobarrier`/`barrier=0` and assert a startup warning.
Empirical: `fio --fsync=1 --bs=4k --rw=write` — a genuine flush on a spinning disk caps out near the
rotational limit (~100–200 IOPS); thousands of fsync'd IOPS/s on a consumer SATA disk proves the flush
is not reaching media.

**SOURCE.** https://www.kernel.org/doc/html/latest/admin-guide/ext4.html ·
https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/storage_administration_guide/writebarrieronoff

**APPLICABILITY.** single-node now.

---

#### 1.16 — SQLite's enumerated failure modes are a ready-made checklist

**WHAT GOES WRONG.** SQLite's `atomiccommit.html` §9 lists the ways a correct commit protocol still
loses: broken locking on network filesystems (SMB/CIFS/NFS — "avoid using SQLite on network
filesystems"); incomplete disk flushes ("IDE disk controllers lie about reaching disk oxide"); partial
file deletions (the assumption that unlink is atomic); garbage written into files by unrelated
processes; and **deletion or renaming of a hot journal** — an operator who "cleans up" the
`-journal` file after a crash converts a recoverable state into permanent corruption. The document's
own framing: "Every now and then someone discovers a new failure mode."

**CONDITIONS.** Operator intervention after a crash; hard/symbolic links to the data file; fsck moving
files to `lost+found`; multi-protocol network mounts.

**FALSIFIABLE CLAIM + TEST.** *Claim: deleting the checkpoint sidecar after a crash is safe (the log
alone reconstructs everything), and deleting the log while keeping a checkpoint is loudly detected —
not silently accepted as "the database is just small."* Test: for each subset of {log, checkpoint,
segment N}, remove it and assert recovery either succeeds with a complete fact set or fails loudly with
a named missing-artifact error. Never a silent partial success.

**SOURCE.** https://www.sqlite.org/atomiccommit.html §9 · https://www.sqlite.org/howtocorrupt.html

**APPLICABILITY.** single-node now.

---

#### 1.17 — SQLite's powersafe-overwrite assumption: writes have a blast radius

**WHAT GOES WRONG.** SQLite defines *powersafe overwrite* as the property that "when an application
writes a range of bytes in a file, no bytes outside of that range will change, even if a crash or power
failure occurs during the write." Where PSOW does **not** hold, an interrupted sector write can leave
the *entire sector* returned as all-zeros or all-ones by ECC — corrupting bytes the application never
touched. SQLite therefore treats sector size as a "blast radius" and, historically, journalled every
byte of every affected sector. Applied here: appending a 200-byte record can, on a non-PSOW device,
damage the *previous* record that shares the tail sector — a previously durable, previously
acknowledged transaction.

**CONDITIONS.** Power loss during an append whose start offset is not sector-aligned. Devices without
power-loss protection. 512e drives (512-byte logical, 4 KiB physical) where the real blast radius is
4 KiB, not 512 bytes.

**FALSIFIABLE CLAIM + TEST.** *Claim: corrupting the final 4 KiB of the log damages at most the records
wholly contained in it, and every earlier record still replays.* Test: write N records, overwrite the
last 4096 bytes with zeros/0xFF, assert replay recovers every record that ended before that boundary.
This will fail if a record straddles the boundary — which is the point: the test measures how much
previously-acknowledged data a single-sector event can cost.

**SOURCE.** https://www.sqlite.org/psow.html · https://www.sqlite.org/atomiccommit.html §2, §6.1

**APPLICABILITY.** single-node now.

---

#### 1.18 — Torn writes: the device guarantees a sector, the record spans many

**WHAT GOES WRONG.** Storage guarantees atomicity only at the logical block (historically 512 B, now
often 4 KiB). A transaction record of arbitrary size spans many blocks, and a power loss can persist an
arbitrary subset of them — including a *non-prefix* subset, because the FTL/scheduler need not write
them in order. So "the tail is truncated" is the optimistic case; "the middle is missing and the end is
there" is permitted. Detection requires a checksum over the whole record — which this system has —
but only if the checksum covers everything and the reader cannot be tricked into re-framing
(see 1.7, 1.8). Note that LSM-shaped, append-only, write-once files are *structurally* immune to torn
*pages* (no in-place update), which is a real advantage of this design — the residual risk is confined
to the tail record and to framing.

**CONDITIONS.** Power loss mid-append of a multi-block record. Amplified by no fsync (many records in
flight simultaneously).

**FALSIFIABLE CLAIM + TEST.** *Claim: for any subset S of the 4 KiB blocks of the final record being
written, replay yields either "record present and complete" or "record absent", never a partial
record.* Test: enumerate block subsets with `dm-log-writes` (records the block-level write stream;
`replay-log` can restore the device to any prefix, and `--fsck` runs a checker at each point). This is
the canonical tool for exactly this claim.

**SOURCE.** https://transactional.blog/blog/2025-torn-writes ·
https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/log-writes.html

**APPLICABILITY.** single-node now.

---

#### 1.19 — CRC-32 has finite detection power and it degrades with record size

**WHAT GOES WRONG.** CRC-32 is not a hash; its guarantees are stated as a Hamming distance for a given
maximum message length. The common CRC-32 polynomial gives HD=4 up to ~12 kbit — all 1-, 2- and 3-bit
errors detected — but at that length 223,059 specific 4-bit error patterns are undetected, and beyond
its length bound the guarantee drops to HD=3 and then HD=2. A multi-megabyte transaction record
protected by one CRC-32 is well outside the polynomial's designed range. Separately, CRC-32 is linear
and trivially forgeable — it detects accident, not tampering. SQLite says it plainly: checksums "don't
guarantee correctness, only reduce probability of undetected corruption."

**CONDITIONS.** Large records (bulk fact loads, large payloads); burst errors longer than 32 bits
(a 64 KiB region corrupted by a misdirected write, per the CERN study where 80% of disk errors were
64 KiB regions).

**FALSIFIABLE CLAIM + TEST.** *Claim: the maximum record size is bounded such that CRC-32 retains
HD≥4, or a stronger check (CRC-64/xxh3/BLAKE3) is used above that bound.* Test: assert a
`@max_record_bytes` constant exists and is ≤ 1512 bytes for HD=4 under the standard polynomial (or
document the chosen weaker bound). Empirical test: inject 4-bit burst errors at random positions in
records of increasing size, measure the undetected rate, and assert it matches the model.

**SOURCE.** https://users.ece.cmu.edu/~koopman/pubs/ray06_crcalgorithms.pdf ·
https://users.ece.cmu.edu/~koopman/roses/dsn04/koopman04_crc_poly_embedded.pdf ·
https://indico.cern.ch/event/13797/contributions/1362288/attachments/115080/163419/Data_integrity_v3.pdf

**APPLICABILITY.** single-node now.

---

#### 1.20 — Silent corruption is a measured rate, not a hypothetical

**WHAT GOES WRONG.** NetApp's FAST'08 study of 1.53 million drives over 41 months found **more than
400,000 checksum mismatches**, plus identity discrepancies (the block is intact but is the wrong block
— a misdirected write) and parity inconsistencies. Identity discrepancies matter most here: a
misdirected write can land a *valid, correctly-CRC'd* record at the wrong offset. CERN's 2007 study
found 500 errors across 100 nodes in five weeks of writing 2 GB files to 3,000+ nodes, with the error
size distribution 10% single-bit, 10% one sector, **80% 64 KiB regions** — burst errors far bigger than
a CRC-32's design point.

**CONDITIONS.** Continuous, at low rate, on every deployment. Rate scales with bytes stored × time.

**FALSIFIABLE CLAIM + TEST.** *Claim: a record that is internally valid but written at the wrong
offset is detected.* Test: take two valid records A (offset X) and B (offset Y), swap them in the file,
replay. Assert detection. This requires the frame to bind the record to its position or its sequence —
a monotonically increasing transaction id checked for contiguity, or the offset folded into the CRC.
Without that, a misdirected write is undetectable by CRC alone.

**SOURCE.** https://www.usenix.org/legacy/event/fast08/tech/full_papers/bairavasundaram/bairavasundaram.pdf ·
https://indico.cern.ch/event/13797/contributions/1362288/attachments/115080/163419/Data_integrity_v3.pdf

**APPLICABILITY.** single-node now.

---

#### 1.21 — After a failed `fsync`, the page cache may hand you the *new* data on re-read

**WHAT GOES WRONG.** The ATC'20 CuttleFS study found that across ext4, XFS and btrfs, "pages are always
marked clean" after a failed writeback — but *what the page contains* varies. On some configurations a
subsequent `read()` returns the **new** (never-persisted) data from the still-resident clean page; after
eviction, the same read returns the **old** data from disk. So an application that tries to recover from
an fsync failure by re-reading and re-writing gets a different answer depending on memory pressure. None
of the five studied applications (PostgreSQL, LMDB, LevelDB, SQLite, Redis) handled this correctly.

**CONDITIONS.** Any fsync failure followed by an in-process recovery attempt; outcome flips based on
whether the page was evicted.

**FALSIFIABLE CLAIM + TEST.** *Claim: the ledger never attempts in-process recovery from a sync
failure by re-reading its own file; it terminates and recovers from the on-disk log via a fresh replay
with a cold cache.* Test: inject an fsync failure (CuttleFS or dm-flakey), then with and without
`drop_caches`, assert the final recovered fact set is **identical** in both runs. Divergence between the
two proves the recovery path is reading the page cache instead of the disk.

**SOURCE.** https://www.usenix.org/conference/atc20/presentation/rebello ·
https://research.cs.wisc.edu/adsl/Publications/atc20-cuttlefs.pdf

**APPLICABILITY.** single-node now.

---

#### 1.22 — "Read your own writes" from the page cache is not evidence of durability

**WHAT GOES WRONG.** A test that writes a transaction, reads it back through the same filesystem, and
asserts equality tests nothing about the disk — the read is served from the same dirty page that has
never left RAM. The entire class of "I wrote it and read it back, so it's fine" tests is vacuous for
durability. The only reads that carry information are reads after the cache is cold: a fresh mount, a
`drop_caches`, `O_DIRECT`, or a different machine reading the same bytes.

**CONDITIONS.** Every naive round-trip test.

**FALSIFIABLE CLAIM + TEST.** *Claim: every durability assertion in the suite is made after
cache-invalidation.* Test: a meta-test — each durability test must call a helper that does
`:file.close`, `sync && echo 3 > /proc/sys/vm/drop_caches` (or unmount/remount the loopback device)
before reading. Grep the test suite for reads not preceded by that helper.

**SOURCE.** https://www.evanjones.ca/durability-filesystem.html ·
https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html

**APPLICABILITY.** single-node now.

---

#### 1.23 — `O_DIRECT` is not durability, and `O_DSYNC` is not metadata durability

**WHAT GOES WRONG.** `O_DIRECT` bypasses the page cache but does not flush the device cache — the write
can still sit in volatile DRAM on the drive. It also has alignment requirements (buffer, offset and
length aligned to the logical block size) and silently falls back to buffered I/O in edge cases.
`O_DSYNC` gives per-write data durability but "none of Linux or Windows guarantees that all file
metadata are also written before the call returns" — so a file whose *size* has not been persisted can
have durable data that recovery cannot see. The correct combination for direct durable writes is
`O_DIRECT|O_DSYNC`, plus a directory fsync on create.

**CONDITIONS.** Anyone reaching for O_DIRECT for latency; unaligned appends; filesystems that silently
fall back.

**FALSIFIABLE CLAIM + TEST.** *Claim: if O_DIRECT is used, all appends are block-aligned in offset and
length, and O_DSYNC is set.* Test: strace the write path and assert every `pwrite` offset and length is
a multiple of the device's `logical_block_size` (read from
`/sys/block/<dev>/queue/logical_block_size`); assert the open flags include both. Verify with `blktrace`
that a flush/FUA is actually emitted per commit.

**SOURCE.** https://www.evanjones.ca/durability-filesystem.html ·
https://www.erlang.org/doc/apps/kernel/file.html (the `sync` open mode caveat)

**APPLICABILITY.** single-node now.

---

#### 1.24 — mmap gives away control of *when* dirty pages hit disk

**WHAT GOES WRONG.** If any part of the ledger or checkpoint path uses mmap (tempting for fast replay
of a checkpoint), the CIDR'22 paper's first problem applies: "due to transparent paging, the OS can
flush a dirty page to secondary storage at any time, irrespective of whether the writing transaction has
committed. The DBMS cannot prevent these flushes and receives no warning when they occur." `mlock` does
not help — locked pages are still written back. There is no way to implement "nothing is durable until
the commit record is durable" over a plain mmap.

**CONDITIONS.** Any `mmap(MAP_SHARED)` write path. LevelDB 1.10 had exactly this bug and it was fixed by
switching to `read()`/`write()` in 1.15.

**FALSIFIABLE CLAIM + TEST.** *Claim: no write path uses mmap; checkpoints are written with ordinary
buffered or direct writes.* Test: static — grep for `:mmap`, NIF mmap usage, `:persistent_term` backed
by mapped files. Dynamic — check `/proc/<pid>/maps` for the ledger and checkpoint files during a write
workload and assert they do not appear as shared file mappings.

**SOURCE.** https://db.cs.cmu.edu/papers/2022/cidr2022-p13-crotty.pdf §3.1 ·
https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf (LevelDB-1.10 mmap atomicity vulnerability)

**APPLICABILITY.** single-node now (contingent on mmap being used at all).

---

#### 1.25 — Under mmap, an I/O error arrives as `SIGBUS`, not an error return

**WHAT GOES WRONG.** "any code that interacts with mmap-backed memory can now produce a SIGBUS that the
DBMS must deal with via cumbersome signal handlers." On the BEAM a SIGBUS is not catchable in Elixir —
it kills the VM. And a checksum validated once at load time is worthless under mmap, because the OS may
have transparently evicted and reloaded the page since: "the DBMS would need to validate the checksum on
every page access."

**CONDITIONS.** Latent sector error under a mapped region; a mapped file truncated by another process.

**FALSIFIABLE CLAIM + TEST.** *Claim: no mapped-file access path exists, so no SIGBUS path exists.*
Test: as 1.24, plus — if mmap is used — truncate the mapped file from another process while a read is in
flight and assert the node survives with an error rather than dying.

**SOURCE.** https://db.cs.cmu.edu/papers/2022/cidr2022-p13-crotty.pdf §3.3

**APPLICABILITY.** single-node now (contingent).

---

#### 1.26 — NFS: `close()` is where writes fail, and a server reboot re-dirties pages behind your back

**WHAT GOES WRONG.** On NFS the client buffers writes and can defer them to `close()` — so
`write()` returning `:ok` carries even less information than usual, and `close()` can return `EDQUOT` or
`ENOSPC` for data written long ago (`man 2 fsync` lists `EDQUOT` specifically for this NFS case). Worse,
when the client detects a server reboot it *re-dirties* pages that were not committed and flags the
originating file descriptor to redrive them — which, as the kernel patch series states, "violates the
fsync() requirement that we should be synchronising all writes to disk": a concurrent `fsync()` from a
different fd can return success while the data is still pending. Silly-rename semantics also mean an
open-but-unlinked file simply disappears if the server reboots.

**CONDITIONS.** Ledger on an NFS mount (common in "just point it at the NAS" deployments), or on
EFS/Filestore.

**FALSIFIABLE CLAIM + TEST.** *Claim: the runtime refuses to open a ledger on a filesystem type in a
deny-list (nfs, nfs4, cifs, smbfs, fuse.s3fs, 9p), or at minimum warns loudly at startup.*
Test: read the fs magic via `statfs` (or parse `/proc/mounts`) for the data directory and assert the
deny-list check fires. Integration test: run against a local `nfsd` export, restart the server
mid-workload, assert acknowledged transactions survive or the system refused to start.

**SOURCE.** https://man7.org/linux/man-pages/man2/fsync.2.html (EDQUOT) ·
https://lkml.rescloud.iu.edu/2208.3/05590.html (NFS: Fix another fsync() issue after a server reboot) ·
https://www.sqlite.org/atomiccommit.html §9.1

**APPLICABILITY.** single-node now.

---

#### 1.27 — File locking is broken on network filesystems, so two nodes can open the same ledger

**WHAT GOES WRONG.** SQLite's §9.1: locking is unreliable on SMB/CIFS and many NFS implementations, and
different locking protocols on the same file do not exclude one another (AFP locks do not exclude
dot-file locks on macOS). For an append-only log, two writers with independent file offsets interleave
partial records and destroy framing permanently — every subsequent replay stops at the first
interleaved record.

**CONDITIONS.** Two BEAM nodes pointed at the same directory (a rolling deploy, a stale container, an
operator running a one-off `mix` task). Note the repo ground rule "Deploys reset in-flight work" — this
is the storage-level version of that hazard.

**FALSIFIABLE CLAIM + TEST.** *Claim: a second process cannot open the ledger for writing; the second
open fails fast with a named error.* Test: spawn two OS processes, both open the ledger, assert exactly
one succeeds. Use an `O_EXCL` lock file **plus** `flock`/`fcntl` and verify the lock is released on
`SIGKILL` (flock is, an O_EXCL sentinel is not — test that stale-lock recovery exists and cannot
false-positive). Adversarial test: both processes append 10k records concurrently with the lock
disabled, assert replay detects corruption rather than silently returning a subset.

**SOURCE.** https://www.sqlite.org/atomiccommit.html §9.1 · https://www.sqlite.org/howtocorrupt.html

**APPLICABILITY.** single-node now.

---

#### 1.28 — ENOSPC mid-append leaves a short write, and `write()` is allowed to be partial

**WHAT GOES WRONG.** POSIX `write()` may transfer fewer bytes than requested and return success for the
prefix. On a full filesystem an append can land 3,000 of 4,096 bytes and return 3,000. If the caller
does not loop on the residual — or treats a short write as an error and retries the whole record — the
log gets a truncated record, or a duplicated prefix, at the exact moment the system is under stress.
`fsync()` itself can return `ENOSPC` (delayed allocation defers the space check to writeback time), and
Erlang's docs warn `close/1` can return `{error, enospc}` for data written earlier.

**CONDITIONS.** Disk full; quota exceeded; thin-provisioned volume exhausted at the array; a
`fallocate`-less append on a nearly full filesystem.

**FALSIFIABLE CLAIM + TEST.** *Claim: the ledger fills a filesystem to exhaustion without producing an
unrecoverable log; every acknowledged transaction replays, and no partially written record is ever
acknowledged.* Test: `mount` a 16 MB loopback ext4, write until `ENOSPC`, note the last transaction id
that got `:ok`, remount and replay, assert every id ≤ that is present. Repeat 100× at randomized fill
levels. Also assert the write path loops on short writes (unit test with a mock that returns partial
counts).

**SOURCE.** https://man7.org/linux/man-pages/man2/fsync.2.html (ENOSPC, EDQUOT) ·
https://www.erlang.org/doc/apps/kernel/file.html · https://www.evanjones.ca/durability-filesystem.html

**APPLICABILITY.** single-node now.

---

#### 1.29 — Recovery code is the least-tested code, and the literature quantifies it

**WHAT GOES WRONG.** Every study that has looked has found the recovery path broken in production
systems. ALICE (OSDI'14): 60 static vulnerabilities across 11 mature applications, 156 dynamic, failures
in **over 4,000 crash states**; 7 of 11 suffered data loss, 2 suffered *silent* errors; roughly half the
vulnerabilities manifest on then-current Linux filesystems. "Torturing Databases for Fun and Profit"
(OSDI'14) tested eight widely used databases under simulated power faults and found **all eight** exhibit
erroneous behavior, with reproducible data loss in the commercial ones. FAST'17 (Ganesan et al.) found
that in eight distributed storage systems, "a single file-system fault can cause catastrophic outcomes
such as data loss, corruption, and unavailability" — redundancy did not save them. The consistent
finding is that these bugs are not exotic; they are the default state of untested recovery code.

**CONDITIONS.** Always. The recovery path runs once per crash, in production, unobserved.

**FALSIFIABLE CLAIM + TEST.** *Claim: the recovery path has ≥ 90% line and branch coverage, and every
branch is reached by a test that constructs the corresponding on-disk state.* Test: run coverage
(`mix test --cover`) restricted to the replay/recovery modules; assert the threshold. Structural test:
enumerate every `{:error, reason}` the replay code can return and assert each has a test that produces
exactly that on-disk state.

**SOURCE.** https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf ·
https://www.usenix.org/conference/osdi14/technical-sessions/presentation/zheng_mai ·
https://www.usenix.org/conference/fast17/technical-sessions/presentation/ganesan

**APPLICABILITY.** single-node now (the FAST'17 item: only if distributed).

---

#### 1.30 — Fault injection tooling: what a claims-based suite should actually be built on

**WHAT GOES WRONG (as a gap).** Hand-rolled corruption tests explore a vanishingly small fraction of the
crash-state space. The literature's tools exist precisely because manual tests miss the interesting
states: **ALICE** (syscall-trace → APM → enumerate crash states → run your checker on each),
**BOB** (block-order breaker: reorder the block trace to discover a filesystem's real persistence
properties), **CuttleFS** (FUSE filesystem that emulates each real filesystem's fsync-failure reaction
and can evict specific clean pages on command), **dm-log-writes** (device-mapper target that records the
block write stream with flush/FUA markers so you can restore the device to any point and run a checker),
**dm-flakey**/**dm-error** (inject EIO on a schedule), **CrashMonkey/ACE** (bounded black-box crash
testing).

**CONDITIONS.** N/A — this is the harness.

**FALSIFIABLE CLAIM + TEST.** *Claim: the crash-consistency suite explores at least the set of crash
states reachable by reordering the block trace of one transaction + one checkpoint, and asserts the
recovery invariant on each.* Test: wire `dm-log-writes` under the loopback data device; for each
recorded flush boundary, `dm-log-writes` `replay-log` up to that point, mount, run replay, assert
"every acknowledged fact present, no unacknowledged fact present, no crash, bounded memory". Count the
states explored and assert the count is > 1.

**SOURCE.** https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/log-writes.html ·
https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf ·
https://www.usenix.org/conference/atc20/presentation/rebello ·
https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-flakey.html

**APPLICABILITY.** single-node now.

---

#### 1.31 — Unserializable writes: acknowledged, flushed writes vanish or reorder inside the SSD

**WHAT GOES WRONG.** Zheng et al. issued writes with `O_SYNC|O_DIRECT` (verified to emit device cache-flush
commands) and cut power. After repower, writes were **missing or in an order impossible under any serial
execution**. Three FTL mechanisms named: the page is programmed but its valid bit is never set, so the FTL
keeps mapping the old page; the new page is marked valid but the old one is never invalidated, so FTL
rebuild picks the stale one; or a program-read-verify iteration is interrupted and the page is marked
invalid. **8 of 15 SSDs** exhibited it, plus **one hard drive** (i.e. it ignored flush). Rates per power
fault: ~991 (SSD#4), ~802 (SSD#2), ~318 (SSD#13). No correlation with price.

**CONDITIONS.** Concurrent writes, power cut, device with a volatile write buffer. Present on *enterprise*
drives.

**FALSIFIABLE CLAIM + TEST.** *Claim: a post-crash log can contain record k+1 while record k — written
earlier by the same writer, both fsynced — is absent. Replay must detect this hole rather than stop at it.*
Test: writers emit monotonically numbered records with embedded timestamps; after repower, reconstruct a
happens-before partial order and count unserialized writes (Zheng uses Golab et al.'s algorithm and reports
a lower bound). Cheaper proxy: `dm-flakey` `drop_writes` on a random subset of bios during an append run.

**SOURCE.** https://www.usenix.org/system/files/conference/fast13/fast13-final80.pdf §5.4

**APPLICABILITY.** single-node now. **This is the mechanism that makes "stop at first bad CRC" unsafe: a
dropped write is a *hole*, not a *tail*.**

---

#### 1.32 — Shorn writes tear a 4 KiB block at 512-byte granularity

**WHAT GOES WRONG.** A 4 KiB logical write lands as a mix of new and old bytes at 512-byte boundaries —
observed: first 3,584 bytes new / last 512 old; first 1,536 new / last 2,560 old. Every observed new-portion
size was a multiple of 512, evidence that some FTLs program in 512-byte sub-pages and map one 4 KiB logical
block across several, contradicting vendor claims of 4 KiB atomicity. **72 shorn writes in 441 test
iterations across 3 drives** — and the two worst offenders were the most expensive "enterprise-class" SLC
drives in the study.

**CONDITIONS.** Power cut during a ≥4 KiB write. Independent of SLC vs MLC and of price.

**FALSIFIABLE CLAIM + TEST.** *Claim: no single record write is atomic; a record can exist whose first
k×512 bytes are from generation N and remainder from generation N−1.* Test: fill the device with
generation-N records where every 512-byte slice is independently identifiable (repeated randomized headers),
overwrite in place with generation N+1, cut power, scan for mixed-generation blocks. Assert the framing
rejects every such record.

**SOURCE.** https://www.usenix.org/system/files/conference/fast13/fast13-final80.pdf §5.3

**APPLICABILITY.** single-node now.

---

#### 1.33 — Misdirected ("flying") writes: correct data at the wrong offset

**WHAT GOES WRONG.** A well-formed block is written to the wrong LBA — HDD servo error, corrupted FTL
mapping entry, or a LUN-mapping mistake in virtualization. A checksum computed *over the record alone*
cannot detect it: the bytes are intact, only the location is wrong. XFS v5 designs against this explicitly,
embedding `uuid`, `owner`, `blkno` and `lsn` in every metadata block because "a write might be misdirected
to the wrong LUN and so be written to the 'correct block' of the wrong filesystem." btrfs calls it a "ghost
write" and embeds the logical block number for the same reason. NetApp's field study counts this class
separately as *identity discrepancies*.

**CONDITIONS.** Firmware bug, FTL corruption, servo error, or storage misconfiguration. Also reachable
mechanically: an S3 restore that concatenates segments in the wrong order (see 2.2) produces exactly this
signature — valid records at wrong offsets.

**FALSIFIABLE CLAIM + TEST.** *Claim: a valid record copied over a different valid record's offset is
detected.* Test: `dd` record at offset A over offset B, both individually CRC-valid; assert replay rejects.
The fix that makes this pass — folding the record's byte offset and a per-file UUID into the CRC input —
also closes 1.7 (zero-record) and 2.2 (segment reordering) at once, for a few bytes of header.

**SOURCE.** https://kernel.org/doc/Documentation/filesystems/xfs-self-describing-metadata.rst ·
https://btrfs.readthedocs.io/en/stable/btrfs-man5.html ·
https://www.usenix.org/legacy/events/fast08/tech/full_papers/bairavasundaram/bairavasundaram.pdf

**APPLICABILITY.** single-node now. **Highest-leverage item in this document** (one fix, three bugs).

---

#### 1.34 — FTL metadata corruption makes a third of the device unreachable, and reads *hang*

**WHAT GOES WRONG.** SSD#3 in the FAST'13 study returned only 69.5% of its records after **8** power faults
— 72.6 GB gone. The block-validity metadata was scrambled, marking ~1/3 of blocks bad. Critically, reads
beyond the retrievable region **hang and never return** until the device is power-cycled. On the BEAM a
`:file.pread/3` that never returns blocks a dirty-IO scheduler indefinitely; the supervisor sees a live
process, not a crashed one, so nothing restarts and nothing alarms.

**CONDITIONS.** A handful of power faults under concurrent write load. Not wear-related.

**FALSIFIABLE CLAIM + TEST.** *Claim: every read on the recovery path has a timeout, and a read that
exceeds it produces a named error rather than a hung process.* Test: use `dm-delay` with a multi-minute
delay (or a FUSE filesystem that never returns) under the log; start replay; assert the ledger reports
`{:error, :io_timeout}` within the configured bound and that the supervisor observes it. Assert with
`:erlang.system_info(:dirty_io_schedulers)` telemetry that no scheduler is permanently occupied.

**SOURCE.** https://www.usenix.org/system/files/conference/fast13/fast13-final80.pdf §5.5

**APPLICABILITY.** single-node now.

---

#### 1.35 — Power faults alone can brick a drive permanently

**WHAT GOES WRONG.** SSD#1 stopped enumerating on the bus entirely after **136** power faults; all data
lost. Current measurement showed the controller still drawing normal power — the failure is a lost mapping
table or a wedged firmware state machine, not a burned component. 136 hard resets is not a large number for
a machine that panics or loses power occasionally.

**CONDITIONS.** Repeated unexpected power loss over the life of a host.

**FALSIFIABLE CLAIM + TEST.** *Claim: the S3 backup, not the local file, is the durability boundary; the
system can be restored to the last backed-up byte offset with no manual step and no access to the original
device.* Test: on a clean machine with no local state, run restore-from-S3 and assert the recovered fact
set equals the set acknowledged up to the last backup. Measure and assert the RPO (bytes/seconds between
the last backup and "now") is bounded and reported.

**SOURCE.** https://www.usenix.org/system/files/conference/fast13/fast13-final80.pdf §5.6

**APPLICABILITY.** single-node now.

---

#### 1.36 — Consumer PLP protects data *at rest*, not data *in flight*

**WHAT GOES WRONG.** Client SSD hold-up capacitors provide on the order of **1 ms** — enough only to finish
an in-progress lower-page program so an interrupted upper-page program does not corrupt the already-written
lower page. Anything acknowledged to the host but still in DRAM/SRAM is lost. Micron: "Client SSDs protect
data at rest. Data center SSDs protect data at rest **and** data in flight… In both types of client SSDs,
the SSD controller SRAM is not protected." Datacenter drives use tantalum banks (Samsung 845DC: 1.4–2.3 mF,
20–40 ms hold-up) covering the DRAM write buffer, controller SRAM, and the FTL table save. So "the drive
has power loss protection" is not the same claim as "an unfsynced write survives power loss."

**CONDITIONS.** Any consumer NVMe/SATA drive with volatile write cache enabled — i.e. the default on a
laptop, a dev box, and many budget cloud instances.

**FALSIFIABLE CLAIM + TEST.** *Claim: the deployment's drive class is known and asserted at startup.*
Test: read the VWC bit from `nvme id-ctrl`; assert that if the drive is not a full-PLP datacenter part,
`fsync: false` is refused (or the durability claim is downgraded in the health endpoint). Intel PLI drives
expose a "Microseconds to Discharge Capacitors" SMART attribute — assert it is present and in spec.

**SOURCE.** https://assets.micron.com/adobe/assets/urn:aaid:aem:1f5ebe25-dc19-4e6f-89d2-31a2c6b69548/renditions/original/as/ssd-power-loss-protection-white-paper-lo.pdf ·
https://semiconductor.samsung.com/resources/others/Samsung_SSD_845DC_05_Power_loss_protection_PLP.pdf ·
https://www.intel.com/content/dam/www/public/us/en/documents/technology-briefs/ssd-power-loss-imminent-technology-brief.pdf

**APPLICABILITY.** single-node now.

---

#### 1.37 — Devices that accept the flush command and don't flush

**WHAT GOES WRONG.** The whole consistency stack assumes flush orders writes to media. btrfs calls this
"perhaps the most serious problem and impossible to mitigate by filesystem": writes from one generation
bleed into another while the filesystem believes generations are isolated, "leaving data on the device in
an inconsistent state without any hint what exactly got written." PostgreSQL documents it as a supported
failure mode: "this can be subverted by disk drives that falsely report a successful write to the kernel."
Empirically confirmed — the FAST'13 study's HDD#1 (a 5.4K consumer drive) exhibited unserializable writes,
indicating it ignored flush requests.

**CONDITIONS.** Consumer SATA/IDE drives, USB/FireWire bridges, some early SSDs (the PostgreSQL wiki names
Intel X25-E / X25-M G2 as unsafe by design, fixed only in the capacitor-equipped 320/710 series).

**FALSIFIABLE CLAIM + TEST.** *Claim: fsync latency is consistent with a real media flush.* Test: run
`pg_test_fsync`, or measure single-record-append+fsync latency; a device whose synchronous write latency is
a *fraction* of its read latency is caching, not flushing. Assert a floor (e.g. p50 > 100 µs on NVMe,
> 5 ms on rotational). A failed physical plug-pull test is conclusive; a passed one is not.

**SOURCE.** https://www.postgresql.org/docs/16/wal-internals.html ·
https://wiki.postgresql.org/wiki/Reliable_Writes · https://btrfs.readthedocs.io/en/stable/btrfs-man5.html

**APPLICABILITY.** single-node now.

---

#### 1.38 — NVMe atomicity is implicit, bounded by AWUPF/NAWUPF, and voided by crossing a boundary

**WHAT GOES WRONG.** NVMe has no atomic-write command. Atomicity is implicit and holds only if size and
alignment constraints are met. **AWUN** is the normal-operation atomic size; **AWUPF** is the size
guaranteed atomic across a power fail ("subsequent reads return either all old data or all new data").
Per-namespace: NAWUPF, and NABSPF for the boundary. Linux exposes
`atomic_write_unit_max = rounddown_pow_of_two(NAWUPF)` and `atomic_write_boundary = NABSPF`. **A write that
crosses an atomic boundary loses atomicity even if it is under the size limit.** Most consumer drives report
AWUPF of one logical block — 4 KiB at best, often 512 bytes.

**CONDITIONS.** Any record whose framed size exceeds AWUPF, or that straddles a NABSPF boundary. For a
variable-size transaction log this is essentially always.

**FALSIFIABLE CLAIM + TEST.** *Claim: the design does not assume any record write is atomic; the real
untorn-write size is `cat /sys/block/<dev>/queue/atomic_write_unit_max` and is 0 (unsupported) on most
drives.* Test: read `nvme id-ctrl`/`id-ns` for AWUPF/NAWUPF/NABSPF and the sysfs `atomic_*` files at
startup, log them, and assert no code path branches on "records are atomic". If any test relies on
atomicity, it must skip unless the value covers the record.

**SOURCE.** https://lwn.net/Articles/1009298/ · https://docs.kernel.org/filesystems/ext4/atomic_writes.html

**APPLICABILITY.** single-node now.

---

#### 1.39 — `RWF_ATOMIC` is the only sanctioned untorn-write path and it is very narrow

**WHAT GOES WRONG.** Since Linux 6.13, `pwritev2(..., RWF_ATOMIC)` gives untorn writes — but only with
**direct I/O**, only on extent-based regular files, only when device + block layer + filesystem all support
it, and initially only for a single filesystem block. Because ext4 cannot use a block size above page size,
on x86 (4 KiB pages) ext4 tops out at 4 KiB without `bigalloc`. **ext4 has no software or COW fallback** —
no hardware support means no atomicity, and an oversized `RWF_ATOMIC` write returns `EINVAL`. XFS can fall
back to copy-on-write. `statx()` with `STATX_WRITE_ATOMIC` reports the real numbers.

**CONDITIONS.** Any attempt to get torn-write-free record writes on Linux without a double-write buffer.

**FALSIFIABLE CLAIM + TEST.** *Claim: `statx(STATX_WRITE_ATOMIC)` on the log file returns
`stx_atomic_write_unit_max`; if it is 0 or `STATX_ATTR_WRITE_ATOMIC` is unset, no record write on this
system is atomic.* Test: call `statx` at open time from a NIF/port, log the value; attempt an `RWF_ATOMIC`
write of `unit_max + 1` bytes and assert `EINVAL`.

**SOURCE.** https://docs.kernel.org/filesystems/ext4/atomic_writes.html · https://lwn.net/Articles/1009298/

**APPLICABILITY.** single-node now.

---

#### 1.40 — Uncorrectable read errors are routine: 2–6 per 1,000 drive-days (Google fleet)

**WHAT GOES WRONG.** Schroeder et al., six years across ten SSD models: uncorrectable errors "affect
**2–6 out of 1,000 drive days**", and **20–63% of drives develop at least one** over their life. Final read
errors are roughly two orders of magnitude more frequent than any other non-transparent error and are
"almost exclusively due to bit corruptions beyond what the ECC can correct." Also: RBER does not predict
uncorrectable errors; SLC is not more reliable than MLC within typical lifetimes; SSDs have a *lower*
replacement rate than HDDs but a *higher* rate of uncorrectable errors. Practically: a mid-log `EIO` on read
is a normal event, not an exotic one — and it is a **different event from a CRC mismatch**, requiring a
different response.

**CONDITIONS.** Any production flash, any age.

**FALSIFIABLE CLAIM + TEST.** *Claim: replay distinguishes "read returned EIO" from "record failed CRC",
and neither is silently treated as end-of-log.* Test: use `dm-dust` (or `dm-flakey`) to inject a hard read
error at a known mid-log offset; assert replay reports an unreadable-region error naming the offset, does
**not** advance the checkpoint past it, and does not return a truncated success. Separately inject a CRC
corruption at the same offset and assert a *different* error is returned. **Build this test first** — it is
the highest-probability real-world event in this document.

**SOURCE.** https://www.usenix.org/system/files/conference/fast16/fast16-papers-schroeder.pdf §3.2, §5

**APPLICABILITY.** single-node now.

---

#### 1.41 — 38% of drive failures give no SMART warning, and vendor AFR understates field failure by up to 70%

**WHAT GOES WRONG.** Narayanan et al. (Microsoft, >500,000 SSDs, ~3 years): observed AFR for some models is
**as much as 70% higher** than the drive's specification. Four SMART symptoms matter (Data Errors,
Reallocated Sectors, Program/Erase Failures, SATA Downshift) and their presence raises AFR **3×–20×** — but
only **62% of failed devices showed any of them**, so **38% failed with a clean SMART record**. Measured
per-device UBER varied by three orders of magnitude across models of the same generation. 50% of failures
occurred more than four months after the predictive signature appeared.

**CONDITIONS.** Production fleet, any model. "SMART is clean" is not evidence of health.

**FALSIFIABLE CLAIM + TEST.** *Claim: the system is correct under an unannounced fail-stop of its storage
device.* Test: `echo 1 > /sys/block/<dev>/device/delete` (or `dm-flakey` in drop-writes mode) mid-write;
assert the ledger crashes loudly rather than continuing to acknowledge writes, and that restart-from-S3
reconstructs the log to the last backed-up offset with no manual step.

**SOURCE.** https://pages.cs.wisc.edu/~remzi/Classes/739/Fall2016/Papers/a7-narayanan.pdf §3.3, §4

**APPLICABILITY.** single-node now.

---

#### 1.42 — ext4 delayed allocation: the zero-length-file problem, and `auto_da_alloc` is only a heuristic

**WHAT GOES WRONG.** With delayed allocation, blocks are not allocated until writeback (up to ~a minute), so
a `rename()` over an existing file can commit in the journal while the new file still has zero data blocks.
Post-crash result: a **zero-length file**, with both old and new content gone. ext3's `data=ordered`
accidentally bounded the window to ~5 seconds; ext4 widened it to ~60, which produced the 2009 data-loss
wave. The mitigation shipped in 2.6.30, `auto_da_alloc` (default on), detects replace-via-rename and
replace-via-`O_TRUNC` and forces allocation before the rename commits — Ts'o's own framing is that it gives
"roughly the same level of guarantees as ext3", i.e. a heuristic that matches an idiom, not a guarantee.
ALICE later measured that this heuristic fixes only three of the sixty vulnerabilities it found.

**CONDITIONS.** `open(tmp)/write/close/rename(tmp, final)` without `fsync(tmp)` — exactly the natural way to
publish a checkpoint sidecar. Reproduce reliably with `noauto_da_alloc`.

**FALSIFIABLE CLAIM + TEST.** *Claim: a crash during checkpoint publish never yields a zero-length
checkpoint.* Test: loop {write sidecar via temp+rename with no fsync; crash via `echo c >
/proc/sysrq-trigger`}; count zero-length sidecars — expect nonzero. Add `fsync(fd)` before rename and
`fsync(dirfd)` after; assert the count goes to zero. Run both arms with `noauto_da_alloc` to remove the
heuristic's cover.

**SOURCE.** https://thunk.org/tytso/blog/2009/03/12/delayed-allocation-and-the-zero-length-file-problem/ ·
https://lwn.net/Articles/322823/ · https://docs.kernel.org/admin-guide/ext4.html (`auto_da_alloc`) ·
https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf §4.4.2

**APPLICABILITY.** single-node now — this hits the checkpoint sidecar directly.

---

#### 1.43 — XFS protects its own metadata thoroughly and your data not at all

**WHAT GOES WRONG.** XFS v5 (2012+) puts a magic number, filesystem UUID, owner, on-disk block number, log
sequence number and CRC32c in nearly every metadata block header, verified on read and recomputed on write —
which detects torn metadata writes, misdirected writes, lost writes (via `blkno`) and stale log replay (via
`lsn`). **None of it covers file data.** A corrupted data block is returned to the application silently.
V4 (no CRCs) is deprecated: kernel support defaulted to `no` in Sept 2025, removal scheduled Sept 2030.
Note also that `norecovery` mounts skip log replay and must be read-only.

**CONDITIONS.** XFS under the log. The lesson generalizes: *the filesystem's integrity guarantees stop at
its own metadata; the application's CRC is the only thing standing between bitrot and a wrong answer.*

**FALSIFIABLE CLAIM + TEST.** *Claim: XFS returns silently-wrong file data when a data block is corrupted,
so the application must CRC-verify on every read, not only during recovery.* Test: `xfs_info <mnt> | grep
crc=` to confirm v5; unmount; `dd` a bit flip into a data block; remount; read through the **normal** read
path (not replay) and assert the application detects it. Assert v5 at startup.

**SOURCE.** https://kernel.org/doc/Documentation/filesystems/xfs-self-describing-metadata.rst ·
https://www.kernel.org/doc/Documentation/admin-guide/xfs.rst

**APPLICABILITY.** single-node now.

---

#### 1.44 — btrfs `nodatacow` silently disables checksums *and* re-enables torn in-place writes

**WHAT GOES WRONG.** btrfs checksums data and metadata by default. But `nodatacow` **implies `nodatasum`**
and disables compression; every file created under it inherits the `NOCOW` attribute. The man page states
the trade plainly: updating in place improves performance for frequent-overwrite workloads "at the cost of
**potential partial writes**, in case the write is interrupted (system crash, device failure)" — and with
`nodatasum` those partial writes are undetectable. Two extra footguns: the option cannot be set
per-subvolume (only the first mounted subvolume's options apply), and since 6.14 direct writes on
checksummed inodes silently fall back to buffered.

**CONDITIONS.** Someone applies the widespread "put your database on nodatacow" advice to the log directory.

**FALSIFIABLE CLAIM + TEST.** *Claim: under default btrfs a corrupted data block yields `EIO`; under
`nodatacow` it yields silently wrong bytes.* Test: corrupt a data block on the unmounted device and read it
back under each configuration; assert the difference. Startup assertion: `lsattr` shows no `C` flag on the
log directory, and `/proc/self/mountinfo` shows no `nodatacow`/`nodatasum`.

**SOURCE.** https://btrfs.readthedocs.io/en/stable/btrfs-man5.html

**APPLICABILITY.** single-node now.

---

#### 1.45 — ZFS `sync=disabled` makes `fsync()` a no-op, and a suspended pool blocks forever

**WHAT GOES WRONG.** `sync=standard` (default) is POSIX: fsync/O_DSYNC reach stable storage and **all
devices are flushed** so nothing is left in controller caches. `sync=disabled` "disables synchronous
requests… it is very dangerous as ZFS would be ignoring the synchronous transaction demands of applications
such as databases or NFS." `logbias=throughput` bypasses configured log devices. Separately, ZFS's integrity
model is the design worth copying: the 256-bit checksum lives in the **parent** block pointer, not in the
block — making the pool a Merkle tree, so a block silently zeroed by firmware cannot self-validate (which is
precisely the failure in 1.7). Operationally: on OpenZFS `fsync()` historically could not fail; a suspended
pool blocks the caller indefinitely rather than returning an error.

**CONDITIONS.** Tuning guides recommending `sync=disabled`; a pool suspended by device failure.

**FALSIFIABLE CLAIM + TEST.** *Claim: `zfs get sync` returns `standard` and the writer has a timeout path
for an fsync that never returns.* Test: assert the property at startup; verify by setting `sync=disabled`,
observing fsync latency collapse, and crashing to demonstrate loss. Separately, suspend the pool
(`zpool offline` all vdevs) mid-write and assert the ledger reports a timeout rather than hanging.

**SOURCE.** https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html ·
https://papers.freebsd.org/2024/bsdcan/norris_openzfs-fsync-zil/

**APPLICABILITY.** single-node now.

---

#### 1.46 — overlayfs: copy-up gives a deliberately minimal guarantee, and `volatile` removes it entirely

**WHAT GOES WRONG.** On first modification of a lower-layer file, overlayfs copies it up; without an
explicit fsync "the upper file could end up with **no data at all (i.e. zeros)**" after a crash — so
overlayfs fsyncs the upper file before the final rename to make copy-up atomic. But the docs are explicit
about how narrow that is: it "only guarantees that if a copy up is observed after a crash, the observed data
is not zeroes or intermediate values from the copy up staging area." By default (`fsync=auto`) there is
**no** explicit fsync on copied-up directories or on metadata-only copy-up. `fsync=volatile` (mount option
`volatile`) "omits all forms of sync calls to the upper filesystem" — "Volatile mounts are not guaranteed to
survive a crash", and once a writeback error occurs, every subsequent sync call returns an error permanently
and the filesystem never recovers.

**CONDITIONS.** The log living in a container's writable layer rather than a bind-mounted volume. Some
build/CI runtimes use `volatile` for speed.

**FALSIFIABLE CLAIM + TEST.** *Claim: the runtime refuses to place the log on an `overlay` filesystem.*
Test: read the log's filesystem type from `/proc/self/mountinfo`; assert it is not `overlay`. Verify the
assertion fires by starting the process with the log inside a container's writable layer.

**SOURCE.** https://kernel.org/doc/html/latest/filesystems/overlayfs.html ("Durability and copy up",
"Volatile mount")

**APPLICABILITY.** single-node now.

---

#### 1.47 — Cloud block-storage snapshots are crash-consistent, not application-consistent

**WHAT GOES WRONG.** EBS and GCE PD are network block devices with no user-visible volatile drive cache, and
fsync is honoured (GCP: "Checksums are calculated for all Persistent Disk operations"). The weak point is
**backups**. AWS states its EBS snapshots are crash-consistent: "snapshots capture only data that has been
written to your EBS volume at the time the snapshot command is issued. This might exclude any data that has
been cached by applications or the operating system." GCP requires `guest-flush` pre/post scripts for
application consistency (unsupported on Hyperdisk). A snapshot taken while the process has dirty page cache
therefore contains a log tail that is a *prefix of, but not equal to*, what was acknowledged.

**CONDITIONS.** Snapshot-based backup taken without an fsync + `fsfreeze`. Directly analogous for the S3
byte-range path: **segments must be cut at fsynced offsets**, or the backup encodes a state the process
never durably had.

**FALSIFIABLE CLAIM + TEST.** *Claim: every S3 segment boundary is at a byte offset that was fsynced before
the segment was uploaded.* Test: instrument the backup path to record (offset, was_fsynced) pairs; assert
the invariant. Crash test: kill the machine mid-backup, restore from S3 only, assert every acknowledged fact
up to the last completed segment is present and no partial record is included.

**SOURCE.** https://docs.aws.amazon.com/prescriptive-guidance/latest/backup-recovery/new-ebs-volume-backups.html ·
https://docs.cloud.google.com/compute/docs/disks/creating-linux-application-consistent-pd-snapshots

**APPLICABILITY.** single-node now.

---

#### 1.48 — Unpowered flash retention is specified in months, not years

**WHAT GOES WRONG.** Charge leaks from floating gates with no power applied, and the qualification floor is
set *at end of rated endurance*. JESD218 Table 1: **Client — 1 year at 30 °C power-off; Enterprise — 3
months at 40 °C power-off**. Retention is temperature-accelerated with 1.1 eV activation energy, so a warm
shelf is dramatically worse. A shelved drive or a cold spare holding "the backup" is not an archive.

**CONDITIONS.** A drive written near its TBW rating, then powered off and stored — a cold spare, a pulled
disk, a "we kept the old server" recovery plan.

**FALSIFIABLE CLAIM + TEST.** *Claim: no unpowered local disk is treated as a durable archive; the S3 copy
is the archive.* Test: a documentation/assertion claim — verify drive class and `nvme smart-log`
`percentage_used`, and assert the backup-verification job reads the S3 copy end-to-end (not just checks it
exists) on a schedule shorter than the class retention window.

**SOURCE.** https://www.jedec.org/sites/default/files/docs/JESD218B.pdf §5.2, Table 1

**APPLICABILITY.** single-node now (archive/backup story).

---

#### 1.49 — The CPU can compute the CRC wrong: silent corrupt execution errors

**WHAT GOES WRONG.** Google and Meta independently documented "mercurial cores" / Corrupt Execution Errors:
individual cores that produce wrong results for specific instructions under specific microarchitectural
conditions, with **no machine check and no log entry**. Meta's reduced example: on Core 59,
`INT(1.153) = 0` while `INT(1.152) = 142`. Google reports "on the order of a few mercurial cores per several
thousand machines," that they "typically afflict specific cores on multi-core CPUs, rather than the entire
chip," that they "can manifest long after initial installation," and that a *correct* library change which
merely shifted instruction mix caused a production pipeline to start returning wrong answers. Meta's debug
reduced 146,000 lines to 60 lines of assembly over multiple years. Consequence here: a CRC computed on a
faulty core is durably stored *wrong*, so replay rejects a record that was never corrupted on disk — and the
operator spends weeks blaming the disk.

**CONDITIONS.** Any modern datacenter CPU. Low rate, not fail-stop, not reported by any hardware channel.

**FALSIFIABLE CLAIM + TEST.** *Claim: a CRC mismatch at recovery can be attributed to storage rather than
compute.* Test: verify-after-compute on a sampled fraction of writes — recompute the CRC with an independent
implementation (`:erlang.crc32/1` vs a hardware CRC32C NIF) and compare; assert the mismatch path exists by
injecting a deliberately wrong second implementation. Record which scheduler/core computed a failing CRC so
a repeat offender is visible in telemetry.

**SOURCE.** https://sigops.org/s/conferences/hotos/2021/papers/hotos21-s01-hochschild.pdf ·
https://arxiv.org/abs/2102.11245

**APPLICABILITY.** single-node now.

---

### 2. Append-only log / WAL / LSM specific pitfalls

#### 2.1 — S3 has no cross-key atomicity, so a multi-segment backup is never a snapshot

**WHAT GOES WRONG.** S3 gives strong read-after-write consistency **per key**, and AWS states the limit
explicitly: *"Updates are key-based. There is no way to make atomic updates across keys."* A backup made
of N byte-range segment objects therefore has no moment at which the set is consistent. A restore that
lists the prefix mid-upload gets segments 1..k-1 and k+1 (because uploads completed out of order),
concatenates them, and produces a log with a **hole** — which, given "stop at first bad CRC", silently
becomes a short but internally valid database. AWS also notes there is no object locking for concurrent
writers: *"If two PUT requests are simultaneously made to the same key, the request with the latest
timestamp wins"* — so two backup runs can interleave segments from different log generations under the
same keys.

**CONDITIONS.** Backup interrupted mid-run; two backup processes (a cron overlap, a redeployed node);
a restore run against a live backup prefix.

**FALSIFIABLE CLAIM + TEST.** *Claim: a restore either produces the complete log up to some committed
point or fails loudly; it never produces a log with a gap.* Test: against MinIO/LocalStack, upload
segments [0,1,2,4] (omit 3), run restore, assert `{:error, {:missing_segment, 3}}` — not a successful
truncated restore. Implementation shape the test forces: a manifest object written **last** naming the
exact segment keys, byte ranges and a whole-log digest; restore reads the manifest first and verifies
contiguity of ranges and the digest of the concatenation.

**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel

**APPLICABILITY.** single-node now.

---

#### 2.2 — Segment keys sorted as strings do not concatenate in numeric order

**WHAT GOES WRONG.** "Restored by sorting and concatenating" is a lexicographic sort if the keys are
strings. `seg-10` sorts before `seg-2`; `seg-9` sorts after `seg-10`. The restored file is then a
permutation of the log. Because every individual record still has a valid CRC, replay does **not** stop
— it happily applies transactions in the wrong order, and for an immutable fact log where transaction
identity carries ordering, that silently rewrites history. S3's `ListObjectsV2` returns keys in UTF-8
binary order, so the bug is invisible until the segment count crosses 10, then 100, then 1000.

**CONDITIONS.** More than 9 segments. Guaranteed to appear eventually and to have been "working fine"
until then.

**FALSIFIABLE CLAIM + TEST.** *Claim: restore orders segments by their numeric index and by their byte
offset, and verifies that segment k's start offset equals segment k−1's end offset.* Test: create 12
segments, restore, assert byte-for-byte equality with the original log. Deliberately name them
un-zero-padded (`seg-1 … seg-12`) so a lexicographic implementation fails. Second test: assert that
replaying a restored log yields transaction ids in strictly increasing order.

Worse, S3-compatible implementations disagree about what the order even is: NooBaa returns UTF-16
code-unit order rather than UTF-8 binary order (issue #8218), and AWS **directory buckets do not return
lexicographical order at all**. Since the backup target is "S3-compatible," listing order is not a
contract you have.

**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html (keys returned in
UTF-8 binary order) · https://docs.aws.amazon.com/AmazonS3/latest/userguide/ListingKeysUsingAPIs.html ·
https://github.com/noobaa/noobaa-core/issues/8218 ·
https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel

**APPLICABILITY.** single-node now.

---

#### 2.3 — A checkpoint that records an offset ahead of what was fsynced destroys the log's authority

**WHAT GOES WRONG.** The checkpoint sidecar holds facts plus a byte offset meaning "the log up to here
is already folded into me." If the checkpoint is made durable **before** the log bytes it summarizes
are durable, a crash yields a checkpoint pointing past the end of a shorter log. Recovery then either
(a) seeks past EOF and treats the log as empty from there — losing every transaction between the real
EOF and the recorded offset, which the checkpoint also does not contain if it was built from the page
cache; or (b) reads garbage. The ordering constraint is absolute and is the WAL rule inverted:
**the log must be durable before the checkpoint that summarizes it, and the checkpoint must be durable
before any log truncation.** With `fsync` off by default there is no ordering primitive at all — the
page cache is free to write the checkpoint sidecar's blocks before the log's.

**CONDITIONS.** Any crash between checkpoint write and log fsync. Guaranteed reachable with fsync off.

**PRECEDENT.** etcd shipped this exact bug in v3.5.0 and published a postmortem. etcd stores a
"consistent index" (CI) in the DB naming the last WAL entry the DB reflects; updating DB state and CI
must be atomic, because *"A partial fail would mean that database and WAL would no longer match, so
some entries would be either skipped (if only CI is updated) or executed twice (if only changes are
applied)."* PR #12855 made the CI a shared in-memory value updated *before* the apply completed, and a
periodic commit hook could persist it in between; a crash in that window made recovery **skip** the
un-applied entry. Shipped 2021-06-16, reported 2021-12-01, confirmed 2022-03-25, fixed 2022-04-24. The
sentence that matters most here: *"For single member cluster it is totally undetectable. There is no
mechanism or tool for verifying that state database matches WAL."*

**FALSIFIABLE CLAIM + TEST.** *Claim: for every crash point, `checkpoint.offset ≤ durable_log_length`,
and the fact set implied by (checkpoint + log-from-checkpoint.offset) equals a from-scratch full replay.*
Test: after every checkpoint, re-open from the checkpoint alone, replay the log from `checkpoint.offset`,
and assert equality with a full replay. Run under randomized `SIGKILL` during checkpoint writing (100+
trials). Use `dm-log-writes` to replay the block stream to every flush boundary and assert the inequality
at each. Also ship this as a **`verify` command** — etcd's postmortem says the absence of exactly this
tool is why a single node could not detect the corruption at all.

**SOURCE.** https://github.com/etcd-io/etcd/blob/main/Documentation/postmortems/v3.5-data-inconsistency.md ·
https://www.sqlite.org/atomiccommit.html §6.2 (journal page-count written last — publish a pointer only
after its target is durable) · https://github.com/facebook/rocksdb/wiki/WAL-Recovery-Modes

**APPLICABILITY.** single-node now. **Highest-leverage item in this document.**

---

#### 2.4 — A corrupted length prefix as a denial-of-service: Kafka CVE-2022-34917

**WHAT GOES WRONG.** The Kafka broker read a request's 32-bit size prefix off the wire and allocated a
buffer of that size **before authentication or any sanity check**. A client sending plaintext to an SSL
port had its first bytes read as a length, making the broker allocate hundreds of MB per connection,
repeatedly, until `OutOfMemoryException`. Affected 2.8.0–2.8.1, 3.0.0–3.0.1, 3.1.0–3.1.1, 3.2.0–3.2.1.
Kafka shipped the mirror-image client-side fix as KIP-498 (`max.response.size`) because a garbage broker
response OOM'd clients the same way. Locally, a bit flip in the size field is the attacker.

**CONDITIONS.** Any decode path that allocates from a declared length before validating it.

**FALSIFIABLE CLAIM + TEST.** *Claim: a record whose declared size exceeds the remaining bytes in the file
never causes an allocation proportional to the declared size.* Test: append one good record, then 8 bytes
`<<0xFFFFFFFF::32, 0::32>>` and nothing else. Assert replay returns `{:error, :truncated}` and that peak
memory (`:erlang.memory(:binary)` before/after) stays under 2× `max_record_bytes`. Assert `:file.pread` is
never called with the raw declared length.

**SOURCE.** https://kafka.apache.org/community/cve-list/ ·
https://cwiki.apache.org/confluence/display/KAFKA/KIP-498:+Add+client-side+configuration+for+maximum+response+size+to+protect+against+OOM

**APPLICABILITY.** single-node now.

---

#### 2.5 — The bound check on one decode path does not protect the other decode paths (Thrift THRIFT-4362)

**WHAT GOES WRONG.** Thrift's `TBinaryProtocol.readString` reads a size and calls `readStringBody(size)`,
which allocates `new byte[size]` regardless of bytes remaining. THRIFT-1643 added a length limit. THRIFT-4362
is the follow-up: `readMessageBegin()` calls `readStringBody(size)` **bypassing `checkStringReadLength(size)`
entirely**, so the limit added in 1643 does not apply on that path. The reporter: "We encountered this issue
in production several times." The bug class is not "no bound" but "one path checks, another doesn't."

**CONDITIONS.** More than one entry point into the same decoder. This system will have at least three:
full-file replay, checkpoint-offset seek-and-read, and S3 segment restore.

**FALSIFIABLE CLAIM + TEST.** *Claim: exactly one function turns a declared size into an allocation, and
every caller reaches the bound check.* Test: property test — generate random 8-byte headers with arbitrary
sizes and feed each through **every** public decode entry point; assert all reject identically. Plus a
structural test asserting only one call site constructs a read of `size` bytes.

**SOURCE.** https://issues.apache.org/jira/browse/THRIFT-1643 ·
https://issues.apache.org/jira/browse/THRIFT-4362

**APPLICABILITY.** single-node now.

---

#### 2.6 — Erlang `{packet, 4}` without `{packet_size, N}` waits for 2 GB

**WHAT GOES WRONG.** `gen_tcp` with `{packet, 4}` reads a 4-byte big-endian length and buffers that many
bytes. Without `{packet_size, N}` a bogus header makes the driver allocate/wait for up to 2 GB. The
canonical erlang-questions example: send `Hello\n` and the driver reads `0x48656c6c` = 1,214,606,444 as the
frame size and hangs. The `inet` docs: `packet_size` "sets the maximum allowed length of the packet body. If
the packet header indicates that the length of the packet is longer than the maximum allowed length, the
packet is considered invalid." This is the same discipline the file framing needs, in the same runtime.

**CONDITIONS.** Any `{packet, 1|2|4}` socket without `packet_size` — a future replication or admin protocol.

**FALSIFIABLE CLAIM + TEST.** *Claim: every `:inet.setopts`/`gen_tcp` call setting `packet` to 1/2/4 also
sets `packet_size`.* Test: static assertion over the source tree, plus a socket test sending
`<<0xFFFFFFFF::32>>` and asserting `{:error, :emsgsize}` within 100 ms rather than a hang.

**SOURCE.** https://www.erlang.org/doc/apps/kernel/inet.html ·
https://erlang.org/pipermail/erlang-questions/2020-April/099417.html

**APPLICABILITY.** single-node now (the framing discipline); the socket instance only if distributed.

---

#### 2.7 — etcd #14098: a lost-unsynced-write tail decoded as a 13,563 TB record, permanently unbootable

**WHAT GOES WRONG.** Kyle Kingsbury ran etcd 3.5.3 on LazyFS, killed it, and dropped un-fsynced writes.
Every restart then died with `wal: max entry size limit exceeded, recBytes: 13563782407139376,
fileSize(64000000) - offset(196120) - padBytes(0) = entryLimit(63803880)` — the garbage tail parsed as a
length prefix. Two second-order lessons. (a) etcd survived at all only because its entry-size limit is
derived from **remaining file size**, not a constant. (b) The initial reproduction was distorted because
LazyFS filled truncated regions with `0x30` (ASCII `'0'`) instead of `0x00`, and etcd's reader scans for
`0x00` to find end-of-file — **the recovery reader's "end of data" heuristic was a byte-value assumption,
and it broke the moment the fill byte changed**. After fixing the fill to `0x00`, a *different* crash
appeared: `panic: tocommit(56444) is out of range [lastIndex(2894)]`. Companion issue #14102 shows bit flips
producing SIGSEGV, SIGBUS, `proto: illegal tag 0`, and `panic: cannot use none as id`.

**CONDITIONS.** Crash with an un-fsynced tail, plus whatever the filesystem puts in the gap. This is exactly
the `fsync: false` default.

**FALSIFIABLE CLAIM + TEST.** *Claim: declared size is validated against `file_size - offset - 8` before
allocation, and replay behaves identically whether the post-crash tail is 0x00-filled, 0xFF-filled,
0x30-filled, or random.* Test: parameterize a fuzz harness over fill bytes `[0x00, 0x30, 0xFF, :random]`;
truncate the log at random offsets mid-record; pad with the fill byte to the original length; replay.
Assert the same recovered fact set every time, no crash, no unbounded allocation.

**SOURCE.** https://github.com/etcd-io/etcd/issues/14098 · https://github.com/etcd-io/etcd/issues/14102

**APPLICABILITY.** single-node now.

---

#### 2.8 — RocksDB #6351: recovery skipped a corrupt record and applied later ones, producing a hole

**WHAT GOES WRONG.** The most on-point published bug for this design. With two unflushed WALs, a maintainer
manually corrupted the second entry of the first WAL, reopened under `kPointInTimeRecovery`, and got: the DB
contains nothing for `key1` but recovers `key2`, written *after* `key1`. His verdict: **"Recovery permitted
a hole, which is not a consistent point in time."** Root cause: WAL recycling *requires* a reader that
tolerates a corrupt record at the boundary between new data and stale recycled data, and that tolerance
leaks into tolerating corruption anywhere. PR #6351 disabled recycling under point-in-time and
absolute-consistency modes; PR #7252 tried to revert it and instead established that the incompatibility is
structural.

**CONDITIONS.** Any recovery mode that resynchronizes past a bad record; any reuse of file space leaving
valid-looking older framing behind.

**FALSIFIABLE CLAIM + TEST.** *Claim: replay never applies a record positionally after a record it failed to
read.* Test: write facts f1..f100, one record each. Flip one byte in record 40's payload so the CRC fails but
the length prefix stays intact and record 41 starts exactly where it should. Replay. Assert the recovered
set is exactly f1..f39 — specifically **assert f41 is absent**, not merely that f40 is. Then assert the store
either refuses new appends or truncates to record 40's offset, so a later append cannot make the hole
permanent. (This is the test that proves you did not accidentally implement resync — see 2.9 for the
alternative design and why LevelDB chose it.)

**SOURCE.** https://github.com/facebook/rocksdb/pull/6351 · https://github.com/facebook/rocksdb/pull/7252

**APPLICABILITY.** single-node now.

---

#### 2.9 — LevelDB deliberately resyncs to the next 32 KiB block — the opposite policy, and its price

**WHAT GOES WRONG (as a design contrast).** LevelDB frames records inside 32 KiB blocks with
`FULL/FIRST/MIDDLE/LAST` fragment types precisely so that "if there is a corruption, skip to the next block
boundary and scan." The documented benefit — "we do not get confused when part of the contents of one log
file are embedded as a record inside another log file" — is exactly the recycled-file hazard. The price is
2.8: a resynchronizing reader can produce holes. "Stop at first bad CRC" is the *safer* of the two policies;
the risk is that a well-meaning future change adds resync for availability.

**CONDITIONS.** Design-time.

**FALSIFIABLE CLAIM + TEST.** *Claim: the reader has no resync path at all.* Test: property test — for every
single-byte mutation at every offset in a 50-record log, replay must yield a **prefix** of the original fact
sequence, never a set with a gap. Plus a mutation-testing or structural assertion that no code path advances
the read offset after a CRC failure and continues.

**SOURCE.** https://github.com/google/leveldb/blob/main/doc/log_format.md

**APPLICABILITY.** single-node now.

---

#### 2.10 — Redis `aof-load-truncated`: three different behaviors people conflate, and a repair tool that can eat 99% of the data

**WHAT GOES WRONG.** (a) *Truncated tail:* Redis logs `Truncating the AOF at offset 439` and loads anyway;
the default is `yes` "in order to guarantee availability after a restart." (b) *Corrupt mid-file:* Redis
aborts with `Bad file format reading the append only file`. (c) *`redis-check-aof --fix`:* the docs warn
that "all the AOF portion from the invalid part to the end of the file may be discarded, **leading to a
massive amount of data loss if the corruption happened to be in the initial part of the file**."

**CONDITIONS.** (a) crash during append; (b) bitrot, torn write, or a disk-full event leaving garbage rather
than a short file.

**FALSIFIABLE CLAIM + TEST.** *Claim: the repair tool reports how many facts it will discard before
discarding them, and refuses without an explicit confirmation when the count exceeds a threshold.*
Test: corrupt record 3 of 10,000; run repair in dry-run mode; assert it prints `would discard 9,997 facts
(99.97%)` and exits non-zero without `--force`.

**SOURCE.** https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/

**APPLICABILITY.** single-node now.

---

#### 2.11 — Redis #5177: truncation tolerance did not help, because the tail was garbage, not short

**WHAT GOES WRONG.** A user lost power; Redis refused to start with `Bad file format` despite
`aof-load-truncated yes`. `redis-check-aof` reported `Expected prefix '*', got: '\0'` — 595 bytes of invalid
data at offset 18,479,826. The RDB preamble validated; the AOF tail after it did not. **Truncation tolerance
covers "the file ends early," not "the file ends at the right length with the wrong bytes"** — and the
latter is what an ext4/power-loss interaction actually produces, because the inode size can be updated before
the block data lands.

**CONDITIONS.** Power loss on any filesystem that extends the file before the data is durable.

**FALSIFIABLE CLAIM + TEST.** *Claim: replay treats "N bytes of zeros/garbage after the last good record"
identically to "file ends after the last good record."* Test: write 100 records, then extend the file by 4096
bytes of non-framing content. Replay must recover exactly 100 and classify the tail as torn, not raise an
error requiring manual intervention.

**SOURCE.** https://github.com/redis/redis/issues/5177

**APPLICABILITY.** single-node now.

---

#### 2.12 — Cassandra CASSANDRA-13987: a record whose validity depends on a marker written *after* it

**WHAT GOES WRONG.** Cassandra's commitlog writes a sync marker before and after each synced section. Data
written after the last complete marker is physically present in the mmap'd file and readable, but replay
**abandons it** because the trailing marker was never written. The JIRA is blunt: "The unfortunate thing is
that the data is still available, in the mmap file, but we can't replay it due to incomplete chained
markers." With the default `commitlog_sync_period_in_ms = 10000` that is up to ten seconds of acknowledged
writes silently dropped **on a process crash, not a power loss**. CASSANDRA-14108 adds that when the marker
interval does not evenly divide the sync interval (9 s vs 10 s), the flush happens 8 seconds late.
CASSANDRA-15228 later concluded that under the default config "the sync markers have no purpose, only
serving to reduce persistence by preventing replay of any mutations serialised between syncs" — a durability
feature that was, in practice, a data-loss feature.

**CONDITIONS.** Any format where a record's validity depends on bytes written after it: a trailing index, a
"segment complete" footer, a chained marker.

**FALSIFIABLE CLAIM + TEST.** *Claim: a record is self-contained — `<<size, crc, payload>>` is verifiable
reading zero bytes past `offset + 8 + size`.* Test: write 10 records; truncate to exactly the end of record
7; assert 7 recovered. Truncate to end-of-record-7 minus one byte; assert 6 recovered. **No third byte
anywhere in the file may change either answer.** Cheap, and it is the test that catches you if a footer is
ever added.

**SOURCE.** https://issues.apache.org/jira/browse/CASSANDRA-13987 ·
https://issues.apache.org/jira/browse/CASSANDRA-14108 ·
https://issues.apache.org/jira/browse/CASSANDRA-15228

**APPLICABILITY.** single-node now.

---

#### 2.13 — Cassandra CASSANDRA-13282: off-by-one at the segment boundary when 1–3 bytes remain

**WHAT GOES WRONG.** `CommitLogReplayer#replaySyncSection` reads a 4-byte `serializedSize`; zero means "end
of data" (segments are zero-filled at creation). But if a mutation happens to end with 1, 2 or 3 bytes
remaining in the segment, the `isEOF` loop check passes, the subsequent 4-byte read fails, and replay aborts
the whole segment — potentially aborting startup. A pure arithmetic bug, triggered by data size, therefore
rare and non-deterministic in production and trivially reachable in a test.

**CONDITIONS.** Record sizes that leave 1–3 bytes of slack at a segment tail. Applies to S3 byte-range
segment boundaries too.

**FALSIFIABLE CLAIM + TEST.** *Claim: replay is correct for records ending at exactly `segment_size − k` for
all k in 0..(header_size + 1).* Test: a parameterized table test over `k = 0..16`. Construct a log whose last
record ends at `file_size − k`, pad the remainder, assert the recovery count. Seventeen rows, catches the
whole class.

**SOURCE.** https://issues.apache.org/jira/browse/CASSANDRA-13282

**APPLICABILITY.** single-node now.

---

#### 2.14 — Cassandra CASSANDRA-16842: two-phase metadata write loses a whole segment of valid data

**WHAT GOES WRONG.** Sync markers are written in two phases — zeros for the next-position and CRC fields,
then the real values later. "If the process shuts down in a disorderly fashion, it is entirely possible for a
valid next marker position to be written to our memory mapped file but not the final CRC value. Later, when
we attempt to replay the segment, we will fail without recovering any of the perfectly valid mutations it
contains." The fix was an *option* to skip the CRC check when a non-zero position is present.

**CONDITIONS.** Any two-phase write where the phases can become independently durable — including
"write the checkpoint body, then patch the offset field in place."

**FALSIFIABLE CLAIM + TEST.** *Claim: nothing in the on-disk format is written in two phases; no byte
previously written is ever rewritten.* Test: wrap the writer in a module that records `{offset, length}` for
every write and fails on any overlap with a prior write. Assert that a single fact append issues exactly one
`:file.write` (or one `writev`).

**SOURCE.** https://issues.apache.org/jira/browse/CASSANDRA-16842

**APPLICABILITY.** single-node now — the checkpoint sidecar is the risk site.

---

#### 2.15 — Cassandra CASSANDRA-20664: a skip that doesn't advance is an infinite loop (and `size = 0` is the input)

**WHAT GOES WRONG.** With `-Dcassandra.commitlog.ignorereplayerrors=true`, corrupt sync blocks made
`CommitLogReplayer` log `Ignoring commit log replay error` forever without advancing the offset — re-reading
the same position, writing 50 MB of logs in 2 seconds, and never completing startup. Reported on 4.1.8, fixed
in 5.0. Note the specific input that produces this in a `<<size::32, crc::32, payload>>` reader: **a declared
size of 0 with a CRC that matches the empty payload** makes a naive `offset = offset + 8 + size` loop spin
forever — and per item 1.7, eight zero bytes are exactly that record.

**CONDITIONS.** Any error-tolerant replay path where the skip distance can be zero.

**FALSIFIABLE CLAIM + TEST.** *Claim: every iteration of the replay loop advances the offset by at least one
byte, and the loop is hard-bounded by `file_size` iterations.* Test: craft a record with declared size 0;
assert replay terminates within `file_size` iterations and within a wall-clock bound.

**SOURCE.** https://issues.apache.org/jira/browse/CASSANDRA-20664 ·
https://github.com/apache/cassandra/pull/4284

**APPLICABILITY.** single-node now.

---

#### 2.16 — Kafka's log docs state the reason CRC alone is insufficient: a crash can *add* nonsense

**WHAT GOES WRONG.** From Kafka's implementation documentation: *"two kinds of corruption must be handled:
truncation in which an unwritten block is lost due to a crash, and corruption in which a nonsense block is
ADDED to the file. The reason for this is that in general the OS makes no guarantee of the write order
between the file inode and the actual block data so in addition to losing written data the file can gain
nonsense data if the inode is updated with a new size but a crash occurs before the block containing that
data is written."* Validity therefore requires **both** `offset + header + size <= file_length` **and** a CRC
match. Kafka then **truncates the file** to the last valid offset before accepting appends — the step people
forget, and without which the next append lands after the garbage and cements it into the log.

**CONDITIONS.** Any crash on a filesystem with independent metadata/data ordering — i.e. everything except
`data=journal`.

**FALSIFIABLE CLAIM + TEST.** *Claim: replay validates the size bound before reading the payload, and
physically truncates the file to the last valid offset before the first new append.* Test: `ftruncate` the
log to `size + 4096` (creating a sparse zero region — the "inode updated, data missing" state), replay,
assert recovery to the last good record **and** assert `File.stat` shows the file was truncated back so the
next append lands at the right offset.

**SOURCE.** https://kafka.apache.org/43/implementation/log/

**APPLICABILITY.** single-node now.

---

#### 2.17 — KAFKA-3955: the repair code existed but was unreachable from the real startup path

**WHAT GOES WRONG.** A segment with non-monotonic offsets made `LogSegment.recover` throw
`InvalidOffsetException`. Kafka *has* code that catches this and truncates the log — but "this code can't be
hit on recovery, because of the code paths in `loadSegments`... we always throw this exception and that goes
all the way to the toplevel exception handler and crashes the JVM." Broker will not boot; the manual
workaround is deleting `.index`/`.log` files by hand. The bug class: detection and repair living at different
call sites, with only the detector reachable.

**CONDITIONS.** Any recovery design where the repair logic is not exercised through the real entry point.

**FALSIFIABLE CLAIM + TEST.** *Claim: every corruption the detector can raise has a test that exercises it
end-to-end through the real startup path, not through a unit test of the detector.* Test: for each error atom
the CRC/size/framing checks can return, build a real on-disk file that produces it and call the top-level
`Store.open/1`. Assert a clean `{:ok, _}` or a structured `{:error, _}` — never an unhandled exception.

**SOURCE.** https://issues.apache.org/jira/browse/KAFKA-3955

**APPLICABILITY.** single-node now.

---

#### 2.18 — etcd #14370: a single-node deployment acknowledged writes before the WAL and DB were durable

**WHAT GOES WRONG.** For a one-member cluster, raft hands etcdserver identical unstable and committed
entries, and etcd responded to the client after only *partially* applying: "etcd commits the boltDB
transaction periodically instead of on each request" and "etcd saves WAL entries in parallel with applying
the committed entries." A crash right after the ack loses the write. Explicitly a **single-member-only** bug
— with multiple members, replication forces the ordering. The fix cost 5.38% latency and maintainers took it:
"Correctness takes precedence over performance."

**CONDITIONS.** Ack-before-durable where the durability step is batched or parallel. Exactly the shape of a
single-node log with periodic checkpointing.

**FALSIFIABLE CLAIM + TEST.** *Claim: with `fsync: true`, a `transact/1` that returned `:ok` survives an
immediate machine-level crash, 100% of the time; with `fsync: false`, the documented guarantee is explicitly
weaker and the test asserts the weaker guarantee rather than staying silent.* Test: LazyFS-mounted data dir;
loop {write fact N; on `:ok` trigger the LazyFS `crash` fifo; restart; assert fact N present}. 500 iterations
with `fsync: true`, assert zero losses. With `fsync: false`, assert only that recovery is a **prefix**, and
record the observed loss window as a documented number.

**SOURCE.** https://github.com/etcd-io/etcd/issues/14370 · https://github.com/etcd-io/etcd/pull/14394

**APPLICABILITY.** single-node now — literally the single-node case.

---

#### 2.19 — RocksDB #6316: `fsync` failed on ENOSPC and RocksDB kept appending to the same MANIFEST

**WHAT GOES WRONG.** `MANIFEST write IO error: No space left on device While fsync: ./MANIFEST-013313`.
RocksDB logged the error and continued appending version edits to the same file. Result:
`Corruption: error in middle of record`, `ldb list_column_families` fails, DB unopenable. The maintainer's
diagnosis: *"the bug here is that when the DB recovers from NoSpace error, it continues to append to the
current manifest. We should create a new manifest file if the previous append/sync failed."* Reported to have
occurred twice in different production environments.

**CONDITIONS.** A failed append or sync followed by continued appends to the same file — the failed write may
be partially present.

**FALSIFIABLE CLAIM + TEST.** *Claim: after any write or sync error on the log or checkpoint, the store stops
appending to that file; recovery opens a fresh one.* Test: a FUSE shim returns `ENOSPC` on write N; assert
(a) no write N+1 to the same fd, (b) the store enters a halted state, (c) after restart with space restored,
replay recovers records 1..N−1 and appends to a **new** segment.

**SOURCE.** https://github.com/facebook/rocksdb/issues/6316 · https://github.com/facebook/rocksdb/pull/6331

**APPLICABILITY.** single-node now.

---

#### 2.20 — SQLite's WAL frame format is the fix for stale-record confusion: salt + cumulative checksum

**WHAT GOES WRONG (as the positive model).** SQLite's WAL frame header is
`{page_number, db_size_after_commit, salt-1, salt-2, checksum-1, checksum-2}`. A frame is valid **iff both**
(1) its salts match the WAL header's salts and (2) the checksum is *cumulative* — "computed consecutively on
the first 24 bytes of the WAL header and the first 8 bytes and the content of all frames up to and including
the current frame." The salt is re-randomized at each checkpoint. Two properties follow: a stale frame from a
previous WAL generation cannot be mistaken for a current one (salt), and a record cannot be relocated or
reordered within the file (chained checksum). And `db_size_after_commit != 0` marks a commit record, so a
partial transaction is structurally distinguishable from a complete one.

**CONDITIONS.** Design-time. This is the countermeasure to 1.7, 1.33, 2.8 and 2.2 simultaneously.

**FALSIFIABLE CLAIM + TEST.** *Claim: a byte-identical record from a previous generation of the file cannot
validate in the current generation.* Test: write records 1..100; checkpoint and truncate; write a shorter
run 1..50; physically splice the bytes of old record 60 into the tail. Assert replay rejects it.
**The current `<<size::32, crc32::32, payload>>` framing fails this test** — a stale record validates fine.
Concrete fix to test against: chain the CRC (`crc_n = crc32(crc_{n-1} <> payload_n)`) or add a 32-bit
per-file generation to each header.

**SOURCE.** https://www.sqlite.org/fileformat2.html §4.1 (WAL Format) · https://www.sqlite.org/wal.html

**APPLICABILITY.** single-node now.

---

#### 2.21 — Mispairing a data file with a sidecar from a different generation

**WHAT GOES WRONG.** SQLite's corruption catalogue enumerates several failures that transfer directly to a
log-plus-checkpoint-sidecar design. §1.4 *mispairing database files and hot journals*: copying the main file
without its journal, or overwriting a database without deleting its journal, silently mixes generations.
§2.5 *unlinking or renaming a file while in use*: two processes end up on different inodes sharing the same
sidecar filename. §2.6 *multiple links to the same file*: hard links and symlinks make two processes derive
different sidecar paths for the same data. §2.7 *carrying an open connection across `fork()`*. Note also §8.1
— a genuine WAL race that existed in SQLite from 3.7.0 through 3.51.2, i.e. more than a decade of production
use before anyone found it.

**CONDITIONS.** `cp -r` of a live data directory; container image builds; partial restore; an operator
copying the log but not the checkpoint.

**FALSIFIABLE CLAIM + TEST.** *Claim: the log and the checkpoint sidecar carry a shared UUID written at store
creation; opening a checkpoint whose UUID does not match the log's is a hard error.* Test: create stores A and
B; swap A's checkpoint sidecar into B's directory; assert `{:error, {:checkpoint_mismatch, _, _}}` on open,
not a silent wrong answer. Second test: copy the log without the checkpoint, and vice versa; assert both error.

**SOURCE.** https://www.sqlite.org/howtocorrupt.html

**APPLICABILITY.** single-node now.

---

#### 2.22 — KAFKA-13664: preallocated zero-filled segments read as `Record size 0`

**WHAT GOES WRONG.** With `log.preallocate=true`, Kafka creates 1 GB zero-filled segment files. Reading them
yields `CorruptRecordException: Record size 0 is less than the minimum record overhead (14)`;
`kafka-dump-log.sh` fails on any segment; `__consumer_offsets` loading fails after a broker reboot because
the reader treats file size as the data bound. The preallocated tail is indistinguishable from data whenever
`file_size != data_size`. Note the interaction with item 1.7: here a zero-length record is treated as an
*error*; in the framing under test it is treated as a *valid record*. Neither is "end of data" unless you say
so explicitly.

**CONDITIONS.** Preallocated or recycled files. Also any S3 restore that pads a missing range.

**FALSIFIABLE CLAIM + TEST.** *Claim: if the design ever preallocates, the authoritative end-of-data is a
persisted watermark, not the file size; and replay completes in O(data) not O(file) time.* Test: `fallocate`
a 1 GB segment, write 10 records, replay. Assert exactly 10 recovered, no error, and wall-clock under a bound
that a naive whole-file scanner would blow. If the design does **not** preallocate, record that as a
deliberate decision with this item as the rationale.

**SOURCE.** https://issues.apache.org/jira/browse/KAFKA-13664

**APPLICABILITY.** single-node now if segments are ever preallocated or recycled; otherwise a recorded
design decision.

---

#### 2.23 — CASSANDRA-13918: the newest *allocated* segment is not the newest *written* segment

**WHAT GOES WRONG.** Commitlog recovery tolerates truncation in "the most recent log file found on disk" but
aborts on problems in the others. Because segments are allocated ahead of use, "it's possible to get into a
state where the last commit log file actually written to is not the same file that was most recently
allocated" — so the genuinely incomplete final segment is not the one granted tolerance, and startup fails.
The fix was to filter header-only files before recovery.

**CONDITIONS.** Segment identity derived from filename ordering or mtime rather than from content.

**FALSIFIABLE CLAIM + TEST.** *Claim: "the last segment" is the highest sequence number containing at least
one valid record, not the filename maximum or the newest mtime.* Test: create segments 1, 2, 3 where 3 is
header-only/empty and 2 has a torn tail. Assert recovery treats 2 as the tolerant tail, does not error on 3,
and that the next append lands in the right place.

**SOURCE.** https://issues.apache.org/jira/browse/CASSANDRA-13918

**APPLICABILITY.** single-node now, once segments roll.

---

#### 2.24 — etcd #11918: WAL purge broke the CRC chain and every node crash-looped on healthy hardware

**WHAT GOES WRONG.** In etcd 3.3.21/3.4.8, after a WAL file was purged, `ValidSnapshotEntries` walked the
remaining files and the decoder's running CRC no longer matched the `crcType` record at the head of the next
file. Every node failed on restart with `etcdmain: walpb: crc mismatch` — on healthy hardware; the reporter
noted "None of these machines have ever suffered any hardware failure or unexpected shutdown." Fixed in
3.3.22/3.4.9. **The lesson pairs directly with 2.20: adopting a chained CRC buys stale-record detection and
buys you this bug**, so the segment-deletion policy must be tested against it.

**CONDITIONS.** Chained checksums combined with segment deletion, compaction, or GC.

**FALSIFIABLE CLAIM + TEST.** *Claim: after deleting every segment fully covered by the latest checkpoint,
recovery succeeds.* Test: a matrix over `(n_segments, checkpoint_position, n_deleted)`. For each cell: write,
checkpoint, delete covered segments, reopen, assert the fact set matches an undeleted control run. Include
the cell where the checkpoint sits exactly on a segment boundary and the cell where it sits one byte before
one.

**SOURCE.** https://github.com/etcd-io/etcd/issues/11918 · https://github.com/etcd-io/etcd/pull/11924

**APPLICABILITY.** single-node now.

---

#### 2.25 — RocksDB #9419 / #10357: files deleted, the metadata edit recording the deletion never made durable

**WHAT GOES WRONG.** Files were deleted during shutdown or purge, then reopen failed with
`Corruption: IO error: No such file or directory: While open a file for random read: .../048510.ldb`. The
maintainer states the violated invariant: *"We only delete files who we've already marked being deleted in
manifest... I assume some tail record of file deletion is missing?"* In #10357 the mirror image: the MANIFEST
dump thinks the file should exist but it was deleted — the unlink happened and the metadata edit did not
reach disk. Multiple independent reporters across RocksDB 6.3.6, 6.15.5, 6.25 and 7.5.3, several describing
multi-hour production outages. #13141 is the same failure while restoring from a checkpoint. **The correct
order is: record the deletion durably, then unlink.**

**CONDITIONS.** Delete-then-record, or record-without-fsync-then-delete. Applies to GC of log segments
covered by a checkpoint, and to S3 lifecycle rules expiring segments.

**FALSIFIABLE CLAIM + TEST.** *Claim: a segment is unlinked only after a durable record exists marking it
obsolete, and every segment referenced by any on-disk checkpoint exists.* Test: an invariant checker run
after every operation in a randomized op sequence (append / checkpoint / gc / restart) asserting
`∀ checkpoint c, ∀ segment s referenced by c: File.exists?(s)`. Then inject `SIGKILL` between the
mark-obsolete write and the `File.rm`, and between the `File.rm` and the fsync of the mark; assert reopen
succeeds in both.

**SOURCE.** https://github.com/facebook/rocksdb/issues/9419 · https://github.com/facebook/rocksdb/issues/10357 ·
https://github.com/facebook/rocksdb/issues/13141

**APPLICABILITY.** single-node now.

---

#### 2.26 — CrashMonkey / ACE (OSDI '18): the crash-test suite is finite, and three operations is enough

**WHAT GOES WRONG (as method).** Mohan et al.: *"most reported bugs can be reproduced using small workloads
of three or fewer file-system operations on a newly-created file system, and that all reported bugs result
from crashes after fsync() related system calls."* Their tools found 24 of the 26 crash-consistency bugs
reported in Linux filesystems over five years, plus **10 new bugs in mature filesystems, seven of which had
been in the kernel since 2014**, causing "broken rename atomicity and loss of persisted files." The
methodological consequence is the important part: exhaustive enumeration of tiny workloads beats long random
soak runs, and it terminates.

**CONDITIONS.** N/A — this is the shape the crash-test suite should take.

**FALSIFIABLE CLAIM + TEST.** *Claim: exhaustive enumeration of all crash points in every 1-, 2-, and
3-operation sequence over the op alphabet yields zero recovery violations.* Test: alphabet =
`{append, checkpoint, gc, segment_roll, fsync, restart}` — ~1,300 sequences of length ≤3. For each, enumerate
crash points from the syscall trace; for each crash, restart and assert the recovered fact set is a prefix of
the acknowledged set and a superset of the fsynced set. Bounded, finite, completable.

**SOURCE.** https://www.usenix.org/conference/osdi18/presentation/mohan

**APPLICABILITY.** single-node now.

---

#### 2.27 — LazyFS: the tool that models "fsync optional and off by default" exactly

**WHAT GOES WRONG (as tooling).** LazyFS (VLDB '24) is a FUSE filesystem with its own page cache that flushes
**only** on explicit `fsync`/`fdatasync`. It injects lost writes (`clear-cache`, optionally with
`crash=true`), **torn-seq** (a run of consecutive writes with no intervening fsync, where you name which ones
persist — e.g. persist writes 1 and 4 of 4, dropping 2 and 3), and **torn-op** (split a single large write
into N parts and persist a chosen subset). It reports at-risk blocks via `unsynced-data-report` and logs every
syscall with arguments. Jepsen ships `jepsen.lazyfs` with `lose-unfsynced-writes!` and a nemesis. This is the
tool that found etcd #14098 and #14102.

**CONDITIONS.** N/A — Linux only, so it belongs in CI rather than on a laptop.

**FALSIFIABLE CLAIM + TEST.** *Claim: under `lose-unfsynced-writes`, recovery always yields a byte-prefix of
the pre-crash log, and never a file whose last record is partially present with a passing CRC.* Test: mount
the data dir on LazyFS; append facts with known payloads; inject `torn-op` on the append write with
`parts=3, persist=[1,3]` — a **non-linear** tear where the first and third thirds land and the middle does
not. That is precisely the case a CRC over payload alone could theoretically pass if the missing middle
happens to be zeros in both images. Assert replay stops at the previous record. Repeat with `persist=[1,2]`
for the linear case.

**SOURCE.** https://github.com/dsrhaslab/lazyfs · https://www.vldb.org/pvldb/vol17/p3017-ramos.pdf ·
https://jepsen-io.github.io/jepsen/jepsen.lazyfs.html

**APPLICABILITY.** single-node now. **Highest-leverage tooling item in this document.**

---

#### 2.28 — Jepsen on Redis-Raft: single-node durability is the untested foundation everything else rests on

**WHAT GOES WRONG (as evidence).** Kingsbury found 21 issues including total data loss on any failover, but
the load-bearing sentence for this system is in Future Work: *"We have not explored single-node faults, such
as filesystem corruption or the loss of un-fsynced data written to disk. Both might be of interest for
Redis-Raft, whose correctness hinges (like most consensus systems) on single-node durability."* Also
documented: Redis Labs told Jepsen that Redis Enterprise's "full ACID compliance" holds only with replication
disabled **and the WAL set to fsync on every write** — and that this was not clearly documented.

**CONDITIONS.** N/A — this is the argument for stating durability claims precisely per mode.

**FALSIFIABLE CLAIM + TEST.** *Claim: the README states, per fsync mode, exactly what survives a `SIGKILL`
and what survives a power loss, and each statement has a named test asserting it.* Three tests:
`fsync_always_survives_sigkill`; `fsync_off_survives_sigkill_process_only` (the page cache outlives process
death — assert full recovery); `fsync_off_loses_bounded_window_on_power_loss` (LazyFS `clear-cache`; assert a
prefix **and** that the loss window does not exceed the documented number, failing the build if it does).

**SOURCE.** https://jepsen.io/analyses/redis-raft-1b3fbf6

**APPLICABILITY.** single-node now.

---

#### 2.29 — `appendfsync everysec` loses two seconds, not one — and the docs say one

**WHAT GOES WRONG.** Redis's documentation says "you may lose 1 second of data" and "you can only lose one
second worth of writes." The implementation disagrees. In `flushAppendOnlyFile()`, if a background fsync is
in progress Redis postpones the `write(2)` (because on Linux `write(2)` blocks behind an in-flight `fsync` on
the same fd) for up to 2000 ms, after which it increments `server.aof_delayed_fsync`, logs "Asynchronous AOF
fsync is taking too long (disk is busy?)", and writes anyway. antirez's own post: *"in the worst case, within
2 seconds everything you write is going to be committed to the operating system buffers."* PR #8612
separately documents a low-resolution-clock bug making the effective interval "possibly up to 2 seconds" —
which the maintainers deliberately **did not fix** ("the code was stable for some years").

**CONDITIONS.** Slow disk, or an fsync landing on the wrong side of a one-second boundary. Directly relevant
if a periodic-fsync mode is ever added between `fsync: false` and `fsync: true`.

**FALSIFIABLE CLAIM + TEST.** *Claim: the documented worst-case loss window for any periodic-fsync mode is
measured, not assumed, and a counter exposes when the interval was exceeded.* Test: FUSE shim delays `fsync`
by 1500 ms; drive writes; assert (a) an `fsync_delayed` counter increments, (b) the measured maximum interval
between successful fsyncs is recorded, (c) the documented worst-case number is ≥ the measured maximum. Fail
the build otherwise.

**SOURCE.** https://oldblog.antirez.com/post/redis-persistence-demystified.html ·
https://github.com/redis/redis/pull/8612 · https://github.com/redis/redis/blob/unstable/src/aof.c

**APPLICABILITY.** single-node now.

---

#### 2.30 — Kafka's durability comes from replication, not from the disk — and this design copied the shape without the mitigation

**WHAT GOES WRONG.** Kafka's own operations guide: *"We recommend using the default flush settings which
disable application fsync entirely... Note that durability in Kafka does not require syncing data to disk, as
a failed node will always recover from its replicas."* `log.flush.interval.messages` and `flush.ms` both
default to `Long.MaxValue`. The log page states the guarantee honestly: with M messages and S seconds, "This
gives a durability guarantee of losing at most M messages or S seconds of data in the event of a system
crash." Kafka even recommends `data=writeback` on ext4 while acknowledging "these options are generally
unsafe in a failure scenario, and will result in much more data loss and corruption... For a single broker
failure, this is not much of a concern as the disk can be wiped and the replicas rebuilt." **A single-node
append-only log that defaults fsync off has adopted Kafka's page-cache reliance without Kafka's replication.**

**CONDITIONS.** The default configuration of the system under test.

**FALSIFIABLE CLAIM + TEST.** *Claim: the default configuration's durability guarantee is stated as an
explicit bound (X transactions or Y seconds), and a test measures the actual worst case against it.* Test:
LazyFS `clear-cache` at randomized times under continuous load, 200 trials; record acknowledged-but-lost
facts per trial; assert `max(lost) <= documented_bound`. If no bound is documented, the test cannot be
written — and that absence is the finding.

**SOURCE.** https://kafka.apache.org/43/operations/hardware-and-os/ ·
https://kafka.apache.org/43/implementation/log/

**APPLICABILITY.** single-node now.

---

#### 2.31 — KIP-966 "last replica standing": restore must never truncate a local log that is longer

**WHAT GOES WRONG.** Kafka's KIP-966 documents the endgame of un-fsynced local loss meeting a
"recover from the surviving copy" protocol: a replica that suffers an unclean shutdown and loses un-flushed
committed data gets re-elected, and rejoining followers **truncate their own logs to match it**, "thereby
removing the last copies of the committed records which the leader lost initially" — a local disk fault
becoming global data loss. KIP-101's scenario 2 is the same shape after a double crash, where "an offset in
one replica points to the middle of a compressed set in another, causing replication to stall." Fixed in
Kafka 4.1 by tracking Eligible Leader Replicas separately from the ISR. The single-node miniature of this bug
is a restore that overwrites a longer local log with a shorter backup.

**CONDITIONS.** Any restore/sync where authority is "whichever copy we are looking at" rather than "whichever
copy provably has the data."

**FALSIFIABLE CLAIM + TEST.** *Claim: an S3 restore never truncates a local log that is longer than the
restored one without an explicit operator override.* Test: back up at offset 1000; append locally to offset
2000 without backing up; run restore. Assert `{:error, {:local_ahead_of_backup, 2000, 1000}}` and that the
local file is byte-for-byte untouched.

**SOURCE.** https://cwiki.apache.org/confluence/spaces/KAFKA/pages/263426970/KIP-966+Eligible+Leader+Replicas ·
https://cwiki.apache.org/confluence/display/KAFKA/KIP-101+-+Alter+Replication+Protocol+to+use+Leader+Epoch+rather+than+High+Watermark+for+Truncation

**APPLICABILITY.** single-node now for the restore-direction invariant; only if distributed for the
leader-election mechanics.

---

#### 2.32 — CORDS (FAST '17): a single file-system fault in one node broke all eight distributed stores

**WHAT GOES WRONG.** Ganesan et al. built `errfs` (FUSE, injecting corruption or read/write errors one block
at a time) and tested Redis, ZooKeeper, Cassandra, Kafka, RethinkDB, MongoDB, LogCabin and CockroachDB.
Single-node findings that transfer directly: **Redis does not checksum AOF user data at all**, so corruption
is undetected locally; Cassandra does not checksum SSTable user data unless compression is on, and a
corrupted value that is *lexically greater* than the original wins digest-mismatch resolution; ZooKeeper
detects log corruption by checksum but "reacts by simply crashing", and a write error during log
initialization partially crashes it (transaction threads die, quorum thread lives) into indefinite write
unavailability. Their four root causes, all single-node: faults often undetected locally; when detected,
systems crash instead of recovering; **systems do not distinguish crash-induced corruption from other
corruption**; local and global recovery interact unsafely.

**CONDITIONS.** One bit flip, one `EIO`, one write error — in one file, in one node.

**FALSIFIABLE CLAIM + TEST.** *Claim: for every 4 KiB block of every file the store writes, injecting
(a) corruption, (b) a read error and (c) a write error produces a classified, non-crashing, documented
outcome.* Test: build the block-access trace of a representative workload (append, checkpoint, restart, S3
backup), then loop over every (file, block, fault-type) triple injecting exactly one, and record the outcome
in a committed table. Any cell reading "unhandled exception" or "silently wrong answer" is a bug. CORDS is
open source and does exactly this.

**SOURCE.** https://www.usenix.org/conference/fast17/technical-sessions/presentation/ganesan ·
https://github.com/aganesan4/CORDS

**APPLICABILITY.** single-node now for the local-behavior half; only if distributed for propagation.

---

### Cross-cutting: the three compounding failures

These do not merely coexist; they chain, and nothing in the chain surfaces an error.

1. **Dropped write → hole → silent truncation → poisoned backup.** An unserializable write (1.31 — 8 of 15
   SSDs, hundreds per power fault on the worst) creates a *hole*, not a *tail*. "Stop at first bad CRC"
   (1.10, 2.8) converts that hole into silent truncation of everything after it. The checkpoint sidecar then
   records the truncated offset as authoritative (2.3), and the next incremental backup uploads the truncated
   log to S3. There is no point in that chain at which an error is raised.

2. **One header change closes four bugs.** Folding the record's byte offset and a per-file generation/UUID
   into the CRC input, and rejecting `size == 0`, simultaneously closes: 1.7 (all-zero region parses as a
   valid empty record — verified: `:erlang.crc32(<<>>) == 0`), 1.8 (size field outside the CRC), 1.33
   (misdirected writes / valid record at the wrong offset), 2.2 (segments concatenated in the wrong order),
   2.15 (`size == 0` infinite replay loop) and 2.20 (stale record from a previous generation). Cost: a few
   bytes of header. This is the highest return in the document.

3. **`EIO` and "bad CRC" are different events needing different responses.** A read error (1.40 — 2–6 per
   1,000 drive-days in Google's fleet) must not advance the checkpoint and must not be read as end-of-log; a
   CRC mismatch may indicate local corruption where the S3 segment is authoritative. Injecting both with
   `dm-dust`/`dm-flakey` and asserting divergent, named outcomes is the single highest-yield fault-injection
   test to build first.

---


## Section 2 — Isolation anomalies and caching claims

**System under test (SUT), for applicability calls:** immutable append-only fact log in Elixir/OTP,
Datomic-shaped. Facts `(id, attribute, answer, transaction, provenance)` accumulate in append-only
*ledgers*. A *snapshot* is one or more ledgers read at a transaction; a snapshot has a **name**, a
plain map the client holds and can construct by hand. Central claim: **a name answers the same thing
forever**, so clients cache on `{name, question}` and never invalidate. `write(name, facts) -> name'`,
`ask(name, question)`, `watch(name, question)`. Derived data = *formulas*, pure and cached by name.
Single node today.

Notation for schedules follows Berenson et al.: `w1[x]` = transaction 1 writes x, `r2[x]` = transaction 2
reads x, `c1`/`a1` = commit/abort of T1, `r1[P]` = predicate read. For the SUT the translation is
`w1[x]` → `write(N, [fact about x])`, `r2[x]` → `ask(N, "x?")`.

Two framing notes that determine how much of this section applies:

1. **A single writer serializes writes, not reads.** Every anomaly below whose witness needs two
   *concurrent writers* is N/A while a single transactor exists. Every anomaly whose witness needs
   only *one write and one read taken at two different moments* is live today — and that is most of
   the read-skew family.
2. **The immutability claim converts isolation bugs into cache-poisoning bugs.** In a mutable
   database, a read-skew is a wrong answer once. Here, a wrong answer gets keyed by a name and
   *memoized forever*, and there is no invalidation path to repair it. This is the single most
   important structural finding in this research: for this design the *severity multiplier* on any
   isolation defect is unbounded, so the tests must be run to a much higher confidence than they
   would be for a conventional store.

---

### Topic 3 — Transaction isolation and consistency anomalies

#### 3.1 The taxonomy is underspecified at the source — pick a formalism and say which

##### 3.1.1 ANSI phenomena have a strict and a broad reading, and the strict reading is wrong
**What goes wrong.** ANSI SQL-92 defines isolation by English-language phenomena (Dirty Read,
Non-repeatable Read, Phantom). Berenson et al. show each has two formalisations. Strict: `A1: w1[x]…r2[x]…(a1 and c2 in any order)`
— an anomaly that *did* occur. Broad: `P1: w1[x]…r2[x]…((c1 or a1) and (c2 or a2) in any order)` — a
pattern that *might* lead to one. The strict reading admits the classic inconsistent-analysis history
`H1: r1[x=50] w1[x=10] r2[x=10] r2[y=50] c2 r1[y=50] w1[y=90] c1`, which is non-serializable but
violates none of A1/A2/A3. Berenson's Remark 4: "the correct interpretations are the Broad ones."
A spec that says "we prevent dirty reads" therefore says almost nothing.
**Conditions.** Any system whose isolation claim is phrased in ANSI phenomena rather than in Adya
cycles.
**Claim + test.** Claim: *the SUT's isolation is stated as a set of prohibited Adya phenomena, not as
an ANSI level name.* Test is documentary + a conformance suite: for each of `{G0, G1a, G1b, G1c,
G-single, G-nonadjacent, G2-item, G2}` the suite must contain a generator that would produce it and
an assertion that it is absent. A missing generator is a failing test.
**Source.** <https://arxiv.org/pdf/cs/0701157> (Berenson, Bernstein, Gray, Melton, O'Neil & O'Neil,
"A Critique of ANSI SQL Isolation Levels", MSR-TR-95-51 / SIGMOD '95), §2.2, §3, Remarks 4–5.
**Applicability.** Single-node now (it is a spec-hygiene requirement, not a distribution one).

##### 3.1.2 "ANOMALY SERIALIZABLE" — forbidding P1/P2/P3 does not give serializability
**What goes wrong.** ANSI Table 1 defines SERIALIZABLE as forbidding the three phenomena, which
Berenson names *ANOMALY SERIALIZABLE*, and then separately requires "fully serializable execution"
in subclause 4.28. The paper's Remark 10 shows `ANOMALY SERIALIZABLE « SNAPSHOT ISOLATION` — i.e.
snapshot isolation is *strictly stronger* than the phenomena-based definition of serializable, while
still not being serializable. Passing a phenomena checklist is not evidence of serializability.
**Conditions.** Any checklist-driven correctness argument.
**Claim + test.** Claim: *no phenomena checklist is accepted as evidence of serializability; only a
cycle check over the full dependency graph is.* Test: run a workload that exhibits write skew (§3.4.9)
and confirm the test harness fails it even though every P0–P3 assertion passes.
**Source.** Same paper, Remark 10 and Table 4.
**Applicability.** Single-node now.

##### 3.1.3 Repeatable Read and Snapshot Isolation are *incomparable*, not ordered
**What goes wrong.** Berenson Remark 9: `REPEATABLE READ »« Snapshot Isolation`. SI forbids A3
(phantoms in the strict sense — "Snapshot Isolation has no phantoms") but allows A5B write skew;
Locking REPEATABLE READ does the opposite. Teams reason "we're at least repeatable read" and infer
guarantees that do not follow.
**Conditions.** Any comparison of two isolation levels by an intuitive strength ordering.
**Claim + test.** Claim: *the SUT's guarantee is stated as a set, not a rung on a ladder.* Test:
assert both directions — a phantom-style test that the SUT passes and a write-skew test that it
fails (or vice versa) — and require the documentation to name which.
**Source.** Same paper, Remarks 8–10, Figure 2.
**Applicability.** Single-node now.

##### 3.1.4 Adya's DSG is the formalism worth adopting
**What goes wrong.** Without a formal dependency model there is no way to say what a checker found.
Adya, Liskov & O'Neil define a *Direct Serialization Graph* over committed transactions with three
edge types: **directly write-depends (ww)** — Ti installs xi and Tj installs x's next version;
**directly read-depends (wr)** — Ti installs xi and Tj reads xi; **directly anti-depends (rw)** —
Ti reads xi and Tj installs x's next version. Levels are then: PL-1 forbids G0; PL-2 forbids G1;
PL-2.99 forbids G1 + G2-item; PL-3 forbids G1 + G2.
**Conditions.** Always.
**Claim + test.** Claim: *the SUT's checker emits an Adya DSG and reports anomalies as named cycles
in it.* Test: the checker's output on a deliberately-injected cycle must name the phenomenon and
print the participating transactions and the edge labels.
**Source.** <https://pmg.csail.mit.edu/papers/icde00.pdf> (Adya, Liskov, O'Neil, "Generalized
Isolation Level Definitions", ICDE 2000); summary at
<https://blog.acolyer.org/2016/02/25/generalized-isolation-level-definitions/>.
**Applicability.** Single-node now.

---

#### 3.2 The G-codes, with definitions and two-transaction witnesses

Each item below gives the formal definition, a schedule that exhibits it, and the SUT translation.

##### 3.2.1 G0 — Write Cycle (dirty write, P0)
**Definition.** "A history exhibits a write cycle if its direct serialization graph contains a cycle
consisting entirely of write-dependency edges." ANSI equivalent P0: `w1[x]…w2[x]…(c1 or a1)`.
**Schedule.** `w1[x] w2[x] w2[y] c2 w1[y] c1` — T1's x survives, T2's y survives; neither serial
order produces that. Berenson: with dirty writes you cannot undo by restoring a before-image, so
"even the weakest locking systems hold long duration write locks. Otherwise, their recovery systems
would fail."
**Conditions.** Two writers interleaving on two keys without long-duration write locks.
**Claim + test.** Claim: *G0 is impossible in the SUT because a single transactor totally orders
writes.* Test: `write/2` from N concurrent processes, each appending a unique token to two different
ledger keys; assert that for every pair of keys the resulting per-key version orders are consistent
with one global order (Elle's `:G0` check restricted to ww edges).
**Source.** Berenson §3 (P0, Remark 3); Adya G0; Hermitage's G0 case.
**Applicability.** N/A single-node with one transactor — *but becomes the first thing to re-test the
day a second writer, a follower, or a per-ledger writer appears.* Also live today if two ledgers can
be written by two different processes without a shared serialisation point.

##### 3.2.2 G1a — Aborted Read
**Definition.** T2 reads a version of an object written by T1, and T1 then aborts. The read must not
be committed-visible.
**Schedule.** `w1[x=101] r2[x=101] a1 c2` — T2 committed a value that never existed.
**Conditions.** A write becomes visible before its transaction is durable/committed.
**Claim + test.** Claim: *`ask(N', q)` never returns a fact from a transaction that later aborts,
where N' is any name.* Test: begin a write that will be rejected (constraint violation, transactor
crash injected mid-append), concurrently poll `ask` on the advanced name and on the pre-write name;
assert the rejected facts are never observed at any name, before or after the abort. **The immutable
twist:** if it is observed even once it is now cached under a name forever, so the assertion must be
"never observed", not "eventually not observed".
**Source.** Adya (G1a); Elle §2; Hermitage postgres.md "prevents Aborted Reads (G1a)".
**Applicability.** Single-node now — this is the highest-value G-code for the SUT because a
partially-applied append is exactly a torn write (see §4.4).

##### 3.2.3 G1b — Intermediate Read
**Definition.** T2 reads a version of an object modified by T1 that was not T1's *final* modification
of that object.
**Schedule.** `w1[x=101] r2[x=101] w1[x=11] c1 c2` — T2 saw 101, a value T1 never intended to publish.
**Conditions.** A multi-fact transaction whose facts become individually visible as they are appended.
**Claim + test.** Claim: *a transaction's facts become visible atomically; no name ever exposes a
prefix of a transaction.* Test: `write(N, facts)` with a large fact set (thousands of facts, forced
across segment/page boundaries); a concurrent reader in a tight loop calls `ask(N', "count of facts
in tx T")` for the advanced name and asserts the answer is always 0 or `length(facts)`, never
anything in between. Run under `:erlang.yield/0` injection and under a scheduler with
`+sbwt none` to widen the window.
**Source.** Adya (G1b); Elle §2; Hermitage postgres.md G1b case.
**Applicability.** Single-node now. This is a *single-writer* anomaly — no concurrency between
writers is required, only concurrency between a writer and a reader.

##### 3.2.4 G1c — Circular Information Flow
**Definition.** "The Direct Serialization Graph contains a directed cycle consisting entirely of
(read and write) dependency edges" — i.e. ww and wr edges only.
**Schedule.** `w1[x=11] w2[y=22] r1[y=22] r2[x=11] c1 c2` — T1 saw T2's write and T2 saw T1's, so
each precedes the other.
**Conditions.** Two writers each observing the other's uncommitted state.
**Claim + test.** Claim: *G1c is impossible; the name returned by `write` linearises the writer's own
observation.* Test: two concurrent writers, each doing read-then-write on the other's key, checked by
Elle's `:G1c` (cycle over ww ∪ wr).
**Source.** Adya (G1c); Hermitage postgres.md G1c case.
**Applicability.** N/A single-writer today; re-test on any multi-writer change.

##### 3.2.5 G2-item — Item Anti-dependency Cycle (write skew on disjoint items)
**Definition.** A DSG cycle containing one or more **item** anti-dependency (rw) edges. The canonical
instance is A5B write skew: `r1[x] r2[y] w1[y] w2[x] (c1 and c2 occur)`.
**Schedule (Fekete's bank example).** X = checking = 70, Y = savings = 80, constraint X+Y > 0.
`H2: R1(X0,70) R2(X0,70) R1(Y0,80) R2(Y0,80) W1(X1,-30) C1 W2(Y2,-20) C2` — final state violates the
constraint, and *first-committer-wins did not fire because the two transactions wrote different items.*
**Conditions.** Two transactions read an overlapping set, then write disjoint items, under snapshot
semantics.
**Claim + test.** Claim: *the SUT admits G2-item / write skew* (this is almost certainly true and
should be documented as a known limit, not a bug). Test: two clients each `ask(N, "sum of X and Y")`
at the same name, each then `write` a fact that is safe only under the value it read. Assert that the
resulting name violates the invariant — then assert the *documentation* says so. If the SUT claims
serializability, this is a hard failure.
**Source.** Berenson A5B (§4.2); <https://www.cs.umb.edu/~poneil/ROAnom.pdf> Example 1.2; Adya G2-item;
Hermitage postgres.md "repeatable read does not prevent Write Skew (G2-item)".
**Applicability.** Single-node now, *if* two clients can compute their facts from a read at a common
name and both writes succeed. A single transactor does not prevent write skew — it serialises the
appends but the *decision* each client made was based on a stale read. This is the SUT's most likely
true anomaly.

##### 3.2.6 G2 — Anti-dependency Cycle including predicates
**Definition.** "A DSG contains a directed cycle with one or more anti-dependency edges (item or
predicate)." Strictly weaker prohibition than G2-item, i.e. G2 covers phantom-flavoured skew.
**Schedule.** `r1[P] r2[P] w1[insert row satisfying P] w2[insert row satisfying P] c1 c2` — Hermitage:
`select * from test where value % 3 = 0` in both, then `insert (3,30)` and `insert (4,42)`; afterwards
the predicate returns both rows and neither transaction's assumption held.
**Conditions.** Two transactions read the same predicate and each writes something that changes the
other's predicate result.
**Claim + test.** Claim: *`ask(N, question)` where `question` is a predicate/aggregate over a ledger
is subject to G2.* Test: two clients `ask(N, "count of facts with attribute :a")`, each writes one new
`:a` fact conditioned on the count being below a cap; assert the cap is exceeded. This is the
formula-level version of the phantom and it is the one that bites a Datomic-shaped store, because
questions are arbitrary queries, not row reads.
**Source.** Adya G2; Hermitage postgres.md "Anti-Dependency Cycles (G2)".
**Applicability.** Single-node now.

##### 3.2.7 G-single — exactly one anti-dependency edge (read skew, A5A)
**Definition.** "A history H exhibits phenomenon G-single if DSG(H) contains a directed cycle with
exactly one anti-dependency edge." ANSI-style: `A5A: r1[x] w2[x] w2[y] c2 r1[y] (c1 or a1)`.
**Schedule.** T1 reads x = 10; T2 sets x = 12 and y = 18 and commits; T1 then reads y = 18. T1 has
seen x from before T2 and y from after it — a state that never existed.
**Conditions.** A read that spans two moments. **No second writer is needed.**
**Claim + test.** Claim: *a name pins a single instant; `ask(N, q)` never mixes pre- and post-`T`
state for any T.* Test — the important one for the SUT: hold a name N, issue `ask(N, q1)` and
`ask(N, q2)` where q1 and q2 touch keys written by the same transaction, with a `write` racing in
between; assert the two answers are consistent with one transaction boundary. Then the harder
variant, §3.5.3: make q1 and q2 hit *different ledgers* in the same name.
**Source.** <https://jepsen.io/consistency/phenomena/g-single>; Berenson A5A; Hermitage
"Read Skew (G-single)".
**Applicability.** **Single-node now, and the highest-leverage read anomaly for this design.**
G-single needs one writer and one reader; the SUT has both.

##### 3.2.8 G-nonadjacent — the phenomenon that actually *defines* snapshot isolation
**What goes wrong.** The property that separates SI from read-committed is not "no read skew"; it is
that SI proscribes cycles in which "no two read-write edges are adjacent to one another". G-single
(exactly one rw edge) and Long Fork (several, non-adjacent) are both special cases. SI *permits*
cycles with adjacent rw edges — which is exactly write skew. If you test only G-single you will
mis-certify a store as snapshot-isolated.
**Schedule (Jepsen's four-transaction example).** T1 writes x=1; T2 reads x and observes y absent;
T3 inserts y=3; T4 reads all and sees only y=3. Edge sequence wr → rw → wr → rw with the two rw edges
non-adjacent.
**Conditions.** Three or more transactions; needs a generator that produces long cycles, not just pairs.
**Claim + test.** Claim: *if the SUT claims snapshot semantics, it prohibits G-nonadjacent.* Test:
Elle over a list-append workload with ≥4 concurrent logical processes and 5–10 ops per transaction;
assert no `:G-nonadjacent` (and separately, expect `:G2-item` to be *allowed*).
**Source.** <https://jepsen.io/consistency/phenomena/g-nonadjacent>.
**Applicability.** Single-node now. A two-transaction test suite structurally cannot find this;
budget for ≥4-transaction generators.

##### 3.2.9 OTV — Observed Transaction Vanishes
**What goes wrong.** T3 observes T1's effect on key 1, then observes key 2 at a *pre-T1* value: the
transaction it just saw has vanished. Prohibited by *monotonic atomic view*, which is what most
"read committed" implementations actually deliver.
**Schedule (Hermitage).** T1 sets 1→11 and 2→19 and commits; T3 reads key 1 → 11; T2 sets 2→18; T3
reads key 2 → 19; T2 commits; T3 reads key 2 → 18 and key 1 → 12. The failing variant is a T3 that
sees 1→11 and then 2→20 (pre-T1).
**Conditions.** A reader that does not hold a fixed snapshot across its reads.
**Claim + test.** Claim: *a held name gives atomic view: once any effect of transaction T is visible
at name N, every effect of T is visible at N.* Test: `write` a transaction touching K keys; a reader
holding one name asks each key in a randomised order under load; assert all-or-nothing per transaction.
**Source.** Hermitage README (OTV column) and postgres.md OTV case;
<https://github.com/ept/hermitage>.
**Applicability.** Single-node now. Direct test of the "a name is one instant" claim.

##### 3.2.10 PMP — Predicate-Many-Preceders
**What goes wrong.** A predicate read returns different sets at two moments in the same logical read
context: `select where value = 30` returns nothing, then `select where value % 3 = 0` returns the
newly inserted row.
**Schedule (Hermitage).** T1 `select * from test where value = 30` → empty; T2 `insert (3,30)`; c2;
T1 `select * from test where value % 3 = 0` → returns the new row.
**Conditions.** Predicate evaluation not anchored to the name.
**Claim + test.** Claim: *every question asked at a name evaluates its predicate against exactly the
facts visible at that name, including for questions the engine has never seen before.* Test: two
structurally different questions with overlapping extents, asked at the same name across a concurrent
write; assert extent consistency. Also assert it for a question compiled *after* the write landed —
this catches an engine that resolves attribute/index metadata at query-compile time rather than at
snapshot time.
**Source.** Hermitage postgres.md PMP cases.
**Applicability.** Single-node now.

##### 3.2.11 P4 — Lost Update, and P4C — Cursor Lost Update
**Definition.** `P4: r1[x] w2[x] w1[x] c1` — T1 reads x, T2 updates it, T1 writes based on its stale
read, T2's update is lost. `H4: r1[x=100] r2[x=100] w2[x=120] c2 w1[x=130] c1` — the +20 vanishes.
P4C is the same with a cursor read: `rc1[x]…w2[x]…w1[x]…c1`, prevented by Cursor Stability.
**Conditions.** Read-modify-write where the write does not carry the read's version.
**Claim + test.** Claim: *`write(name, facts)` where `facts` were computed from `ask(name, …)` is
subject to lost update unless `name` participates in a compare-and-set.* Test: N clients each
`ask(N, "counter")` and `write` counter+1; assert the final counter equals N. It will not, unless
`write/2` rejects when the supplied `name` is not the current head. **This is the single most
important API-shape question in the SUT:** does `write(name, facts)` mean "append after `name`"
(CAS, aborts on staleness) or "append at head" (blind write, loses updates silently)? The former is
first-committer-wins; the latter is P4 by construction.
**Source.** Berenson §4.1 (P4, P4C, H4); Hermitage postgres.md "Lost Update (P4)".
**Applicability.** **Single-node now.** A single transactor does not prevent lost update — it
guarantees both appends land, which is precisely the failure.

##### 3.2.12 Long Fork
**What goes wrong.** Two transactions in parallel snapshots each observe one of two concurrent
writes but not the other, so no single serial order explains both observations. Elle detects it but
"tags it as G2" — you get a true positive with a coarse label.
**Conditions.** Parallel snapshot isolation; multiple snapshot lineages.
**Claim + test.** Claim: *there is exactly one lineage of names; no two names are incomparable.*
Test: write x and y in separate transactions; two readers each ask both; assert not (reader A sees
x∧¬y and reader B sees y∧¬x). Assert additionally that the name type has a *total* order function
and that `write` refuses to fork.
**Source.** Elle paper §1 and §9 (Future Work), <https://arxiv.org/pdf/2003.10554>;
<https://jepsen.io/consistency/phenomena>.
**Applicability.** N/A single-node/single-writer; **becomes the defining test if ledgers are ever
written independently**, because a name that names *several* ledgers at several transactions is
structurally a fork point.

---

#### 3.3 What Snapshot Isolation gives — and precisely what it does not

##### 3.3.1 SI's actual definition and First-Committer-Wins
**Content.** "A transaction Ti executing under SI conceptually reads data from the committed state
of the database as of time start(Ti) (the *snapshot*), and holds the results of its own writes in
local memory store." At commit Ti gets a Commit-Timestamp and "successfully commits only if no other
transaction T2 with a Commit-Timestamp in T1's execution interval [Start-Timestamp, Commit-Timestamp]
wrote data that T1 also wrote." Oracle implements the variant *First-Updater-Wins* (lock at update
time rather than certify at commit time); "the ultimate effect is the same."
**Claim + test.** Claim: *the SUT implements first-committer-wins over the fact-key space, or it
does not implement SI.* Test: two writers, overlapping key sets, both derived from the same name;
assert exactly one succeeds and the other gets a retryable error. If both succeed, the SUT is *below*
SI on the update path (it is closer to Oracle Read Consistency, which "allows general lost updates
(P4)").
**Source.** <https://www.cs.umb.edu/~poneil/ROAnom.pdf> §1; Berenson §4.2, §4.3.
**Applicability.** Single-node now.

##### 3.3.2 SI does not preclude P3 (predicate phantoms in the broad sense)
**What goes wrong.** Berenson: "Snapshot Isolation does not preclude P3." Constraint: a set of job
tasks may not sum to more than 8 hours. T1 reads the predicate, sees 7, adds a 1-hour task; T2
concurrently does the same. "Since the two transactions are inserting different data items (and
different index entries as well, if any), this scenario is not precluded by First-Committer-Wins and
can occur in Snapshot Isolation." Yet SI *does* preclude the strict phantom A3 — "Snapshot Isolation
has no phantoms" in the A3 sense, because each transaction never sees concurrent updates.
**Claim + test.** Claim: *aggregate/predicate constraints are not enforced by the SUT's write path.*
Test: the 8-hour-task test, expressed as two clients each `ask(N, "sum of :duration")` and each
appending a fact. Assert violation, and assert the docs say so.
**Source.** Berenson §4.2, Remark 10.
**Applicability.** Single-node now.

##### 3.3.3 The read-only transaction anomaly (Fekete, O'Neil & O'Neil 2004) — the killer for a read-heavy store
**What goes wrong.** It had been "widely assumed that, under SI, read-only transactions always
execute serializably provided the concurrent update transactions are serializable." That is false.
X = checking = 0, Y = savings = 0, constraint X+Y > 0, penalty of 1 if it goes negative:

```
H3: R2(X0,0) R2(Y0,0) R1(Y0,0) W1(Y1,20) C1 R3(X0,0) R3(Y1,20) C3 W2(X2,-11) C2
```

T3 is *read-only* and prints X = 0, Y = 20, while the final values are Y = 20 and X = −11. "This
can't happen in any serializable execution since if 20 was added to Y before 10 was subtracted from
X, no charge of 1 would ever occur, and the final balance should be 10, not 9." The intuition:
"The fact that SI allows commit order different than serial order is what causes the anomaly." And
critically: "any execution of T1 and T2 (with arbitrary parameter values) without T3 present will
always act serializably" — **the read-only transaction is what makes the history non-serializable.**
**Conditions.** SI; two update transactions that are serializable on their own; one read-only
observer.
**Claim + test.** Claim: *"our anomalies can only come from writers" is false; a read-only `ask` can
be the witness.* Test: implement H3 literally against the SUT with three clients (T1 deposit, T2
conditional withdrawal, T3 read-only report). Assert that T3's printed pair is consistent with the
final state under some serial order. This test **must** be in the suite even though it looks like it
only exercises reads.
**Source.** <https://www.cs.umb.edu/~poneil/ROAnom.pdf> Example 1.3 (Fekete, O'Neil & O'Neil, SIGMOD
Record 2004); commentary at <https://brooker.co.za/blog/2025/02/05/feketes.html> — Brooker's point
is that "my transactions are all read-only so I'm safe" is dangerously false reasoning.
**Applicability.** Single-node now, given first-committer-wins on the write path. If the write path
is a strict single serial transactor with no snapshot-based decision-making, this cannot arise — but
the moment clients compute facts from a held name, it can.

##### 3.3.4 Serializable Snapshot Isolation — the "dangerous structure" and what it costs
**Content.** Cahill/Fekete: a non-serializable SI execution always contains a *pivot* transaction with
two consecutive rw-antidependency edges (T1 →rw T2 →rw T3). PostgreSQL's SSI detects this with SIREAD
locks, escalating granularity (tuple → page → relation) under memory pressure and *summarising*
committed transactions, both of which produce false positives — legitimate serializable histories get
aborted. PostgreSQL's `SERIALIZABLE READ ONLY DEFERRABLE` blocks until a *safe snapshot* is available,
after which the read-only transaction can never be aborted and its results are valid on read; it is
"the only case in which Serializable blocks."
**Claim + test.** Claim: *if the SUT ever adds a serializability guarantee, it detects pivots, not
individual rw edges.* Test: build the three-transaction pivot from Hermitage's Fekete example
(`select *` in T1; T2 `update … where id=2` and commit; T3 `select *` and commit; T1 `update … where
id=1` → must fail) and assert the abort. Also test the *false positive rate* — a serializable
workload must not abort more than a documented budget, or the guarantee is unusable.
**Source.** <https://drkp.net/papers/ssi-vldb12.pdf> (Ports & Grittner, "Serializable Snapshot
Isolation in PostgreSQL", VLDB 2012); Hermitage postgres.md final case;
<https://www.postgresql.org/docs/current/transaction-iso.html>.
**Applicability.** Only if the SUT promises serializability. Worth reading now to decide *not* to.

##### 3.3.5 Real implementations of SSI have shipped serializability bugs — assume yours will
**What goes wrong.** Jepsen found PostgreSQL 12.3 at SERIALIZABLE permitting **G2-item** in normal
operation with no faults. Every observed cycle involved a freshly inserted row; Peter Geoghegan
traced it to the conflict-detection path assigning transaction IDs wrongly when handling concurrent
updates and inserts, so real conflicts were missed. Patched with a regression test.
**Conditions.** New rows created inside a transaction that also participates in a read-write cycle.
**Claim + test.** Claim: *the SUT's isolation tests include the "freshly created entity" case, not
only the "pre-existing entity" case.* Test: every isolation generator must have a variant where the
entity id is created *inside* the transaction under test. This is a cheap generator change that has
historically found real bugs.
**Source.** <https://jepsen.io/analyses/postgresql-12.3>.
**Applicability.** Single-node now (it is a test-design rule).

---

#### 3.4 Isolation is not recency — the orthogonal axis

##### 3.4.1 Serializability places no bound on time
**What goes wrong.** Kingsbury: serializability "places no bounds on time or order" — an operation
"could execute right now, or it could be delayed until the end of time." Legally, under Adya's
formalism, "for every read-only transaction to return an initial, empty state of the database" is
serializable, by ordering all read-only transactions before every write transaction. A store can be
perfectly serializable and answer every read with the empty database.
**Conditions.** Any system that claims "serializable" as its recency story.
**Claim + test.** Claim: *the SUT's recency guarantee is stated separately from its isolation
guarantee.* Test: a real-time monotonicity probe — process P writes and receives name N'; a *different*
process Q then calls `ask(N', q)`; assert Q sees the write. Then the stronger one: Q calls
`ask(head(), q)` after P's write returned; assert Q sees it. If the second fails, the SUT is
serializable-but-not-strict-serializable and must say so.
**Source.** <https://aphyr.com/posts/313-strong-consistency-models>;
<https://jepsen.io/consistency/models/strict-serializable>; Elle §5.1.
**Applicability.** Single-node now. Note the SUT's *name-passing* API makes strict serializability
much easier to achieve than in a distributed store: if `write` returns the name, the client's own
causal chain is explicit. The gap is precisely the *out-of-band* channel — P tells Q "go look" over
a side channel that is not a name.

##### 3.4.2 Linearizability vs serializability vs strict serializability
**Content.** Linearizability = single-object, real-time. Serializability = multi-object, no real-time.
Strict serializability = both; it "treats the entire database as one linearizable object". Elle's
mechanisation: strict-1SR is enforced by adding real-time precedence edges — "if transaction T1
completes before T2 begins, T2 must appear to take effect after T1" — computed as a transitive
reduction in O(n·p).
**Claim + test.** Claim: *the SUT is strict serializable for writes and at-least-monotonic for reads.*
Test: run Elle with `:consistency-models [:strict-serializable]` and real-time edges enabled; the
checker will report cycles that include `rt` edges distinctly from `wr`/`rw` ones (Figure 3 of the
Elle paper shows exactly this labelled output).
**Source.** Elle paper §5.1, <https://arxiv.org/pdf/2003.10554>; Kingsbury as above.
**Applicability.** Single-node now.

##### 3.4.3 Read-your-writes
**What goes wrong.** A client writes, gets `N'`, and a subsequent `ask` does not reflect it. In the
SUT this is only possible if (a) the client asks at an older name — user error the API invites, since
names are plain maps the client holds — or (b) `write` returns before the fact is readable.
**Claim + test.** Claim: *for all facts f and names N, `ask(write(N,[f]), "f?")` returns f, on every
node/process, immediately, with no retry.* Test: tight loop, 10⁶ iterations, across a process
boundary and across an ETS/persistent_term/Mnesia boundary if one exists; assert 0 failures. Then the
adversarial variant: `write` from process A, `ask` from process B on the *same* returned name.
**Source.** Terry, Demers, Petersen, Spreitzer, Theimer & Welch, "Session Guarantees for Weakly
Consistent Replicated Data", PDIS 1994, <https://dl.acm.org/doi/10.5555/645792.668302>;
<https://jepsen.io/consistency/models/read-your-writes>.
**Applicability.** Single-node now (cheap, should be trivially green — a red here is a serious bug).

##### 3.4.4 Monotonic reads
**What goes wrong.** A client sees a fact, then a later read does not. In the SUT this cannot happen
*at a fixed name* by construction, which is exactly the claim under test; it *can* happen across
names if the client advances to a name that is not a descendant.
**Claim + test.** Claim: *names are totally ordered and `ask` is monotone along that order.* Test:
provide and test a `descends?(N1, N2)` predicate; then assert: for every pair of names a client
observes in sequence, the later descends from the earlier, and every fact visible at the earlier is
visible at the later. Fuzz by handing the client hand-constructed names (see §4.2).
**Source.** Terry et al. (Monotonic Reads); <https://jepsen.io/consistency/models/monotonic-reads>.
**Applicability.** Single-node now.

##### 3.4.5 Monotonic writes and writes-follow-reads (causal)
**What goes wrong.** Monotonic writes: a client's second write is applied without its first.
Writes-follow-reads: a write that was *caused by* a read becomes visible somewhere the read's
antecedent is not. Together with the two above these compose to PRAM and then to causal consistency.
**Claim + test.** Claim: *the name a write returns descends from the name it was issued against, and
from every name the writer previously observed.* Test: assert `descends?(returned_name, input_name)`
for every `write` and that the transaction's `provenance` field records the input name, so causality
is checkable offline from the log alone.
**Source.** Terry et al.; <https://aphyr.com/posts/313-strong-consistency-models> (PRAM = monotonic
reads + monotonic writes + read-your-writes; causal = PRAM + writes-follow-reads).
**Applicability.** Single-node now; becomes load-bearing if `watch` ever fans out through a relay.

##### 3.4.6 `watch(name, question)` must be a monotonic, gap-free stream
**What goes wrong.** A websocket that streams answers "as the name advances" is a session guarantee
surface. Failure modes: (a) an answer arrives for a name that does not descend from the previously
delivered one (non-monotonic); (b) a transaction is skipped so a client that reconstructs state from
the stream diverges; (c) after reconnect the client resumes from a name the server has since
garbage-collected; (d) an answer is delivered for a transaction that is later rolled back.
**Claim + test.** Claim: *for every `watch` subscription, the sequence of delivered names is strictly
increasing in the descends-from order, and replaying the stream from any delivered name reproduces
`ask` at the final name exactly.* Test: long-running watch under writer load with injected socket
drops, process kills and reconnects; a shadow client polls `ask` and the two must agree at every
delivered name. Compare-and-diff, not sample.
**Source.** Terry et al. (Monotonic Reads / Writes Follow Reads); Elle §5.1 on per-process
dependencies (`Ti <p Tj`) as a way to strengthen any cycle-detectable model.
**Applicability.** Single-node now.

---

#### 3.5 MVCC-specific hazards that survive being single-node

##### 3.5.1 A long-running reader vs version GC — "snapshot too old"
**What goes wrong.** MVCC systems reclaim versions no live snapshot needs. If the reclamation
criterion is time- or space-based rather than reference-based, a reader holding an old snapshot finds
its versions gone. PostgreSQL's `old_snapshot_threshold` made this explicit: after the threshold
elapsed, "the server will be eligible to vacuum dead tuples, and if a 'long-play' transaction still
needs them, it will get a 'snapshot too old' error." **The important part: PostgreSQL removed the
feature entirely in 17** because "it had a number of known problems in terms of correctness and
performance… We agreed to remove it, after a long period without an active plan to fix it."
**In the SUT this is not an error, it is a lie:** a name that used to answer X must not start
answering "gone", because clients cached X forever and will never re-ask.
**Conditions.** Any index/segment GC, any log truncation, any `:db/noHistory`-style compaction.
**Claim + test.** Claim: *no name ever transitions from answering to erroring.* Test: hold a name for
longer than any GC/compaction interval (force compaction explicitly), then `ask` it. Assert the same
answer, byte-for-byte. Run a second variant where the holder is a *cold* client that constructed the
name by hand and never registered interest — this is the case reference-counting GC cannot see.
**This test is the difference between "immutable" and "immutable while someone is looking".**
**Source.** <https://postgrespro.com/blog/pgsql/5967899> (MVCC in PostgreSQL — Snapshots);
<https://www.dbi-services.com/blog/no-more-snapshot-too-old-in-postgresql-17/>.
**Applicability.** Single-node now. Highest-leverage MVCC item for this design.

##### 3.5.2 Transaction-id assignment order vs commit order — the immutable past changes
**What goes wrong.** The classic MVCC bug: ids are handed out at transaction *start*, visibility is
decided by id, but transactions commit in a different order. A reader takes a snapshot at T; a
transaction with a *lower* id commits afterwards; the reader's "immutable" past now contains a fact
it did not contain before. PostgreSQL's concrete instance: a transaction is marked committed in CLOG
*before* it removes its XID from the proc array, and `TransactionIdIsInProgress()` had a fast path
returning false based on the single-item CLOG cache alone. Result: `ERROR: t_xmin is uncommitted in
tuple to be updated`, or an UPDATE proceeding before the previous UPDATE on the same row was visible.
"This has been broken ever since it was introduced in 2008"; the window is normally tiny but
"synchronous replication makes it much wider, because the wait for synchronous replica happens in
that window." Fixed in commit `e24615a0057a9932904317576cf5c4d42349b363` (2022-06-27).
**Conditions.** Any two-phase "assign id, then publish" scheme; any durability wait between id
assignment and visibility. **An Elixir/OTP transactor that assigns `tx` in one GenServer call and
fsyncs in another has exactly this window.**
**Claim + test.** Claim: *for any name N, the fact set at N is fixed the first time N is observable.*
Test — the decisive one for the whole system: a probe process captures name N at time t and its
answer A; a fuzzer then runs thousands of writes, crashes, restarts, replica promotions; the probe
re-asks N and asserts A. Additionally: assert that the transaction counter is advanced *only* after
durability, or that visibility is gated on a separately-published watermark rather than on
`tx <= N.tx`. Instrument by injecting a sleep between id assignment and fsync and confirming the test
goes red — a test that cannot be made to fail is not testing anything.
**Source.** <https://www.postgresql.org/message-id/E1o5hFk-0020zN-0W@gemulon.postgresql.org>
(PostgreSQL commit "Fix visibility check when XID is committed in CLOG but not in procarray").
**Applicability.** **Single-node now.** This is the mechanism most likely to falsify the central
claim without any distribution involved.

##### 3.5.3 Cross-ledger read skew on one node — a snapshot of *several* ledgers
**What goes wrong.** A snapshot is "one or more ledgers read at a transaction". If each ledger has
its own transaction counter, or if the name captures per-ledger positions gathered at slightly
different moments, then a name is not one instant — it is a *vector* assembled over an interval. A
question spanning ledgers A and B then sees A-after-T and B-before-T: G-single (§3.2.7) with a single
writer, on a single node, with no concurrency bug anywhere in the storage layer. This is the same
shape as Jepsen's G-nonadjacent example and it is a *design* anomaly, not an implementation one.
**Conditions.** Per-ledger transaction numbering, or name construction that reads head positions
sequentially.
**Claim + test.** Claim: *a multi-ledger name is atomic: it corresponds to a single point in one
global order.* Test: writer alternates a paired invariant across ledgers A and B (append `+1` to A
and `−1` to B in one transaction); a reader repeatedly constructs a fresh multi-ledger name and asks
`sum(A) + sum(B)`; assert it is always 0. Run at high write rate. If the SUT has no global counter,
this test fails immediately and the fix is architectural (a single global `tx` for all ledgers, with
per-ledger positions derived from it), not a patch.
**Source.** Definitional, from <https://jepsen.io/consistency/phenomena/g-single> and
<https://jepsen.io/consistency/phenomena/g-nonadjacent>; the multi-object framing is Adya's
(<https://pmg.csail.mit.edu/papers/icde00.pdf>).
**Applicability.** **Single-node now.** Probably the most under-appreciated risk in the design as
described.

##### 3.5.4 Internal consistency — a transaction that fails to observe its own reads and writes
**What goes wrong.** Elle's `:internal` anomaly: "a transaction reads some value of an object which
is incompatible with its own prior reads and writes." Real instance: FaunaDB 2.6.0, `T1: append(0,6),
r(0,nil)` — the transaction did not see its own append. Dgraph: `T1: w(10,2), r(10,1)` — read an
*earlier* value than it wrote. Elle notes these "can be caused by improper isolation, or by
optimistic concurrency control which fails to apply a transaction's writes to its local snapshot."
**Conditions.** Any local-buffer/snapshot merge; any query path that bypasses the in-flight write set.
**Claim + test.** Claim: *within one `write` call, any derived computation sees the pending facts.*
Test: if `write` supports functions/tx-fns that read, assert read-own-writes inside the transaction.
Elle detects this for free from any list-append history — it needs no cycle analysis, so it is the
cheapest check to add and it has found bugs in two real databases.
**Source.** Elle paper §6.1 and §7.3–7.4, <https://arxiv.org/pdf/2003.10554>.
**Applicability.** Single-node now.

##### 3.5.5 Dirty update, garbage read, duplicate write
**What goes wrong.** Three phenomena Adya's formalism does not admit but Elle checks because they
show up in real systems. **Dirty update:** "a history exhibits dirty update if it contains an
uncommitted transaction T1 which writes xi, and a committed transaction T2 which contains a write
acting on xi" — an aborted write is promoted into committed state by a later writer building on it.
**Garbage read:** "a read observes a value which was never written" — arises from "client, network,
or database corruption, errors in serialization or deserialization." **Duplicate write:** "the trace
of a committed read version contains a write of the same argument multiple times" — arises when "a
client or database retries an append operation," and with registers it manifests as G1c or G2 instead.
**Conditions.** Retries at any layer; any serialization boundary (ETF/`term_to_binary`, JSON,
protobuf); crash-restart with replay.
**Claim + test.** Claim: *(a) an aborted transaction's facts are never built upon; (b) `ask` never
returns a value not present in the log; (c) an idempotent retry of `write` does not double-append.*
Test: list-append workload with client-side retries enabled and forced timeouts on `write`; assert
`:dirty-update`, `:garbage-read`, `:duplicate-elements` all absent. **The retry case is very likely
live in the SUT**, because a websocket/GenServer timeout on `write` is indistinguishable from a
failure and the natural client behaviour is to retry.
**Source.** Elle paper §4.1.5 and §6.1; <https://github.com/jepsen-io/elle>.
**Applicability.** Single-node now.

##### 3.5.6 Read Committed re-evaluates the predicate against the *new* row — a documented anomaly
**What goes wrong.** PostgreSQL documents that in Read Committed, when an UPDATE/DELETE hits a
concurrently-updated row, "the search condition of the command (the WHERE clause) is re-evaluated to
see if the updated version of the row still matches." The result: `UPDATE website SET hits = hits+1`
concurrent with `DELETE FROM website WHERE hits = 10` deletes nothing, "even though a `hits = 10` row
existed both before and after the UPDATE." This is an anomaly with no name in the ANSI or Adya
taxonomies; it is a consequence of a specific implementation choice.
**Conditions.** Conditional writes evaluated against a moving target.
**Claim + test.** Claim: *if the SUT ever adds conditional/predicated writes, the predicate is
evaluated exactly once, at the name the client supplied.* Test: the `hits = 10` schedule verbatim.
**Source.** <https://www.postgresql.org/docs/current/transaction-iso.html> §13.2.1.
**Applicability.** Only if conditional writes exist. Worth recording as a design constraint now.

##### 3.5.7 Side effects that escape the log (sequences, ids, counters)
**What goes wrong.** PostgreSQL: "changes made to a sequence (and therefore the counter of a column
declared using serial) are immediately visible to all other transactions and are not rolled back if
the transaction that made the changes aborts." Any allocator outside the transactional log breaks the
"a name determines everything" claim: the same name plus a re-run yields different ids.
**Conditions.** Entity-id allocation, tempid resolution, sequence attributes, `make_ref()`,
`System.unique_integer()`.
**Claim + test.** Claim: *every id observable in a fact is a deterministic function of the
transaction and its content.* Test: replay the log from empty into a fresh instance and assert
byte-identical fact sets and identical names at every transaction. A replay that produces different
ids means names are not reproducible and backup/restore (§4.1) will produce colliding names.
**Source.** <https://www.postgresql.org/docs/current/transaction-iso.html> (Serializable section
caveat).
**Applicability.** Single-node now.

---

#### 3.6 How these are actually detected

##### 3.6.1 Elle: infer an Adya DSG from black-box observations
**What it is.** Elle "infers an Adya-style dependency graph between client-observed transactions" by
"carefully selecting database objects and operations when generating workloads, so as to ensure that
the results of database reads reveal information about their version history." It is *sound*
(Theorem 1: given a trace-recoverable observation, anything Elle reports is present in every clean
interpretation) and near-complete. It is **linear in history length and effectively constant in
concurrency** — it handled "hundreds of thousands of transactions in tens of seconds" where Knossos
(linearizability) "timed out or ran out of memory after a few hundred transactions."
**Claim + test.** Claim: *the SUT's isolation is verified by a sound checker over generated
histories, not by hand-written scenario tests.* Test: adopt `jepsen.io/elle` directly; it runs against
any store that can express append-to-list. Scenario tests (Hermitage-style) are the *regression* layer;
Elle is the *discovery* layer. Both are needed and they find different things.
**Source.** <https://arxiv.org/pdf/2003.10554>; <https://github.com/jepsen-io/elle>.
**Applicability.** Single-node now.

##### 3.6.2 Why list-append is Elle's preferred datatype: traceability + recoverability
**What it is.** Two properties. **Recoverability:** "every version we observe can be mapped to a
specific write in some observed transaction" — obtained by making every written value unique.
**Traceability:** for a list, "a write to x append[s] a unique value to x. Then any read of xi tells
us the order of all versions written prior: `xi = [1,2,3]` implies that x took on the versions [],
[1], [1,2], and [1,2,3] in exactly that order." Registers destroy history ("in a sense, blind writes
*destroy history*"); counters are non-recoverable ("we can't tell which increment produced a
particular value"); sets are recoverable but only partially traceable because "sets are order-free."
Lists give both, which is what lets Elle recover the version order `≪` and hence ww and rw edges,
not just wr.
**Claim + test.** Claim: *the SUT's test workload uses append-only lists keyed by unique values, not
counters or registers.* Test/design rule: the generator must (1) make every appended argument
distinct, (2) read whole lists, (3) mix 1–10 ops per transaction across ~10–100 keys, (4) do many
writes per key. **This is a direct fit for a fact log** — a `(id, attribute, answer)` where answer
accumulates is already a list-append object, so the SUT is unusually well suited to Elle's strongest
inference mode. Do not weaken it by testing only "latest value" reads.
**Source.** Elle paper §3, §4.1.6, §4.2.3, <https://arxiv.org/pdf/2003.10554>.
**Applicability.** Single-node now. **Highest-leverage methodology finding in this section.**

##### 3.6.3 Elle's cycle-finding mechanics — what the harness must implement
**What it is.** Union the dependency graphs (ww, wr, rw) with optional process, real-time and version
edges; run Tarjan's SCC; then BFS within each component for a *short* cycle. Restrict edge sets to
target specific anomalies: G0 = ww only; G1c = ww ∪ wr; G2 = any cycle with ≥1 rw. "G-single is
trickier, because it requires exactly one read-write edge. We partition the dependency graph into two
subgraphs: one with, and one without read-write edges. We find strongly connected components in the
full graph, but for finding a cycle, we begin with a node in the read-write subgraph, follow exactly
one read-write edge, then attempt to complete the cycle using only write-write and write-read edges."
Output is a short human-readable witness (Elle's Figure 2/3 style).
**Claim + test.** Claim: *the checker reports a minimal witness, not "a violation occurred".* Test:
inject a known cycle and assert the witness names the exact transactions and edge labels.
**Source.** Elle paper §6, <https://arxiv.org/pdf/2003.10554>.
**Applicability.** Single-node now.

##### 3.6.4 Hermitage: the scenario layer, and the reason it exists
**What it is.** A hand-run suite of interleavings covering G0, G1a, G1b, G1c, OTV, PMP, P4, G-single,
G2-item, G2, with per-database result tables. Key empirical results: "PostgreSQL, MySQL and MS SQL
Server all boast an isolation level called 'repeatable read', but it means something different in
every one of them"; "Oracle 'serializable' is actually not serializable at all, but snapshot
isolation"; several vendors' "read committed" is really *monotonic atomic view*. Kleppmann's caveat
is worth quoting for the SUT's own suite: "any concurrency issues that depend on fast timings will
not be found. However, it's remarkable that even at the slow speed of a human, you can still easily
demonstrate concurrency issues. It's not the speed that matters, it's the ordering of events."
**Claim + test.** Claim: *the SUT has a Hermitage-shaped table asserting, per anomaly, prevented or
not.* Test: port the ten test cases; the deliverable is the table, committed, with a CI job that
fails if a cell flips. The full PostgreSQL schedules are at
<https://github.com/ept/hermitage/blob/master/postgres.md> and translate mechanically to
`write`/`ask`.
**Source.** <https://github.com/ept/hermitage>;
<https://martin.kleppmann.com/2014/11/25/hermitage-testing-the-i-in-acid.html>.
**Applicability.** Single-node now.

##### 3.6.5 Most databases do not default to what they claim — measure, don't read the docs
**What it is.** Bailis's survey of 18 databases: only 3 default to serializability and only 9 offer
it at all; MySQL, PostgreSQL and Oracle 11g default to read-committed-or-weaker. The general lesson
for a claims-based framework: the vendor's own name for its level is the least reliable input.
**Claim + test.** Claim: *every guarantee in the SUT's README has a corresponding failing-when-broken
test, by name.* Test: a lint that cross-references guarantee statements to test ids. (This mirrors
the repo's own `onto-scan` discipline: a claim with no test is drift.)
**Source.** <http://www.bailis.org/blog/when-is-acid-acid-rarely/>.
**Applicability.** Single-node now.

---

### Topic 4 — Caching and invalidation claims

The central claim under test: **`{name, question} -> answer` is a total, immutable function, forever.**
Everything below is a way that function turns out to be partial, or non-immutable, or not a function.

Grouped by the *kind* of falsifier: identity (§4.1–4.3), durability (§4.4–4.6), erasure (§4.7–4.8),
purity (§4.9–4.14), and cache mechanics (§4.15–4.22).

#### 4.1 Name reuse after restore or rollback — the same name denoting two histories
**What goes wrong.** Restore from backup to transaction 900, then accept new writes. Transactions
901..1000 are re-issued with the *same* numbers and different content. Every client cache holding
`{name@950, q}` now returns answers from the abandoned timeline. Nothing detects this: the name is
well-formed, the store answers confidently, and there is no invalidation channel by design. Datomic
sidesteps this by making excision "irrevocable" and by making restore an operational break; the SUT's
hand-constructible name makes it much easier to hit.
**Conditions.** Any restore-to-point-in-time, any rollback, any log truncation followed by new writes,
any "reset the dev database" that shares a cache with anything.
**Claim + test.** Claim: *a name is globally unique across all histories the store has ever had.*
Test: write to tx 1000; snapshot the answer at a name; restore to 900; write different facts; ask the
same name; assert either the identical original answer, or a hard error naming the epoch mismatch —
never a different answer. **Fix shape:** include a *database epoch / instance UUID* in the name and
bump it on every restore, so a stale name fails closed. Assert the epoch is in the name's map and is
covered by the cache key.
**Source.** <https://docs.datomic.com/operation/excision.html> ("Excision is irrevocable… unrecoverable,
short of restoring a backup"); the general cache-key lesson at
<https://portswigger.net/research/practical-web-cache-poisoning>.
**Applicability.** Single-node now. **Top-three risk.**

#### 4.2 A client-constructible name can name a transaction that does not exist yet
**What goes wrong.** The name is "a plain map the client holds and can construct by hand." A client
constructs `%{tx: 5000}` when head is 900. Options: (a) the store errors — then the name space is not
total and the client must handle it, which is fine but must be specified; (b) the store answers with
what it has — then when tx 5000 actually arrives, the *same name answers differently*, which
falsifies the central claim outright; (c) the store blocks — a liveness hazard and a DoS vector.
Elle names the read-side version of this: a `:future-read`.
**Conditions.** Any hand-constructed or arithmetically-derived name; any client that does `tx + 1`
to "wait for the next one."
**Claim + test.** Claim: *`ask` at a not-yet-existing name is an error, and the error is stable — the
same name errors forever, or answers forever, never both.* Test: ask at `head+k` for k in 1..1000;
record the outcomes; advance the log past them; re-ask; assert every outcome is unchanged. If option
(a), assert the error is *sticky* — i.e. it is recorded that this name was refused, or (better) the
error is never cacheable and clients are told so explicitly (see §4.18 negative caching).
**Source.** Elle's `:future-read` anomaly, <https://github.com/jepsen-io/elle>; Adya's history
constraint "One cannot read from the future: if a read r(xi) is in E, then there must exist a write
w → (xi) which precedes it" (<https://arxiv.org/pdf/2003.10554> §4.1.3).
**Applicability.** **Single-node now.** This is a direct consequence of the API shape and should be
the first test written.

#### 4.3 A name for a transaction that was attempted and rolled back
**What goes wrong.** Distinct from §4.2: tx 950 was *allocated* and then failed. If names are
allocated before durability (§3.5.2), a client that observed the in-flight name caches an answer for
a transaction that never committed. This is G1a with an unbounded blast radius.
**Conditions.** Id-before-durability; any client that learns a name from a `watch` frame emitted
optimistically.
**Claim + test.** Claim: *a name is only ever emitted to a client after the transaction it names is
durable.* Test: crash the transactor between "append accepted" and "fsync returned" (inject via a
`:sys.replace_state` hook or a controlled `:erlang.halt/1`); on restart, assert no name previously
returned by `write` or delivered by `watch` is missing, and no name for the failed transaction was
ever emitted. Instrument both directions — emitted-but-lost *and* lost-but-emitted.
**Source.** Adya G1a; the PostgreSQL CLOG/procarray window,
<https://www.postgresql.org/message-id/E1o5hFk-0020zN-0W@gemulon.postgresql.org>.
**Applicability.** Single-node now.

#### 4.4 The torn / truncated tail — the same name answers differently across a restart
**What goes wrong.** **This is the killer case and it deserves the most test budget.** A transaction
is appended and made visible; the process crashes before the tail is durable; on restart the log
recovery truncates the partial record; the transaction is gone. A client that read at that name
before the crash holds a cached answer that the store now contradicts. The name has answered two
different things — the central claim is falsified by a single ordinary power cut.
RocksDB makes the trade-off explicit in four named modes:
- `kTolerateCorruptedTailRecords` — "The WAL replay ignores any error discovered at the tail of the
  log", because "on unclean shutdown there can be incomplete writes at the tail of the log"; it is a
  *heuristic* — "the system cannot differentiate between corruption at the tail of the log and
  incomplete write." This mode silently loses committed data.
- `kAbsoluteConsistency` — "Any IO error during WAL replay is considered as data corruption"; fails
  closed.
- `kPointInTimeRecovery` — replay stops at the first error and recovers to a consistent prior point;
  **the default since 6.6**, precisely because of the correctness concerns with the tolerant mode.
- `kSkipAnyCorruptedRecords` — best-effort, may resurrect or drop arbitrary records.
Notably, RocksDB found that WAL *recycling* interacts badly with the tolerant mode: recovery cannot
distinguish "end of new data" from real corruption, so "committed updates [are] truncated — a
violation of the recovery guarantee."
**Conditions.** Any append-only file, any `:disk_log`, any custom framing. Sector-atomicity is not
record-atomicity: a 4 KiB sector can be half-written.
**Claim + test.** Claim: *for every name N ever emitted to any client, and for every crash at any
point, `ask(N, q)` after restart equals `ask(N, q)` before.* Test — the flagship test of the whole
suite:
1. A recorder process continuously `ask`s at every name it is handed and journals `{name, question,
   answer_hash}` to a *separate* device.
2. A writer loop appends under load.
3. `:erlang.halt(1)` (not a clean stop — must skip `terminate/2` and OS buffers) at randomised
   points, ideally with `dm-flakey` / a fault-injecting FUSE layer, or at minimum with `O_DIRECT`
   disabled and page cache dropped.
4. On restart, replay the recorder journal and assert every `{name, question}` still yields the same
   `answer_hash`.
Run thousands of iterations. **Assert the property, not "no data loss":** losing the tail is
acceptable *if and only if* no name from the lost tail ever escaped. So the real invariant is
**emission is gated on durability** — a name may only leave the process after fsync returns. Test
that directly by instrumenting the fsync boundary.
**Source.** <https://github.com/facebook/rocksdb/wiki/WAL-Recovery-Modes>;
<https://github.com/facebook/rocksdb/pull/6351> (recycling vs tolerant-tail data loss).
**Applicability.** **Single-node now. The single highest-leverage item in this document.**

#### 4.5 fsync can fail, and the failure can be reported once and then forgotten
**What goes wrong.** A failed `fsync` may mark the dirty pages clean, so a *retry* of fsync returns
success while the data was never written. PostgreSQL's "fsyncgate" (2018) is the canonical write-up;
the general result is that applications frequently mishandle fsync failure and lose data believing it
durable. For the SUT this converts §4.4 from "rare crash" into "ordinary I/O error."
**Conditions.** Any Linux filesystem; thin-provisioned or network storage makes it likely rather than
theoretical.
**Claim + test.** Claim: *an fsync error causes the transactor to stop and refuse to emit further
names, rather than retry.* Test: inject EIO on fsync (device-mapper `dm-error`, or an LD_PRELOAD
shim); assert the process crashes or enters a refusing state, and assert no name issued after the
first EIO is ever served. A retry-and-continue path here is a correctness bug, not a robustness
feature.
**Source.** PostgreSQL fsync reliability discussion, <https://wiki.postgresql.org/wiki/Fsync_Errors>;
Rebello et al., "Can Applications Recover from fsync Failures?" USENIX ATC 2020,
<https://www.usenix.org/conference/atc20/presentation/rebello>.
**Applicability.** Single-node now.

#### 4.6 Emission-before-durability in the `watch` path specifically
**What goes wrong.** `watch` is designed to push names as they advance, which creates pressure to
emit early for latency. If a `watch` frame carries a name before fsync, §4.4 applies with the added
twist that the client may have already computed and *persisted* something from it.
**Claim + test.** Claim: *`watch` never delivers a name earlier than `write` would return it.* Test:
a watcher and a writer on the same node; log `(name, monotonic_time)` at both the watch-frame
delivery and the `write` return, plus at the fsync return; assert `fsync_return_time <=
watch_delivery_time` for every name.
**Source.** Same as §4.4/§4.5; the ordering-vs-durability framing is the CLOG/procarray one,
<https://www.postgresql.org/message-id/E1o5hFk-0020zN-0W@gemulon.postgresql.org>.
**Applicability.** Single-node now.

#### 4.7 Erasure / GDPR deletion changes what an old name answers
**What goes wrong.** An immutable log plus a right to erasure is a contradiction that must be
resolved somewhere. Datomic resolves it with *excision*, "a special operation that happens outside
the timeline of Datomic history, removing data across all of history as if the data never happened."
An old name that used to answer "Alice, alice@example.com" now answers something else. **Every cached
answer keyed by an old name is now both stale and a compliance liability**, and by design there is no
way to tell clients to drop it.
Datomic's own caveats: excision cannot touch schema datoms or bootstrap datoms; it cannot excise
fulltext attributes; removal of `:db/noHistory` attributes from indexes and logs "cannot be fully
guaranteed"; it "does not affect the memory database"; and it is "irrevocable."
**Conditions.** Any erasure requirement — which, for a multi-tenant product, is not optional.
**Claim + test.** Claim: pick one and test it:
(a) *Erasure is out of scope; the SUT is not lawful for personal data* — test: a documented,
CI-asserted statement, plus a schema-level annotation that refuses personal-data attributes.
(b) *Erasure exists and every client cache is provably purged* — test: erase a fact; assert every
name that ever exposed it now errors (not "answers differently"); assert the client SDK's cache is
keyed such that the erase invalidates it. This requires an invalidation channel, i.e. it *falsifies
the "no cache-coherence protocol" claim* for this one case.
(c) **Crypto-shredding** — store personal data encrypted per subject and destroy the key. The name
still answers the same ciphertext forever; only decryptability changes. This is the only option that
preserves the central claim, and it is what practitioners actually recommend for Datomic.
Test for (c): assert all personal-data attributes are stored as ciphertext with a per-subject key id
in provenance, and that a key destruction leaves every name's *fact set* byte-identical.
**Source.** <https://docs.datomic.com/operation/excision.html>;
<https://vvvvalvalval.github.io/posts/2018-05-01-making-a-datomic-system-gdpr-compliant.html>;
<https://medium.com/magnetcoop/gdpr-right-to-be-forgotten-vs-datomic-3d0413caf102>.
**Applicability.** **Single-node now.** This is the item most likely to force an architecture change
if deferred.

#### 4.8 Erasure is asynchronous — a window where the same name answers both ways
**What goes wrong.** Datomic: "the effect of excision is a background operation that occurs during
the first indexing job after an excision transaction," and "large excisions can trigger indexing jobs
whose execution time is proportional to the size of the entire database, leading to back pressure and
reduced write availability." So there is a period during which some readers see the excised data and
some do not — at the *same name*.
**Conditions.** Any background reindex/compaction that changes visible content.
**Claim + test.** Claim: *no background job changes the answer at any name; erasure is either atomic
at a transaction or it is a new epoch (§4.1).* Test: begin an erasure; hammer `ask` at a fixed old
name from many processes throughout the reindex; assert every process sees the same answer at every
moment (all-old, then a discontinuity that is an *epoch change*, not a silent content change).
**Source.** <https://docs.datomic.com/operation/excision.html>.
**Applicability.** Single-node now.

#### 4.9 A formula's output changes because its *code* changed and the name did not
**What goes wrong.** Formulas are "cacheable BY SNAPSHOT NAME." A cache key of `{name, question}`
omits the *identity of the code that computed the answer*. Deploy a bug fix to a formula and every
client keeps the old answer forever; deploy it and warm a new node, and two nodes now serve different
answers for the same key. This is exactly the "unkeyed input" failure from web cache poisoning: "any
difference in the response triggered by an unkeyed input may be stored and served to other users."
Build systems solved this long ago — Bazel/Nix cache keys hash the *action* including the toolchain,
not just the inputs.
**Conditions.** Any deploy, any hot code load (and Elixir/OTP makes hot code load *easy*, which makes
this *more* likely here than in a typical stack), any dependency bump that changes a library used
inside a formula.
**Claim + test.** Claim: *the cache key is `{name, question, formula_code_digest}`, where the digest
covers the formula source, its transitive dependencies, and the runtime version.* Test:
1. Compute an answer; record the cache key.
2. Change one character in the formula body; recompute; assert the cache key changed.
3. Change a transitively-called module; assert the key changed.
4. Bump the OTP/Elixir version; assert the key changed (or assert a documented decision that it need
   not, with a determinism test backing it — see §4.12).
5. Adversarial: two formulas with the same name and different bodies must never share a key.
**Source.** <https://portswigger.net/research/practical-web-cache-poisoning> (unkeyed inputs);
<https://reproducible-builds.org/docs/> (build inputs that must be pinned).
**Applicability.** **Single-node now. Top-three risk** — and it is cheap to fix *before* any cache
is deployed and expensive after.

#### 4.10 Formula reads the clock
**What goes wrong.** `DateTime.utc_now()`, `System.monotonic_time()`, `:os.timestamp()`, or a
relative date in a query ("facts from the last 7 days") makes the formula a function of wall time.
The first client to ask pins an answer for eternity.
**Conditions.** Any reporting/aggregation formula. Extremely common.
**Claim + test.** Claim: *formulas are pure functions of the snapshot.* Test — static: forbid the
clock modules inside formula code via a compile-time check (an AST walk in a `@before_compile` hook,
or a Credo/dialyzer rule) and fail the build. Test — dynamic: evaluate every formula twice with the
system clock advanced by a year between runs (`libfaketime`, or a mocked time module); assert
byte-identical output. Any "now" a formula needs must be an *explicit argument* that is part of the
question, hence part of the cache key.
**Source.** <https://reproducible-builds.org/docs/> ("Timestamps"; the SOURCE_DATE_EPOCH pattern is
the standard fix — pass time in, don't read it).
**Applicability.** Single-node now.

#### 4.11 Formula reads the pid / node / host
**What goes wrong.** `self()`, `node()`, `make_ref()`, `:erlang.unique_integer()`,
`System.get_env/1`, hostname — all vary per process/node and none are in the cache key. Output that
embeds a pid is not just non-deterministic, it is non-comparable, so a "did two nodes agree?" test
silently passes because nothing ever compares them.
**Conditions.** Debug fields, correlation ids, "computed by" provenance stamps.
**Claim + test.** Claim: *a formula evaluated on two nodes at the same name produces byte-identical
output.* Test: run every formula on ≥2 BEAM nodes and ≥2 OS processes; hash and compare. Also run
under a different `node()` name and a different `$HOSTNAME`. Static test: forbid `self/0`,
`make_ref/0`, `node/0`, `:erlang.unique_integer/0,1`, `System.get_env/1` inside formula modules.
**Source.** <https://reproducible-builds.org/docs/> (environment variables, randomness, build paths).
**Applicability.** Single-node now (a single node still has many processes).

#### 4.12 Formula depends on map iteration order — the Erlang 32-element cliff
**What goes wrong.** **This one is specific to the SUT's runtime and is easy to ship by accident.**
Erlang maps have two representations: "a map with at most 32 elements has a compact representation"
(a *flatmap*, whose "keys are sorted"), and maps with 33+ elements use a Hash Array Mapped Trie. So
`maps.to_list/1` on a small map appears sorted, and on a large map "the order of elements returned
appears arbitrary." A formula that folds over a map and concatenates, or that emits JSON from a map,
therefore produces one output for a 32-key map and a *differently ordered* output for a 33-key map —
and the boundary is data-dependent, so it will pass every small test and fail in production. Worse,
OTP does not guarantee that different iteration routes agree: the reported issue is that
`maps:to_list(Map) =:= maps:to_list(maps:iterator(Map))` "does not hold", and the desired invariant
(all iteration routes agree) is stated as a *wish*, not a guarantee. The docs' own advice is
prescriptive: "If the resulting list needs to be ordered, use `lists:sort/1` to sort the result."
**Conditions.** Any formula that iterates a map with more than 32 keys — entity attribute maps,
group-by results, per-tenant rollups.
**Claim + test.** Claim: *no formula's output depends on map iteration order.* Test:
1. Property test every formula at map sizes 30, 31, 32, 33, 34, 64, 1000 — assert output is
   invariant under key *insertion order* (build the same logical map by inserting keys in shuffled
   orders and assert identical output). The 32/33 boundary must be an explicit fixture.
2. Static: ban `Map.to_list/1`, `Enum.map` over a map, `:maps.to_list/1`, `:maps.keys/1`, `for {k,v}
   <- map` inside formula code unless immediately followed by a sort — or, better, provide the only
   sanctioned iteration helper and ban the rest.
3. Run the suite on ≥2 OTP minor versions and assert identical output, since the internal order is
   explicitly unspecified and has changed.
**Source.** <https://www.erlang.org/doc/system/maps.html>;
<https://github.com/erlang/otp/issues/7851> ("maps:to_list order differs from iterator order").
**Applicability.** **Single-node now. Top-three risk, and the most SUT-specific finding in this
document.**

#### 4.13 Formula formats floats
**What goes wrong.** Float-to-string is a notorious determinism boundary: shortest-round-trip vs
fixed precision, `-0.0` vs `0.0`, NaN payloads, locale decimal separators, and cross-version changes
in the formatter. Two nodes agreeing on the *value* can disagree on the *bytes*, which is what a
content-addressed cache key hashes.
**Conditions.** Any aggregate producing a ratio or average; any JSON encoding of a float.
**Claim + test.** Claim: *formula output contains no floats, or float rendering is pinned to an
explicit, tested format.* Test: property test round-tripping the full float space through the
formula's serializer and asserting byte-stability across OTP versions and locales (`LC_ALL=tr_TR.UTF-8`
is the classic trap). Preferred fix: use integers/decimals in the fact log and in formula output, and
assert statically that no float ever reaches the serializer.
**Source.** <https://reproducible-builds.org/docs/> (locale; stripping unreproducible information).
**Applicability.** Single-node now.

#### 4.14 Formula non-determinism from serialization, hashing and concurrency
**What goes wrong.** Four more sources, each of which has bitten reproducible-build efforts:
(a) **`term_to_binary` version drift** — the external term format has version-dependent encodings;
    hashing a term's ETF bytes is not stable across OTP versions unless `[minor_version: N]` is pinned.
(b) **Hash seeds** — `:erlang.phash2/1` is stable, but `:erlang.hash`, sets/dicts backed by
    randomised hashing, and anything from `:rand` without an explicit seed are not.
(c) **Parallelism** — a formula that uses `Task.async_stream` with `ordered: false`, or reduces over
    results in completion order, is order-non-deterministic by construction.
(d) **Uninitialized/ambient data** — NIF buffers, binary padding, and struct fields defaulted from
    the environment.
**Conditions.** Any of the above inside a formula or its serializer.
**Claim + test.** Claim: *a formula's output is byte-identical across 100 repetitions on one node,
across nodes, across OTP versions, and under `ordered: false` scheduling jitter.* Test: an N-times
determinism harness that is *mandatory* for every registered formula — a formula cannot be registered
until it has passed it. Make it part of the registration API, not a separate CI job, so it cannot be
skipped. Run one arm with `+S 1` and one with `+S 16` to shake out (c).
**Source.** <https://reproducible-builds.org/docs/> (randomness, parallelism, uninitialized memory,
version information).
**Applicability.** Single-node now.

#### 4.15 Cache stampede / thundering herd on a cold name
**What goes wrong.** "When a frequently-accessed cache item expires, multiple requests to that item
can trigger a cache miss and start regenerating that same item at the same time." In the SUT the
trigger is not expiry (there is none) but *novelty*: every advance of the name produces a brand-new
key, so a popular question is recomputed by every client simultaneously the instant the name moves.
**A never-invalidating cache does not avoid stampede — it converts a periodic stampede into one
stampede per write.** With `watch` fanning out the new name to every subscriber at once, the herd is
perfectly synchronised, which is the worst case.
**Conditions.** Hot question + high write rate + `watch` fan-out. Guaranteed by design.
**Claim + test.** Claim: *for a hot `{name, question}`, at most one computation is in flight per node
and the fan-out does not multiply load by subscriber count.* Test: 1000 watchers on one question;
one write; count formula invocations. Assert ≤ number_of_nodes. Fixes: single-flight/request
coalescing per key; probabilistic early recomputation on the *predicted next* name (the XFetch idea
adapted — recompute speculatively before the name advances); staggered `watch` delivery.
**Source.** <http://www.vldb.org/pvldb/vol8/p886-vattani.pdf> (Vattani, Chierichetti & Lowenstein,
"Optimal Probabilistic Cache Stampede Prevention", VLDB 2015).
**Applicability.** Single-node now; worsens with every added client.

#### 4.16 Unbounded cache growth — immutable keys are never *wrong*, so they are never evicted
**What goes wrong.** The claim "never invalidate" is often silently read as "never evict." Every write
mints a new name, so the key space grows monotonically at the write rate times the question
cardinality. Memory grows without bound; the process dies; the "cache" was load-bearing (§4.19) and
the system is down. Datomic is explicit that "Datomic caches only immutable data, so all caches are
valid forever" — but it still uses a *bounded LRU* object cache and a bounded memcached tier. Valid
forever ≠ retained forever, and the design must state which.
**Conditions.** Any long-running client process (a LiveView, a GenServer, an ETS table) that memoizes.
**Claim + test.** Claim: *cache memory is bounded and eviction is safe (a miss is always
recomputable).* Test: (1) a soak test — 24 h of writes with a fixed question set; assert RSS and ETS
table size plateau. (2) An eviction-safety test — evict 100% of the cache at a random moment under
load and assert every answer is unchanged and every client still makes progress. (3) Assert that no
code path treats cache presence as semantically meaningful (see §4.19).
**Source.** <https://docs.datomic.com/operation/caching.html> (object cache is "an LRU Java cache";
memcached is an optional intermediate tier; "Datomic caches only immutable data, so all caches are
valid forever").
**Applicability.** Single-node now.

#### 4.17 Cross-tenant cache key collision
**What goes wrong.** If the name does not include the tenant/studio, or the question does not, then
two tenants asking "revenue?" at structurally equal names share a cache entry. This is the
unkeyed-input failure in its most damaging form: "one visitor's response gets served to another."
The SUT is unusually exposed because names are *client-supplied maps* — a client can present another
tenant's name, and if authorisation is checked at the edge but the cache key is computed from the
name alone, a cached cross-tenant answer is servable.
Note also the repo's own doctrine cuts the other way: "The Graph is infrastructure; the Atlas is the
tenant's" — a shared cache that is correct for infrastructure data is a leak for tenant data.
**Conditions.** Multi-tenant + shared cache + authorisation not in the key.
**Claim + test.** Claim: *the cache key covers tenant identity and the full authorisation context.*
Test: (1) two tenants with byte-identical data and identical questions; assert their cache keys
differ. (2) Adversarial: tenant A presents tenant B's name; assert refusal *before* any cache lookup,
and assert the attempt does not populate or read A's cache. (3) A key-derivation property test: no
two distinct `(tenant, name, question, authz)` tuples produce the same key (collision test over
millions of random tuples). (4) Assert answers are filtered by provenance/authz *before* caching,
never after — a post-filter on a shared cached answer is the classic leak.
**Source.** <https://portswigger.net/research/practical-web-cache-poisoning>;
<https://kwill.dev/posts/datomic-cloud-multi-tenancy/> (Datomic Cloud multi-tenancy constraints).
**Applicability.** **Single-node now. Top-three risk** (security, not just correctness).

#### 4.18 Negative caching — "not found" and "not yet" are different, and only one is immutable
**What goes wrong.** Three negative answers with three different lifetimes: "no such entity at this
name" (immutable — cache forever), "name is in the future" (mutable — must never be cached, §4.2),
"error/timeout" (says nothing about the data — must never be cached). Conflating them means either
poisoning the cache with a transient failure, or refusing to cache legitimate empty results and
losing the main performance benefit. DNS learned this: RFC 2308 gives negative answers their own TTL
derived from the SOA record precisely because the natural TTL is wrong.
**Conditions.** Any client cache that stores whatever `ask` returned.
**Claim + test.** Claim: *`ask` returns a three-way-distinguishable result and the client SDK caches
exactly one of the three.* Test: force each of the three conditions; assert the returned term is
structurally distinct (`{:ok, answer}` / `{:error, :future_name}` / `{:error, :unavailable}`); assert
the SDK caches only the first; assert a transient error followed by success does not serve the error.
**Source.** RFC 2308, "Negative Caching of DNS Queries (DNS NCACHE)",
<https://www.rfc-editor.org/rfc/rfc2308>.
**Applicability.** Single-node now.

#### 4.19 Cache as a source of truth
**What goes wrong.** Because the cache never invalidates, it becomes indistinguishable from the store,
and code starts *depending* on presence: "if it's cached the write landed", "if it's not cached, it
doesn't exist." Then eviction, restart, or a cold node changes behaviour rather than latency. This is
the failure mode a never-invalidating cache invites most strongly, precisely because it is correct
almost all of the time.
**Conditions.** Any read path that branches on cache hit vs miss.
**Claim + test.** Claim: *the system's observable behaviour is invariant under total cache loss.*
Test: a chaos arm that drops the entire cache (and, separately, drops a random 10%) every N seconds
during the full functional test suite; assert zero test failures and zero behavioural differences
beyond latency. Additionally: run the whole suite with the cache *disabled* and assert identical
results. If the two runs differ, the cache is load-bearing.
**Source.** <https://engineering.fb.com/2022/06/08/core-infra/cache-made-consistent/> (Meta's framing
of cache as an invariant-bearing component that must be *measured*, not assumed).
**Applicability.** Single-node now.

#### 4.20 The fill-vs-invalidate race — the bug the design claims to have eliminated, and where it hides
**What goes wrong.** Meta's canonical bug: a cache fill races an invalidation; the fill's older value
lands after the invalidation is processed, and the stale entry persists *indefinitely*. Concretely,
"if a cache receives x=42 from a database fill after processing an invalidation for x=43, the older
value persists despite the database containing newer data." The SUT's design genuinely does eliminate
this for `{name, question}` — a fill for an immutable key can never be stale. **But it re-appears at
every derived key that is not named by a snapshot:** a "latest name" pointer, a `head()` cache, a
per-tenant "current name" in ETS, an index from a business key to a name. Those are mutable and they
have all the classic races.
**Conditions.** Any mutable pointer alongside the immutable store — and there is always at least one,
because clients need to *find* the current name.
**Claim + test.** Claim: *enumerate every mutable key in the system; there must be a short, closed
list, and each entry must have a stated coherence protocol.* Test: an inventory test — a lint that
fails if any cache/ETS/persistent_term key is not either (a) derived from a name or (b) on the
declared mutable list with a named protocol. Then, for each mutable key, a fill/invalidate race test:
concurrent fill and update with injected delays on the fill path, asserting the final state is the
newer value. The "no cache-coherence protocol" claim is true only for (a) and the test suite must
make the boundary explicit.
**Source.** <https://engineering.fb.com/2022/06/08/core-infra/cache-made-consistent/>;
<https://uvdn7.github.io/cache-invalidation/>.
**Applicability.** Single-node now.

#### 4.21 Measure the invariant continuously, like Polaris — don't just test it
**What it is.** Meta's Polaris "monitors violations of client-observable invariants" while treating
the stateful service as a black box, acting as a cache client so it detects exactly what users would
experience. It reports on multiple timescales (1, 5, 10 minutes) so that transient replication lag
does not generate false positives, and defers expensive database-bypass verification until an
inconsistency persists across reporting boundaries. Meta took TAO from 99.9999% to 99.99999999%
consistent — fewer than one inconsistent entry per ten billion cache writes in a five-minute window.
Their *consistency tracing* traces only the narrow window between a write and subsequent cache fills
rather than logging all mutations, which located a real production bug (error-handling that failed to
evict stale metadata) in under 30 minutes.
**Claim + test.** Claim: *the SUT publishes a continuously-measured metric for "a name answered
differently than it did before", not just a green test suite.* Test/design: a permanent Polaris-shaped
prober — samples `{name, question}` pairs, journals answer hashes off-box, re-asks them on a schedule
and after every restart and deploy, and alarms on any change. Report it as a nines figure. **This is
the single most transferable engineering practice found in this research**: the central claim is an
*invariant*, and invariants want a monitor, not only a test.
**Source.** <https://engineering.fb.com/2022/06/08/core-infra/cache-made-consistent/>.
**Applicability.** Single-node now.

#### 4.22 HTTP/ETag interactions when names leave the process
**What goes wrong.** The natural HTTP mapping is ETag = hash of `{name, question}` — a *strong*
validator, which is exactly right and unusually easy here. Three ways it goes wrong:
(a) **ETag reuse across an epoch change** (§4.1) — after a restore, the same ETag denotes different
    bytes, and intermediary caches will serve the old body forever on a 304.
(b) **Weak vs strong validators** — a weak ETag (`W/"…"`) permits the server to return semantically
    but not byte-equivalent content, which breaks any client hashing the body.
(c) **`Cache-Control: immutable` / very long `max-age`** applied to a URL that is *not* name-scoped
    (e.g. `/ask?q=…` without the name in the path) — an unkeyed input again, now cached in shared
    proxies you do not control and cannot purge.
**Conditions.** Any HTTP surface, CDN, or browser cache in front of `ask`.
**Claim + test.** Claim: *every cacheable HTTP response's URL contains the full name; ETags are
strong; `immutable` is only ever set on name-scoped URLs; the epoch is part of the ETag.* Test:
(1) assert no cacheable response exists whose URL omits the name; (2) restore to an earlier epoch,
re-request, assert the ETag differs; (3) assert `Vary` covers every request header that changes the
body (tenant, auth, accept-encoding) — or better, that no such header exists because everything is in
the path.
**Source.** RFC 9110 §8.8.3 (ETag; strong vs weak validators),
<https://www.rfc-editor.org/rfc/rfc9110>; RFC 9111 (HTTP Caching),
<https://www.rfc-editor.org/rfc/rfc9111>;
<https://portswigger.net/research/practical-web-cache-poisoning>.
**Applicability.** Single-node now.

#### 4.23 Name canonicalization — a map is not a good identity
**What goes wrong.** "A name is a plain map the client holds and can construct by hand" means name
*equality* is map equality, and cache keys are derived from a map. Two failure directions:
**over-splitting** — `%{ledgers: [a, b], tx: 7}` and `%{ledgers: [b, a], tx: 7}` denote the same
snapshot but hash differently, so the cache misses, doubles in size, and stampedes (§4.15);
**under-splitting** — a key derivation that stringifies or hashes carelessly maps two distinct names
to one key, which is silent corruption. Add the Erlang map-order hazard (§4.12) and a naive
`:erlang.phash2(name)` is unreliable across sizes and versions.
**Conditions.** Multi-ledger names; optional fields; atom vs binary keys; nil-vs-absent.
**Claim + test.** Claim: *there is exactly one canonical form of a name, and `key(n1) == key(n2) ⟺
denotes_same(n1, n2)`.* Test: a property test over generated names — (1) canonicalization is
idempotent; (2) any permutation/re-encoding of a name canonicalizes identically; (3) an injectivity
test over millions of distinct names asserting no key collisions; (4) round-trip through JSON and
back (clients are JS) preserves the key — this catches atom/binary, integer/float, and key-order
drift at the wire boundary.
**Source.** Design-level; grounded in <https://www.erlang.org/doc/system/maps.html> (unspecified
iteration order) and <https://portswigger.net/research/practical-web-cache-poisoning> (key must be a
faithful function of the request).
**Applicability.** **Single-node now.** Cheap to fix now, structurally painful later.

#### 4.24 Schema evolution changes what old facts *mean* without changing what they *are*
**What goes wrong.** The fact set at an old name is unchanged, but the *interpretation* changes: an
attribute's cardinality flips one-to-many, its value type changes, an attribute is renamed, or a
formula's understanding of `provenance` changes. `ask(old_name, q)` now returns a different answer
from the same facts. Datomic guards the extreme case by refusing to excise schema datoms at all
("Schema datoms and datoms that are part of Datomic's bootstrap cannot be excised").
**Conditions.** Any schema change, any attribute rename — and this repo's own doctrine has a rename
ledger, so renames are expected, not hypothetical.
**Claim + test.** Claim: *schema is itself facts in the log, so the schema in force at name N is the
schema at N, not the current one.* Test: change an attribute's definition; assert `ask` at a
pre-change name uses the pre-change schema and returns the identical prior answer. If the store reads
the *current* schema when answering an old name, the central claim is false for every schema change —
which is a common enough event that it would falsify the claim in practice within weeks.
**Source.** <https://docs.datomic.com/operation/excision.html>;
<https://docs.datomic.com/transactions/acid.html>.
**Applicability.** Single-node now.

#### 4.25 The claim itself, stated as one testable invariant
**What it is.** Everything above reduces to one property worth stating in the repo in exactly these
terms, because a claim that cannot be written as an assertion cannot be tested:

> For every name N ever observable by a client, every question Q, and every pair of times t₁ < t₂
> spanning arbitrary writes, crashes, restarts, restores, deploys, erasures, compactions, schema
> changes and cache states: `ask(N, Q)@t₁ == ask(N, Q)@t₂`, byte for byte — or `ask(N, Q)@t₂` raises
> a *typed epoch error* that names the discontinuity.

The escape hatch matters as much as the invariant: **the only safe way to break immutability is to
fail closed and loudly.** A design that can only either answer-the-same or answer-differently has no
way to survive a restore or a lawful erasure. A design with an epoch in the name has one.
**Test.** The Polaris-shaped prober of §4.21 *is* this test, run forever. The suite in §4.4 is this
test, run against crashes. Everything else in Topic 4 is a way of enumerating the `t₁ < t₂` interval.
**Source.** Synthesised; closest primary statements are
<https://docs.datomic.com/operation/caching.html> ("Datomic caches only immutable data, so all caches
are valid forever") and
<https://engineering.fb.com/2022/06/08/core-infra/cache-made-consistent/> (invariants must be measured).
**Applicability.** Single-node now.

---

### Source index

**Isolation theory**
- Berenson, Bernstein, Gray, Melton, O'Neil & O'Neil, "A Critique of ANSI SQL Isolation Levels",
  SIGMOD '95 / MSR-TR-95-51 — <https://arxiv.org/pdf/cs/0701157>
- Adya, Liskov & O'Neil, "Generalized Isolation Level Definitions", ICDE 2000 —
  <https://pmg.csail.mit.edu/papers/icde00.pdf>; summary
  <https://blog.acolyer.org/2016/02/25/generalized-isolation-level-definitions/>
- Adya, "Weak Consistency: A Generalized Theory and Optimistic Implementations for Distributed
  Transactions", MIT PhD thesis 1999 — <http://pmg.csail.mit.edu/papers/adya-phd.pdf>
- Fekete, O'Neil & O'Neil, "A Read-Only Transaction Anomaly Under Snapshot Isolation", SIGMOD Record
  2004 — <https://www.cs.umb.edu/~poneil/ROAnom.pdf>
- Fekete, Liarokapis, O'Neil, O'Neil & Shasha, "Making Snapshot Isolation Serializable", TODS 2005 —
  <https://www.cse.iitb.ac.in/infolab/Data/Courses/CS632/2009/Papers/p492-fekete.pdf>
- Ports & Grittner, "Serializable Snapshot Isolation in PostgreSQL", VLDB 2012 —
  <https://drkp.net/papers/ssi-vldb12.pdf>
- Terry, Demers, Petersen, Spreitzer, Theimer & Welch, "Session Guarantees for Weakly Consistent
  Replicated Data", PDIS 1994 — <https://dl.acm.org/doi/10.5555/645792.668302>
- Brooker, "What Fekete's Anomaly Can Teach Us About Isolation" —
  <https://brooker.co.za/blog/2025/02/05/feketes.html>
- Bailis, "When is 'ACID' ACID? Rarely." — <http://www.bailis.org/blog/when-is-acid-acid-rarely/>

**Detection tools and vocabularies**
- Kingsbury & Alvaro, "Elle: Inferring Isolation Anomalies from Experimental Observations",
  arXiv:2003.10554 — <https://arxiv.org/pdf/2003.10554>; tool <https://github.com/jepsen-io/elle>
- Kleppmann, Hermitage — <https://github.com/ept/hermitage>, PostgreSQL cases
  <https://github.com/ept/hermitage/blob/master/postgres.md>, background
  <https://martin.kleppmann.com/2014/11/25/hermitage-testing-the-i-in-acid.html>
- Jepsen consistency reference — <https://jepsen.io/consistency>,
  <https://jepsen.io/consistency/phenomena>, <https://jepsen.io/consistency/phenomena/g-single>,
  <https://jepsen.io/consistency/phenomena/g-nonadjacent>,
  <https://jepsen.io/consistency/models/snapshot-isolation>,
  <https://jepsen.io/consistency/models/strict-serializable>
- Kingsbury, "Strong consistency models" — <https://aphyr.com/posts/313-strong-consistency-models>
- Jepsen: PostgreSQL 12.3 — <https://jepsen.io/analyses/postgresql-12.3>

**MVCC and durability mechanics**
- PostgreSQL, "Transaction Isolation" — <https://www.postgresql.org/docs/current/transaction-iso.html>
- PostgreSQL commit e24615a005, "Fix visibility check when XID is committed in CLOG but not in
  procarray" — <https://www.postgresql.org/message-id/E1o5hFk-0020zN-0W@gemulon.postgresql.org>
- "MVCC in PostgreSQL — 4. Snapshots" — <https://postgrespro.com/blog/pgsql/5967899>
- Removal of `old_snapshot_threshold` in PostgreSQL 17 —
  <https://www.dbi-services.com/blog/no-more-snapshot-too-old-in-postgresql-17/>
- RocksDB WAL Recovery Modes — <https://github.com/facebook/rocksdb/wiki/WAL-Recovery-Modes>;
  recycling interaction <https://github.com/facebook/rocksdb/pull/6351>
- PostgreSQL fsync errors — <https://wiki.postgresql.org/wiki/Fsync_Errors>; Rebello et al., "Can
  Applications Recover from fsync Failures?", USENIX ATC 2020 —
  <https://www.usenix.org/conference/atc20/presentation/rebello>

**Immutable-database precedent**
- Datomic ACID — <https://docs.datomic.com/transactions/acid.html>
- Datomic caching — <https://docs.datomic.com/operation/caching.html>
- Datomic excision — <https://docs.datomic.com/operation/excision.html>
- Datomic + GDPR — <https://vvvvalvalval.github.io/posts/2018-05-01-making-a-datomic-system-gdpr-compliant.html>,
  <https://medium.com/magnetcoop/gdpr-right-to-be-forgotten-vs-datomic-3d0413caf102>
- Datomic Cloud multi-tenancy — <https://kwill.dev/posts/datomic-cloud-multi-tenancy/>

**Caching**
- Meta, "Cache made consistent" (Polaris) —
  <https://engineering.fb.com/2022/06/08/core-infra/cache-made-consistent/>;
  <https://uvdn7.github.io/cache-invalidation/>
- Vattani, Chierichetti & Lowenstein, "Optimal Probabilistic Cache Stampede Prevention", VLDB 2015 —
  <http://www.vldb.org/pvldb/vol8/p886-vattani.pdf>
- Kettle, "Practical Web Cache Poisoning" — <https://portswigger.net/research/practical-web-cache-poisoning>
- RFC 9110 (HTTP Semantics, ETag) — <https://www.rfc-editor.org/rfc/rfc9110>; RFC 9111 (HTTP Caching)
  — <https://www.rfc-editor.org/rfc/rfc9111>; RFC 2308 (Negative Caching of DNS Queries) —
  <https://www.rfc-editor.org/rfc/rfc2308>

**Determinism**
- Reproducible Builds documentation — <https://reproducible-builds.org/docs/>
- Erlang maps (flatmap/hashmap, iteration order) — <https://www.erlang.org/doc/system/maps.html>;
  <https://github.com/erlang/otp/issues/7851>

---


## Section 3 — Backup/restore and crypto/key-management claims

Research for a claims-based test suite. System under test: single-node, immutable
append-only fact-log; incremental byte-range segment backup to S3-compatible object
storage; envelope encryption with three tiers (Cloud KMS → master → per-subject →
per-fact data key) and erasure-by-key-destruction plus tombstone facts.

Applicability legend: **SN** = applies to the single node today · **DIST** = only
matters if/when distributed · **N/A** = not applicable, recorded for completeness.

---

### 5. BACKUP AND RESTORE FAILURE MODES

#### 5.1 The backup that has never been restored is not a backup
**WHAT GOES WRONG.** GitLab.com, 31 Jan 2017: an engineer removed the wrong data
directory, and *five* separate mechanisms — pg_dump to S3, LVM snapshots, Azure disk
snapshots, streaming replication, and Azure-level backups — all failed to produce a
usable restore. They recovered only because an engineer had, by chance, taken a manual
LVM snapshot six hours earlier for unrelated staging work. Nobody had ever executed
the restore path end to end.
**CONDITIONS.** Any backup mechanism whose success is inferred from the backup side
only.
**CLAIM + TEST.** *Claim: the documented restore procedure, run by someone who did
not write it, against the current on-disk format, produces a byte-identical log.*
Test: a CI job that (a) writes N facts, (b) runs `backup`, (c) restores into a clean
directory on a clean machine image, (d) asserts `sha256(restored) == sha256(source)`
AND that a full read of the restored log returns the same fact set. Fail the build if
this job has not run in the last 24h.
**SOURCE.** https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
**APPLICABILITY.** SN.

#### 5.2 The backup job failing silently because the notification path also failed
**WHAT GOES WRONG.** GitLab's pg_dump was invoking PostgreSQL 9.2 binaries against a
9.6 server; pg_dump aborts on a major-version mismatch. The failure *did* generate
mail — but the mail had no DMARC signature and the receiving server discarded it. The
S3 bucket sat empty for months and the dashboard said nothing.
**CONDITIONS.** Backup success signalled out-of-band (email, webhook, log line) rather
than measured in-band from the target.
**CLAIM + TEST.** *Claim: backup health is derived from the target bucket, not from
the exit code of the backup process.* Test: kill the backup process with exit 0 after
it uploads nothing; assert the health check goes red within one interval. Second test:
break the notification channel entirely and assert health still goes red.
**SOURCE.** https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
**APPLICABILITY.** SN.

#### 5.3 Restore that is slower than the outage budget
**WHAT GOES WRONG.** GitLab's recovery required copying from a staging host over a link
throttled to ~60 Mbps: roughly 18 hours of copying for ~300 GB. The backup existed and
was correct; the *time to use it* was the failure. Google's 2011 Gmail incident is the
same shape from the other side — tape backups saved 0.02% of users' mail precisely
because tape was offline and immune to the replication bug, but restoring took hours
rather than the milliseconds a datacenter failover takes.
**CONDITIONS.** RTO assumed rather than measured; bandwidth between the object store
and the restore host never benchmarked.
**CLAIM + TEST.** *Claim: restore of a log of size S completes in ≤ T seconds, and T
is recorded, not assumed.* Test: parametrise the restore CI job over log sizes
(1 GB / 10 GB / 100 GB), record wall-clock and bytes/sec, and assert against a
committed RTO budget. Assert the budget file is younger than the last format change.
**SOURCE.** https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/ ·
https://www.datacenterknowledge.com/archives/2011/03/01/google-turns-to-tape-to-rescue-lost-gmail
**APPLICABILITY.** SN.

#### 5.4 The hole: a failed PUT after a later PUT succeeded
**WHAT GOES WRONG.** The segment scheme names each object for the byte range it holds.
If segment `[0,100)` and `[200,300)` land but `[100,200)` fails (transient 500, process
kill, credential expiry mid-run), the bucket contains two objects and a gap. A restore
that "sorts segments and concatenates" produces a file that is byte-shifted from 100
onwards — every record boundary after the hole is garbage, and the file is still a
plausible length.
**CONDITIONS.** Multiple segments per run, or a run that resumes after partial failure;
no manifest recording the expected contiguous range.
**CLAIM + TEST.** *Claim: `restore` refuses to produce output when the segment set is
not a contiguous cover of [0, N).* Test: upload segments `[0,100)` and `[200,300)`,
delete nothing else, run restore, assert it exits non-zero naming the missing range
`[100,200)` (errors are data with the repair attached). Second test: assert `verify`
reports the contiguous run as 100, not 300.
**SOURCE.** Mechanism generalised from restic's pack-file model, where a missing pack
makes the repository fail an integrity check rather than restore short:
https://restic.readthedocs.io/en/latest/077_troubleshooting.html
**APPLICABILITY.** SN. **This is the single highest-value test in the section — the
design already anticipates it (verify uses the contiguous run) but the guarantee must
be asserted, not documented.**

#### 5.5 Segment uploaded out of order, then the run dies
**WHAT GOES WRONG.** If the uploader parallelises or retries, a later range can be
durable before an earlier one. S3 gives strong read-after-write per key but there is
no cross-key atomicity and no transaction: "Updates are key-based. There is no way to
make atomic updates across keys." A crash between the two leaves the hole of 5.4 with
a *higher* maximum offset than the truthful contiguous end — which is exactly why
`verify` comparing against the highest segment boundary would lie.
**CONDITIONS.** Concurrency or retry in the upload path; any crash window.
**CLAIM + TEST.** *Claim: the contiguous-run computation is the only definition of
"backed up", and no code path uses max-offset.* Test: grep-level assertion is weak —
instead, upload `[0,10)` and `[90,100)`, assert `verify` says 10 bytes covered and
`backup` next run re-uploads from 10, not from 100.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel
**APPLICABILITY.** SN.

#### 5.6 S3 consistency history — what changed in Dec 2020 and what did not
**WHAT GOES WRONG.** Before December 2020, S3 offered read-after-write consistency
only for PUTs of *new* objects, and eventual consistency for overwrites, deletes and
LIST. Backup tools written in that era carry sleeps, retry-on-404 loops and
"eventually the list will catch up" assumptions. Since Dec 2020 all GET/PUT/LIST of
objects, plus ACL/tag/metadata reads, are strongly consistent in all Regions. But
**bucket configuration remains eventually consistent**: AWS still documents that a
deleted bucket may appear in a LIST, and that after enabling versioning for the first
time you should *wait 15 minutes* before issuing object writes.
**CONDITIONS.** Any provisioning script that enables versioning/Object Lock/lifecycle
and immediately starts backing up. Also: S3-*compatible* stores (MinIO, R2, Backblaze,
Ceph RGW, Wasabi) make their own consistency promises and several historically did not
match S3's.
**CLAIM + TEST.** *Claim (a): the backup path relies on no eventual-consistency
workaround. Claim (b): provisioning waits for, or verifies, versioning before the
first write.* Test: run the whole suite against a fault-injecting S3 proxy that delays
LIST visibility by 30s and returns stale bucket-config reads; assert no test depends
on immediate LIST. Test (b): create bucket, enable versioning, immediately write and
overwrite an object, assert the noncurrent version exists (this is the documented
15-minute hazard — a `null` version ID means the write beat versioning).
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel ·
https://aws.amazon.com/s3/consistency/
**APPLICABILITY.** SN. Bucket-config item is deployment-time, not runtime.

#### 5.7 Concurrent writers to the same key: last-writer-wins, no locking
**WHAT GOES WRONG.** AWS: "Amazon S3 does not support object locking for concurrent
writers. If two PUT requests are simultaneously made to the same key, the request with
the latest timestamp wins." Two backup runs overlapping (cron overrun, a deploy that
starts a second instance) can both compute the same next segment range from different
tail positions; the shorter one can win and truncate a range that was already complete.
**CONDITIONS.** No mutual exclusion around the backup run. Note the repo ground rule:
*deploys reset in-flight work* — a redeploy mid-backup is exactly this.
**CLAIM + TEST.** *Claim: two concurrent `backup` runs cannot produce a segment whose
name claims more bytes than it holds.* Test: run two backups concurrently against the
same bucket with an artificial stall in one; afterwards assert for every segment
`object_size == range_end - range_start`, and that a restore still round-trips.
Consider a lock object with a TTL, and assert the second run refuses.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel
**APPLICABILITY.** SN.

#### 5.8 Segment name says one range, object body holds another
**WHAT GOES WRONG.** The range is encoded in the key. Nothing binds the name to the
bytes. A truncated upload, a proxy that buffers, or a bug that computes the end offset
before the final read can produce `seg-000100-000200` containing 80 bytes. Restore
concatenates and every subsequent record is shifted.
**CONDITIONS.** Name-as-metadata with no length or digest check on read.
**CLAIM + TEST.** *Claim: restore validates `Content-Length` (and a checksum) of each
segment against the range in its name before concatenating.* Test: PUT a segment whose
body is one byte short of its name's range; assert restore refuses and names the
offending key. Repeat with one byte long.
**SOURCE.** S3 supports per-object CRC64NVME (default), CRC32/32C, SHA-1/256/512,
XXHash and MD5, and S3 Batch Operations "Compute checksum" can verify objects at rest
without downloading them:
https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html
**APPLICABILITY.** SN.

#### 5.9 Verification that only checks existence
**WHAT GOES WRONG.** A `verify` that LISTs the bucket and confirms the expected keys
are present passes against corrupted bodies, truncated bodies, and bodies encrypted by
an attacker (see 5.14). restic makes this explicit: `restic check` does *not* read pack
contents; only `check --read-data` does, and it costs a full download.
**CONDITIONS.** Verification cost optimised before verification correctness.
**CLAIM + TEST.** *Claim: `verify` compares content, not existence, and says which
mode it ran in.* Test: overwrite a mid-chain segment with the right number of random
bytes; assert `verify` fails. Then assert a cheap "existence-only" mode, if it exists,
labels its own output as such and cannot satisfy the release gate.
**SOURCE.** https://restic.readthedocs.io/en/latest/045_working_with_repos.html
**APPLICABILITY.** SN.

#### 5.10 No manifest: the backup does not know how many segments it should have
**WHAT GOES WRONG.** With segments self-describing by name and nothing else, "complete"
is inferred from what is present. Any absence is indistinguishable from "that range
never existed". There is no way to detect a deletion of the *newest* segments — the
chain simply appears shorter, and a restore silently lands you at an older point in
time. This is silent partial restore in its purest form.
**CONDITIONS.** No monotonic, signed, or otherwise authenticated record of the highest
committed offset.
**CLAIM + TEST.** *Claim: after a restore, the system can state the exact offset it
restored to, and compare that to an independently recorded high-water mark.* Test:
back up to offset N, delete the top three segments, restore, assert the tool *reports*
`restored to offset M < N` prominently rather than exiting 0 quietly. Stronger: keep a
`HEAD` object holding the last verified contiguous offset and assert restore fails
loudly when the segments do not reach it.
**SOURCE.** Failure shape documented in restic's "Data seems to be missing" class of
issue: https://github.com/restic/restic/issues/4115
**APPLICABILITY.** SN.

#### 5.11 Multipart upload leaves paid-for, invisible, incomplete parts
**WHAT GOES WRONG.** A multipart upload that is initiated and never completed leaves
its parts in the bucket. They bill as storage indefinitely, and they are invisible to
`aws s3 ls` and to the console's Objects tab. Worse for correctness: a crashed
multipart upload leaves *no* object, so a naive "did the key appear?" check correctly
reports absence — but a resume implementation that reuses the same upload ID across
runs can complete an upload assembled from parts computed against two different tail
positions.
**CONDITIONS.** Segments large enough to trigger the SDK's multipart threshold
(commonly 8–16 MB); any crash mid-upload.
**CLAIM + TEST.** *Claim (a): a killed backup leaves no incomplete multipart upload
older than one run interval. Claim (b): resume never reuses an upload ID across runs.*
Test: SIGKILL the process mid-upload of a large segment; assert
`ListMultipartUploads` is empty after the next run, or that an
`AbortIncompleteMultipartUpload` lifecycle rule with `DaysAfterInitiation` is present
on the bucket and asserted by a config test.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpu-abort-incomplete-mpu-lifecycle-config.html ·
https://aws.amazon.com/blogs/aws-cloud-financial-management/discovering-and-deleting-incomplete-multipart-uploads-to-lower-amazon-s3-costs/
**APPLICABILITY.** SN.

#### 5.12 Multipart ETag is not an MD5 — integrity checks that quietly do nothing
**WHAT GOES WRONG.** For multipart objects, the ETag is a composite (a digest of part
digests plus `-N`), not the MD5 of the object. Code that compares `ETag` to a local
MD5 to "verify" a large segment will always mismatch — and the usual fix is for someone
to delete the check. S3 also distinguishes *composite* from *full-object* checksums for
multipart; a comparison across the two types fails for correct data.
**CONDITIONS.** Any object above the multipart threshold.
**CLAIM + TEST.** *Claim: verification uses a full-object checksum algorithm
(`CRC64NVME` or `SHA256` with full-object checksum type), never ETag.* Test: upload
one segment below and one above the multipart threshold with the same content
pipeline; assert `verify` passes for both and that the code path is identical.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html
**APPLICABILITY.** SN.

#### 5.13 Node credentials can delete: versioning and retention live on the bucket, and nothing asserts they are on
**WHAT GOES WRONG.** The design explicitly says the node's credentials can usually
delete, and that versioning/retention are "expected to live on the bucket". Expectation
is not enforcement. Code Spaces (June 2014) died in a single afternoon: an attacker who
got the AWS control panel created backdoor logins and deleted EBS snapshots, S3
buckets, AMIs and instances; the backups were in the same account as production and the
company shut down within hours. Codefinger (Jan 2025) needed only `s3:GetObject` and
`s3:PutObject` to overwrite every object with SSE-C-encrypted ciphertext.
**CONDITIONS.** Backup target reachable with the same credential the node holds; no
independent verification of bucket protections.
**CLAIM + TEST.** *Claim: the backup target has versioning enabled, an Object Lock or
equivalent retention configuration, and a lifecycle policy consistent with the
retention promise — and the tool refuses to run against a bucket that does not.*
Test: point `backup` at a bucket with versioning off; assert it exits non-zero with the
remediation printed. Then a scheduled config test that reads
`GetBucketVersioning` / `GetObjectLockConfiguration` / `GetBucketLifecycleConfiguration`
and asserts them, run from credentials *other* than the node's.
**SOURCE.** https://threatpost.com/hacker-puts-hosting-service-code-spaces-out-of-business/106761/ ·
https://www.breaches.cloud/incidents/codespaces/ ·
https://github.com/ramimac/aws-customer-security-incidents
**APPLICABILITY.** SN.

#### 5.14 Ransomware that encrypts rather than deletes — and versioning does not help
**WHAT GOES WRONG.** Codefinger used compromised AWS keys to re-`PutObject` every
object with **SSE-C**, supplying their own AES-256 key. AWS never stores an SSE-C key;
CloudTrail records only an HMAC of it, which is useless for recovery. The objects still
exist, still have plausible sizes, and LIST still shows them. Attackers then set
lifecycle rules marking files for deletion in seven days to create urgency. Existence
checks pass; the data is gone.
**CONDITIONS.** A credential with PutObject on the backup bucket; no policy condition
denying SSE-C.
**CLAIM + TEST.** *Claim (a): `verify` detects content substitution, not just presence.
Claim (b): the bucket policy denies requests carrying
`x-amz-server-side-encryption-customer-algorithm`.* Test (a): re-upload a segment with
different bytes; assert `verify` fails. Test (b): attempt an SSE-C PUT with the node
credential; assert AccessDenied.
**SOURCE.** https://www.halcyon.ai/blog/abusing-aws-native-services-ransomware-encrypting-s3-buckets-with-sse-c
**APPLICABILITY.** SN.

#### 5.15 Ransomware that reaches the backup because the backup is reachable
**WHAT GOES WRONG.** CloudNordic and AzeroCloud (Aug 2023): after a datacenter
migration put previously segregated servers on one internal network, attackers reached
central administration and encrypted server disks *and both the primary and secondary
backup systems*. The company told customers the majority had lost all data and did not
expect to have customers afterwards. The NCSC's guidance on this is blunt: an offline
copy is the control that survives credential compromise.
**CONDITIONS.** Backup on the same trust boundary / network / identity as production.
**CLAIM + TEST.** *Claim: at least one copy of the log is written by a principal the
node cannot assume, into a namespace the node cannot delete from.* Test: with the
node's exact credential set, attempt `DeleteObject`, `DeleteObjectVersion`,
`PutBucketVersioning(Suspended)`, `PutBucketLifecycleConfiguration`,
`PutObjectRetention(bypass)`; assert every one is denied. This is a permissions
*negative* test and it is cheap.
**SOURCE.** https://www.datacenterdynamics.com/en/news/danish-hosting-firms-lose-all-customer-data-in-ransomware-attack/ ·
https://www.ncsc.gov.uk/pdfs/blog-post/offline-backups-in-an-online-world.pdf
**APPLICABILITY.** SN.

#### 5.16 Object Lock governance mode is bypassable by design
**WHAT GOES WRONG.** Governance mode blocks *most* users; anyone with
`s3:BypassGovernanceRetention` who sends `x-amz-bypass-governance-retention:true`
deletes anyway — and the console adds that header automatically for such users.
Compliance mode cannot be bypassed by anyone including the account root, and retention
cannot be shortened — but that is also an availability hazard (you cannot delete a
mistakenly-locked 100 TB). Object Lock requires versioning and cannot be disabled once
enabled on a bucket.
**CONDITIONS.** Assuming "Object Lock is on" means immutable.
**CLAIM + TEST.** *Claim: the retention mode in use is asserted, and the node's
principal lacks `s3:BypassGovernanceRetention`.* Test: read
`GetObjectLockConfiguration`, assert the mode matches the documented promise; simulate
the bypass delete with the node credential and assert denial.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html ·
https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-managing.html
**APPLICABILITY.** SN.

#### 5.17 Lifecycle expiration deletes what Object Lock protects
**WHAT GOES WRONG.** AWS documents that "S3 Lifecycle rules continue to perform
expirations of current versions through simple DELETE operations regardless of the
object-level Object Lock configurations." A retention story built on Object Lock plus
a tidy-up lifecycle rule can quietly shed current versions. Separately,
`NoncurrentVersionExpiration` with `NewerNoncurrentVersions: 0` and
`NoncurrentDays: 1` leaves effectively no recovery window, and lifecycle rules fail
silently — a misconfigured rule raises no error on save and evaluates once a day.
**CONDITIONS.** Any lifecycle rule on the backup bucket.
**CLAIM + TEST.** *Claim: the backup prefix has no expiration or
noncurrent-expiration rule shorter than the stated retention.* Test: parse
`GetBucketLifecycleConfiguration`, assert every rule whose prefix intersects the backup
prefix either is `AbortIncompleteMultipartUpload`-only or has
`NoncurrentDays >= retention_days`. Run it as a config test, not a comment.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-managing.html ·
https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-configuration-examples.html
**APPLICABILITY.** SN.

#### 5.18 Delete markers make an object "gone" without deleting anything
**WHAT GOES WRONG.** On a versioned bucket, `DeleteObject` inserts a delete marker;
GET returns 404 and LIST omits the key, while the data still exists as a noncurrent
version. A `verify` that treats 404 as "segment missing, re-upload" will happily
re-upload — masking that someone (or something) is deleting backups, and then
`NoncurrentVersionExpiration` eventually makes the loss real.
**CONDITIONS.** Versioned bucket plus any deleting principal.
**CLAIM + TEST.** *Claim: `verify` distinguishes "never uploaded" from "delete marker
present".* Test: `DeleteObject` a mid-chain segment on a versioned bucket; assert
`verify` reports a *deleted* segment (via `ListObjectVersions`) rather than a missing
one, and that this is treated as an alertable security event, not a routine re-upload.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html
**APPLICABILITY.** SN.

#### 5.19 Cross-region replication is asynchronous and does not backfill
**WHAT GOES WRONG.** S3 Replication is asynchronous; even with Replication Time Control
the promise is "most objects in seconds, 99.9% within 15 minutes" — and the RTC SLA
explicitly does *not* apply when you exceed request-rate guidance or the default 1 Gbps
replication transfer quota. Replication also only covers objects written *after* the
rule is created unless Batch Replication is run, and delete-marker replication is a
separate opt-in. A DR bucket can therefore be missing exactly the newest segments —
the ones you need.
**CONDITIONS.** Any "we replicate to a second region so we're safe" claim.
**CLAIM + TEST.** *Claim: the replica bucket's contiguous run is within X seconds of
the source's, measured.* Test: after a backup, poll the replica and record the lag;
assert against a budget. Assert the replication rule's `DeleteMarkerReplication`
setting matches the intended policy either way.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-time-control.html
**APPLICABILITY.** DIST for multi-region; SN if a DR replica is claimed.

#### 5.20 Backing up a file while it is being appended to
**WHAT GOES WRONG.** The design already handles the obvious case (stop at the last
complete record, because a live log's tail may be half-written). The subtler case is
the *reader*: a copy of a growing file is crash-consistent at best — it reflects what
was written to the page cache/disk in order, not what the writer believes it committed.
If the log's record framing (length prefix, checksum, terminator) is written
non-atomically, a segment can end mid-frame in a way that still parses.
**CONDITIONS.** Any read of the live log concurrent with appends.
**CLAIM + TEST.** *Claim: for every possible truncation point of the live log, the
backup's "last complete record" boundary is at or before the last durably-committed
record.* Test: property test — append records of random sizes, take a backup at a
random byte offset chosen by an injected reader, restore, assert the restored log
parses cleanly and its record set is a *prefix* of the source's record set. Run for
thousands of offsets, especially offsets inside length prefixes and checksums.
**SOURCE.** https://www.computerweekly.com/feature/Storage-101-Crash-consistent-vs-application-consistent-snapshots
**APPLICABILITY.** SN. High leverage: this is a pure property test with no infra.

#### 5.21 "It was written" is not "it was durable" — the fsync lie
**WHAT GOES WRONG.** PostgreSQL's *fsyncgate* (2018): on Linux, when writeback fails,
dirty pages can be marked clean and the error reported exactly once, to whichever fd
calls `fsync()` first. PostgreSQL retried the checkpoint, the retry's `fsync()`
returned success because the error flag had been consumed, and the checkpoint completed
over data that never reached disk. Twenty years of silent data loss potential. The fix
was to PANIC on fsync failure rather than retry.
**CONDITIONS.** Any append path that treats a second `fsync()` after an error as
recovery; any backup that reads through the page cache and believes it.
**CLAIM + TEST.** *Claim: an `fsync` error is fatal to the process, never retried into
apparent success; and the backup's notion of "durable tail" derives from a successful
fsync, not from file length.* Test: fault-inject EIO on fsync (dm-flakey, or an
LD_PRELOAD shim); assert the process aborts and that on restart the log recovers to the
last known-durable record rather than accepting the longer, unsynced file.
**SOURCE.** https://lwn.net/Articles/752063/ · https://danluu.com/fsyncgate/
**APPLICABILITY.** SN. High leverage for an append-only log specifically.

#### 5.22 Restore that lands on top of live facts
**WHAT GOES WRONG.** The design says restore refuses to land on live facts. The
failure mode is the refusal being weaker than it reads: a restore into a directory
that *looks* empty but holds a zero-length log, or a keyring, or checkpoints from a
different lineage. Concatenating a restored log onto (or beside) a live one gives a
file that parses and answers queries with two interleaved histories.
**CONDITIONS.** Restore target directory not provably empty; identity of the log not
checked (no instance UUID, no epoch).
**CLAIM + TEST.** *Claim: restore refuses unless the target contains no log, no
keyring and no checkpoint, and the segments' lineage identifier matches the target's
(or the target has none).* Test matrix: empty dir (pass); dir with 0-byte log (refuse);
dir with a log from a *different* lineage (refuse, naming the mismatch); dir with a
shorter prefix of the same lineage (decide deliberately — refuse or extend — and test
whichever you chose).
**SOURCE.** Design statement in the SUT; failure shape is the classic split-brain
restore. Corroborating: https://about.gitlab.com/blog/gitlab-dot-com-database-incident
**APPLICABILITY.** SN.

#### 5.23 Restore order: lexicographic sort is not numeric sort
**WHAT GOES WRONG.** "Sort segments and concatenate." If the range is rendered without
zero-padding, `seg-100` sorts before `seg-20`. If it is padded to a fixed width, the
scheme breaks silently the first time the log exceeds that width. If offsets are hex in
one place and decimal in another, ordering is wrong for a subset of values only.
**CONDITIONS.** Any offset-in-key encoding.
**CLAIM + TEST.** *Claim: restore orders segments by parsed integer offset, and refuses
keys it cannot parse.* Test: generate segment names across the padding boundary
(e.g. 999→1000, 2^31, 2^32, 2^53) and assert restore's order equals numeric order.
Add a key with a malformed name and assert refusal rather than silent skip.
**SOURCE.** Generic; the padding-boundary class is why S3 LIST's lexicographic ordering
is documented as byte order: https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html
**APPLICABILITY.** SN. Cheap, and the kind of bug that only shows up in production.

#### 5.24 Checkpoints are derived — until a restore proves they are
**WHAT GOES WRONG.** The design excludes checkpoints from backup on the grounds that
they are derived. That is only true if they can actually be rebuilt from the restored
log, at the current code version, within the RTO. Rebuild time is usually never
measured, and a subtle checkpoint-format dependency on data that *is not* in the log
(a config value, a clock, an ordering) turns "derived" into "lost".
**CONDITIONS.** Any derived artifact excluded from backup.
**CLAIM + TEST.** *Claim: checkpoints rebuilt from a restored log are equivalent to
the originals, and the rebuild fits the RTO.* Test: back up, restore into a clean dir,
rebuild checkpoints, assert semantic equality with the source's checkpoints (or, if
they are not byte-comparable, assert identical query answers over a fixed query set).
Record rebuild wall-clock and assert against budget.
**APPLICABILITY.** SN.

#### 5.25 Keys backed up whole, every run, next to the ciphertext
**WHAT GOES WRONG.** This is the direct inverse of 5.26 and it is the one the design
chose. If the key store lands in the same bucket, under the same credential, as the
segments, then an attacker who reads the bucket has both halves and the encryption
contributes nothing against that adversary. It also means every historical backup of
the key store contains keys the tombstone reconciliation is supposed to have
destroyed — the reconciliation fixes a *restored* keyring, but an attacker reading an
old key-store object directly does not run your reconciliation. (See 6.14 for the
erasure consequence, which is the more serious half.)
**CONDITIONS.** Key store and ciphertext in one bucket/prefix/credential.
**CLAIM + TEST.** *Claim: the key-store backup is written to a distinct bucket under a
distinct credential, and the node's segment-writing credential cannot read it.* Test:
with the segment credential, attempt GetObject on a key-store object; assert denied.
Second: assert the key store objects are themselves encrypted under the Cloud KMS key,
so possession of the bucket is not possession of the master.
**SOURCE.** ICO on encrypted backups: "If you encrypt your backups, you should have
good key management in place to ensure that you can access the backup when necessary" —
and the converse duty in the same guidance:
https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/security/encryption/encryption-scenarios/
**APPLICABILITY.** SN. **Highest-leverage security finding in section 5.**

#### 5.26 The reverse: ciphertext backed up without the keys
**WHAT GOES WRONG.** The failure is symmetrical and equally fatal: segments restore
perfectly and every fact answers `:erased` because the keyring did not come along, or
came from before the subjects existed, or the Cloud KMS key lives in a project that was
deleted with the account. NIST's whole point about cryptographic erase is that key
availability *is* data availability.
**CONDITIONS.** Key backup on a different cadence, in a different system, or dependent
on an external KMS whose lifecycle you do not control.
**CLAIM + TEST.** *Claim: restore of segments + key store, on a machine with no prior
state, decrypts a known fact from every subject tier.* Test: the CI restore job must
end by reading one fact per subject and asserting plaintext, not `:erased`. A restore
that yields only `:erased` must fail the build — it is indistinguishable from total
key loss and must not be allowed to look like success.
**SOURCE.** https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r2.pdf
**APPLICABILITY.** SN.

#### 5.27 Compression or encryption makes partial recovery impossible
**WHAT GOES WRONG.** A plain append-only log degrades gracefully: lose the middle and
you still read the start. Wrap it in a stream cipher/AEAD over the whole file, or a
solid compression stream, and one damaged byte can destroy everything after it. The
SUT's per-fact data keys are the *right* shape here — damage is bounded to one fact —
but only if the framing is also per-fact. If segments are additionally
compressed/encrypted as whole objects at the backup layer, that property is lost.
**CONDITIONS.** Any whole-object transform added at the backup layer.
**CLAIM + TEST.** *Claim: corrupting k random bytes in the middle of a restored log
loses at most the facts whose byte ranges contain them.* Test: restore, flip bytes at
random offsets, re-read, assert the count of unreadable facts is bounded (ideally 1 per
flip) and that reading continues past the damage rather than aborting.
**SOURCE.** Design principle; corroborated by restic's per-pack blob framing making
damage pack-local: https://restic.readthedocs.io/en/latest/045_working_with_repos.html
**APPLICABILITY.** SN.

#### 5.28 Bit rot in cold storage that nothing ever reads
**WHAT GOES WRONG.** Cold segments are, by construction, never read until the worst
day. Object stores checksum internally and repair, but that protects the object as
stored — it does not protect against a corruption introduced *before* the checksum was
taken (bad RAM on the backup host, a bug in the segmenter), which the store will then
faithfully preserve for eleven nines of durability.
**CONDITIONS.** Checksum computed by the same process that may have corrupted the data;
no independent end-to-end digest recorded at fact-write time.
**CLAIM + TEST.** *Claim: the digest verified at restore was computed from the live log
by the writer, not by the uploader.* Test: inject a corruption *between* the log reader
and the uploader (a shim that flips a byte); assert `verify` catches it. If it does
not, the checksum is being computed downstream of the corruption and proves nothing.
Schedule a periodic scrub (S3 Batch Operations "Compute checksum" verifies at rest
without egress).
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html
**APPLICABILITY.** SN.

#### 5.29 One provider, one account, one blast radius
**WHAT GOES WRONG.** UniSuper (May 2024): a Google Cloud engineer's misconfiguration
during provisioning cancelled the private cloud subscription and deleted the fund's
backups — in *both* geographies, because the deleted thing was the subscription, not
the data. Recovery took nearly two weeks and was only possible because backups also
existed with a different provider. OVHcloud SBG2 (Mar 2021): 30,000 servers destroyed
by fire; backups held in the same building were "non-recoverable", and the Lille
commercial court later ordered OVH to pay damages for keeping backups at the same
physical location as production.
**CONDITIONS.** Backups whose survival is correlated with production's — same account,
same subscription, same building, same provider.
**CLAIM + TEST.** *Claim: at least one restorable copy survives the loss of the entire
primary cloud account.* Test: this is a tabletop/DR-drill assertion, but it can be made
falsifiable — run the restore CI job against the *secondary* target on a schedule, from
credentials scoped only to that target, and fail if it has not passed in N days.
**SOURCE.** https://www.datacenterdynamics.com/en/news/google-cloud-accidentally-deleted-unisupers-private-cloud-subscription/ ·
https://blocksandfiles.com/2023/03/23/ovh-cloud-must-pay-damages-for-lost-backup-data/
**APPLICABILITY.** SN.

#### 5.30 "Backup succeeded" metrics that lie
**WHAT GOES WRONG.** Three distinct lies, all seen in the GitLab timeline: (a) exit code
0 from a job that uploaded nothing; (b) a success metric emitted before the upload is
durable; (c) a freshness metric derived from the *job's* last run rather than the
*target's* newest object. Each makes a dashboard green over an empty bucket.
**CONDITIONS.** Any metric emitted by the backup process about itself.
**CLAIM + TEST.** *Claim: the backup-health signal is computed by reading the target,
by a process that cannot write to it.* Test: three negative tests — (a) stub the
uploader to no-op, assert red; (b) crash after PUT but before the metric, assert the
next health read is green (durability, not reporting, is the truth); (c) stop the
backup process entirely for 2× the interval, assert red.
**SOURCE.** https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
**APPLICABILITY.** SN.

#### 5.31 RPO measured from the wrong clock
**WHAT GOES WRONG.** "We back up every 5 minutes" is a statement about the scheduler.
The actual RPO is (time since the newest *durable* byte in the target). A run that
takes 7 minutes on a 5-minute schedule, or a run that stops at the last complete record
while a 40 MB fact is being written, silently widens RPO. Because the tail-truncation
rule is correct and deliberate, a single very large in-flight record can pin the
contiguous run for as long as it takes to write.
**CONDITIONS.** Variable record sizes; backup interval near or below run duration.
**CLAIM + TEST.** *Claim: `now - timestamp(last fact inside the contiguous run) ≤ RPO`
at all times.* Test: write a pathologically large fact slowly while the backup runs on
schedule; assert the measured RPO stays inside budget, or that the system alerts. This
will probably fail, and that is the point — it converts a scheduler claim into a data
claim.
**APPLICABILITY.** SN.

#### 5.32 S3-compatible is not S3
**WHAT GOES WRONG.** The design says "S3-compatible object storage". Compatibility
varies in exactly the places that matter here: multipart semantics, `ListObjectVersions`,
Object Lock support, conditional writes (`If-None-Match`), checksum algorithm support
(CRC64NVME is recent and not universal), and consistency guarantees. A test suite that
only ever runs against MinIO can pass while the production target lacks Object Lock.
**CONDITIONS.** Any non-AWS target.
**CLAIM + TEST.** *Claim: the backup tool probes the target's capabilities at startup
and refuses (or degrades loudly) when a required feature is absent.* Test: a capability
matrix test run against every supported target — assert versioning, object lock,
multipart, and the chosen checksum algorithm are each present or explicitly waived in
config with a recorded decision.
**SOURCE.** https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html
(feature set is AWS-specific) 
**APPLICABILITY.** SN.

---

### 6. ENCRYPTION, KEY MANAGEMENT AND SECURE-DELETION PITFALLS

#### 6.1 Crypto-erase is only "Purge" if the data was *never* stored in the clear
**WHAT GOES WRONG.** NIST SP 800-88 treats Cryptographic Erase as a valid sanitization
technique, but it is conditional: CE sanitizes only the *keys*, so it is a
precondition that no sensitive data was ever stored on the media in plaintext. If any
fact was written before encryption was in force — or written under a subject key that
did not yet exist — those bytes are not erased by destroying anything. **The SUT's own
stated gap ("a fact written before its subject was declared is not covered") is exactly
this NIST precondition, unmet.**
**CONDITIONS.** Any window between first write and subject declaration; any migration
that imported pre-existing facts.
**CLAIM + TEST.** *Claim: no fact exists in the log that is not covered by some subject
key.* Test: a scanner that walks the whole log and asserts every fact carries a wrapped
data key resolving to a declared subject; assert count of uncovered facts == 0. This
turns a documented gap into a monitored, falsifiable number — and the number should be
printed on every `verify`.
**SOURCE.** https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r2.pdf
(Rev.1, withdrawn 26 Sep 2025, at
https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-88r1.pdf)
**APPLICABILITY.** SN. **Highest-leverage crypto claim in the section.**

#### 6.2 CE also requires that the key never left the boundary
**WHAT GOES WRONG.** Destroying a key sanitizes data only if no copy of that key exists
anywhere else. In a three-tier envelope scheme the copies multiply: the subject key
exists wrapped in the key store, in every backup of the key store, in the memory of any
process that unwrapped it, in any cache, and possibly in a support export. NIST's CE
guidance presupposes controlled key custody; without it, "erased" is a claim about one
copy.
**CONDITIONS.** Key store backed up whole (as here), key caching, key export paths.
**CLAIM + TEST.** *Claim: the set of locations holding subject-key material is
enumerable, and destruction visits all of them.* Test: after an erasure, assert (a) the
live keyring has no entry, (b) an in-process cache lookup returns nothing, (c) a freshly
restored key store from the *previous* backup, after tombstone reconciliation, also has
no entry, and (d) — the one that will fail — that the previous key-store *object itself*
in the bucket does not contain the key. See 6.14.
**SOURCE.** https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r2.pdf
**APPLICABILITY.** SN.

#### 6.3 GCP KMS cannot destroy a key immediately — "erasure is immediate" is false at the top tier
**WHAT GOES WRONG.** Google Cloud KMS does not allow immediate destruction. A key
version enters `DESTROY_SCHEDULED` for a configurable duration: **default 30 days,
minimum 24 hours** (the minimum is 0 only for import-only keys), and the duration is
fixed at key-creation time and cannot be changed afterwards. During that window the
version is restorable. Google's docs further note that after the state becomes
`DESTROYED`, logical deletion has *started* and material may persist in Google systems
for up to 45 days total.
**CONDITIONS.** Any erasure claim whose chain of custody terminates at a Cloud KMS key,
rather than at a key you hold. Note the SUT destroys the *subject* key, not the KMS key —
so this bites only for whole-tenant/whole-master destruction, and for the KMS key's own
lifecycle.
**CLAIM + TEST.** *Claim: the system's erasure guarantee does not depend on destroying
a Cloud KMS key version, and any operation that does is documented as taking ≥24h.*
Test: assert the erasure path performs no `DestroyCryptoKeyVersion` call. Separately,
assert the KMS key was created with an explicit `destroy_scheduled_duration` and record
it — because it cannot be changed later.
**SOURCE.** https://docs.cloud.google.com/kms/docs/destroy-restore ·
https://docs.cloud.google.com/kms/docs/key-states
**APPLICABILITY.** SN. **Surprising and load-bearing for any "immediate erasure" claim.**

#### 6.4 Restoring the key store from before an erasure — and the reconciliation that is only as good as the tombstones
**WHAT GOES WRONG.** The design is right: the keyring reconciles against tombstone facts
every time it opens, so an older key store is corrected. The failure modes are in the
seams. (a) If the tombstone fact itself was never backed up (it lives past the
contiguous run — see 5.4/5.31), a restore gets the old key store *and* no tombstone,
and the erasure is undone. (b) If reconciliation happens at open but the key store is
readable by any path that does not go through open, the correction is bypassed. (c) If
a tombstone is written but the erasure is not idempotent, replaying tombstones on an
already-erased store may error and abort reconciliation partway.
**CONDITIONS.** Restore from a backup whose contiguous run predates the tombstone;
partial reconciliation.
**CLAIM + TEST.** *Claim: for every erasure, the tombstone fact is durable in the
backup target before (or atomically with) the key destruction.* Test: erase a subject,
then immediately restore both log and key store from the backup taken *just before* the
erasure; assert the subject reads `:erased`. Then the adversarial version: restore from
a backup taken *between* the key destruction and the tombstone's inclusion in the
contiguous run; assert the subject reads `:erased` (it must not resurrect). If ordering
is key-destroy-then-tombstone, this test will fail — invert the order.
**APPLICABILITY.** SN. **Highest-leverage correctness test for the erasure design.**

#### 6.5 Non-committing AEAD: a ciphertext that decrypts under two keys
**WHAT GOES WRONG.** AES-GCM is not key-committing. It is feasible to construct a
ciphertext that decrypts successfully under multiple keys to different plaintexts. Len,
Grubbs and Ristenpart's *Partitioning Oracle Attacks* (USENIX Security 2021) built key
multi-collisions for AES-GCM (and XSalsa20/Poly1305, ChaCha20/Poly1305) and used them to
recover secrets in ~m + log k queries where an oracle reveals whether decryption
succeeded. AWS's own SDK treats key commitment as a best practice and, since v2.0.x,
`RequireEncryptRequireDecrypt` is the default — a ciphertext without commitment
"might actually contain different data keys, each encrypted by a different wrapping key",
so one reader gets `0x0` and another `0x1`.
**CONDITIONS.** Any place a fact's ciphertext can be decrypted under a caller-influenced
or multiply-valid key, and the *success or failure* of that decryption is observable.
An `:erased` vs plaintext distinction is exactly such an oracle.
**CLAIM + TEST.** *Claim: it is infeasible to construct a fact whose ciphertext decrypts
successfully under two different subject keys.* Test: use a published GCM key
multi-collision construction to build a two-key ciphertext, insert it as a fact, and
assert the reader rejects it — which requires a commitment string or a KDF binding the
key identity into the tag. Also: rate-limit or make uniform the timing/response of
decrypt failures so `:erased` is not a partitioning oracle.
**SOURCE.** https://www.usenix.org/system/files/sec21-len.pdf ·
https://docs.aws.amazon.com/encryption-sdk/latest/developer-guide/concepts.html#key-commitment
**APPLICABILITY.** SN.

#### 6.6 The wrapped key travels beside the ciphertext with nothing binding them
**WHAT GOES WRONG.** In the SUT, a per-fact data key wrapped by the subject key travels
*inside* the fact. If the wrapping is unauthenticated, or authenticated without binding
to the fact's identity, then an attacker (or a bug) can move a wrapped key from fact A
onto fact B, or move a whole fact between subjects/tenants. Decryption succeeds; the
fact now appears under the wrong subject — which also means it will not be erased when
the right subject is erased.
**CONDITIONS.** Wrapped-DEK-beside-ciphertext with no AAD carrying (subject id, fact id,
offset, log lineage).
**CLAIM + TEST.** *Claim: swapping a wrapped data key, or an entire ciphertext, between
two facts causes decryption to fail.* Test: encrypt fact A and fact B under the same
subject; swap ciphertext bodies; assert both fail. Swap wrapped keys; assert both fail.
Then across subjects. Then re-write a fact at a different offset; assert failure if
offset is in the AAD.
**SOURCE.** AWS KMS on encryption context as AAD: "cryptographically bound to the
ciphertext so that the same encryption context is required to decrypt the data … defends
against an attacker replacing one ciphertext with another":
https://docs.aws.amazon.com/kms/latest/developerguide/encrypt_context.html
**APPLICABILITY.** SN. **Cheap test, catches a whole class.**

#### 6.7 AAD that is not verified by the caller
**WHAT GOES WRONG.** Even when AAD is used, AWS warns that in most language bindings
decrypt *returns* the encryption context rather than enforcing it: "The decrypt function
in your application should always verify that the encryption context in the decrypt
response includes the encryption context in the encrypt request (or a subset) before it
returns the plaintext data." A reader that decrypts successfully and then trusts the
subject id it read *out of the fact* has verified nothing — the AAD only proves the
ciphertext was made with *some* context, not the one you expected.
**CONDITIONS.** Decrypt-then-read-metadata ordering.
**CLAIM + TEST.** *Claim: the reader passes the expected subject id into decrypt and
fails closed on mismatch; it never derives the subject from the decrypted output.*
Test: craft a fact whose in-band subject label says S1 but whose AAD says S2; assert
the read for S1 fails rather than returning plaintext.
**SOURCE.** https://docs.aws.amazon.com/encryption-sdk/latest/developer-guide/concepts.html#encryption-context
**APPLICABILITY.** SN.

#### 6.8 GCM nonce reuse is catastrophic, not gradual
**WHAT GOES WRONG.** Two messages under the same (key, IV) let an adversary recover the
GHASH authentication subkey H from the tags and XOR the ciphertexts — Joux's "forbidden
attack", raised against the NIST draft in 2006. Böck, Zauner et al. found 184 live HTTPS
servers repeating nonces, fully breaking authenticity, plus >70,000 using random nonces
and therefore exposed to birthday collisions. GCM provides *no* confidentiality and *no*
integrity under nonce reuse — it is not a degradation.
**CONDITIONS.** Random 96-bit nonces at volume, or a counter that resets (restore from
backup! process restart! a restored key store with a stale counter!). Note the specific
hazard here: **restoring a key store resets any nonce counter stored with it, while the
ciphertexts written since remain.** Kopia hit precisely the random-nonce-reuse concern
in 2025.
**CLAIM + TEST.** *Claim: no (key, nonce) pair is ever used twice, including across
restore.* Test (a): a fuzz/property test that encrypts millions of facts and asserts the
nonce set is a set. Test (b) — the important one: back up, write 10k more facts, restore
the *old* key store, write more facts, and assert no nonce collides with one already on
disk. If nonces are counter-based and the counter lives in the key store, this fails.
Mitigations: derive the nonce from the fact's byte offset (unique by construction in an
append-only log), or use a per-fact key so each key encrypts exactly one message, or use
a nonce-misuse-resistant mode (AES-GCM-SIV, RFC 8452).
**SOURCE.** https://www.usenix.org/system/files/conference/woot16/woot16-paper-bock.pdf ·
https://csrc.nist.gov/csrc/media/projects/block-cipher-techniques/documents/bcm/comments/800-38-series-drafts/gcm/joux_comments.pdf ·
https://github.com/kopia/kopia/issues/5169
**APPLICABILITY.** SN. **The restore-resets-the-counter case is the surprising one.**

#### 6.9 Random 96-bit nonces have a message budget
**WHAT GOES WRONG.** With random 96-bit IVs, collision probability follows the birthday
bound; NIST SP 800-38D constrains the number of invocations with a given key when IVs
are generated randomly (the widely-cited working limit is ~2^32 messages per key for a
2^-32 collision probability). A per-subject key that encrypts every fact for a long-lived
subject can approach this; a per-fact key cannot.
**CONDITIONS.** One key encrypting many messages with random nonces.
**CLAIM + TEST.** *Claim: no single key is used for more than the configured message
budget, and the system refuses (or rotates) at the limit.* Test: set the budget to a
small number in test config, encrypt budget+1 facts under one key, assert the system
rotates or errors rather than silently continuing.
**SOURCE.** https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf ·
https://www.usenix.org/system/files/conference/woot16/woot16-paper-bock.pdf
**APPLICABILITY.** SN. The SUT's per-fact data key design already largely avoids this —
assert it rather than assume it.

#### 6.10 GCM's per-invocation plaintext limit
**WHAT GOES WRONG.** GCM's counter is 32 bits when a 96-bit IV is used, capping a single
invocation at 2^32−2 blocks ≈ 64 GiB (SP 800-38D states 2^39−256 bits). A fact larger
than that — a blob, an attachment, a bulk import written as one record — cannot be
encrypted as a single GCM message. Implementations that wrap and continue produce
counter overlap.
**CONDITIONS.** Unbounded fact size.
**CLAIM + TEST.** *Claim: fact size is bounded below the AEAD's per-invocation limit,
and an over-limit fact is rejected at write time with the limit named.* Test: attempt to
write a fact of limit+1 bytes (or a scaled-down configured limit); assert a clean
rejection, not a truncation or a silent chunking.
**SOURCE.** https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf
**APPLICABILITY.** SN.

#### 6.11 Wrapping key reuse across tiers / no hierarchy versioning
**WHAT GOES WRONG.** With master→subject→fact, three things go wrong quietly: (a) the
same master wraps every subject key forever, so master compromise is total and
undetectable; (b) there is no version tag on a wrapped key, so after a master rotation
nothing can tell which master version produced a given wrapped subject key — decryption
is by trial, and old backups become undecryptable when an old master is retired;
(c) a wrapped key produced under master v1 and stored beside a fact written under v2
looks identical.
**CONDITIONS.** Rotation of any tier without a version identifier in the wrapped blob.
**CLAIM + TEST.** *Claim: every wrapped key carries the identifier of the exact key
version that wrapped it, and the unwrapper selects by that identifier rather than
trying keys.* Test: rotate the master, write new facts, assert old facts still decrypt
*and* that the code path selected v1 explicitly (instrument it). Then delete v1 and
assert old facts fail with a *named* "missing master version v1" error rather than a
generic decrypt failure.
**SOURCE.** AWS KMS handles this internally — "When you use the rotated KMS key to
decrypt ciphertext, AWS KMS uses the key material that was used to encrypt it… You
cannot select a particular key material for decrypt operations":
https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
**APPLICABILITY.** SN.

#### 6.12 Rotation that does not re-wrap, and the belief that it did
**WHAT GOES WRONG.** AWS states it plainly: "Key rotation has no effect on the data
that the KMS key protects. It does not rotate the data keys that the KMS key generated
or re-encrypt any data protected by the KMS key. Key rotation will not mitigate the
effect of a compromised data key." Teams routinely enable rotation and record it as
remediation for a suspected key compromise. It is not.
**CONDITIONS.** Any compliance control that says "keys rotated annually" over an
envelope scheme.
**CLAIM + TEST.** *Claim: after a rotation, the number of subject keys still wrapped
under the previous master version is reported, and a re-wrap operation exists and is
tested.* Test: rotate; assert a `rewrap` command re-wraps all subject keys and that
afterwards zero keys reference the old version; assert old backups still restore
(re-wrap must not invalidate the key-store backups that predate it).
**SOURCE.** https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
**APPLICABILITY.** SN.

#### 6.13 Rotation that breaks old backups
**WHAT GOES WRONG.** The inverse of 6.12. A re-wrap or a key-store format change makes
the *current* key store good and every archived key store un-openable by the current
code. Discovered only during a restore, i.e. during an outage. AWS KMS avoids this by
retaining all key material for `AWS_KMS`-origin keys "even if key rotation is disabled"
and deleting it only when the KMS key is deleted.
**CONDITIONS.** Any key-store schema or wrapping change.
**CLAIM + TEST.** *Claim: the current binary can open every key-store version still
inside the retention window.* Test: keep golden key-store fixtures from each released
format version in the repo; a CI test opens all of them and decrypts a known fact.
Adding a format version without adding a fixture must fail the build.
**SOURCE.** https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
**APPLICABILITY.** SN.

#### 6.14 Keys backed up whole, every run — the erasure hole
**WHAT GOES WRONG.** The design backs up the key store **whole, every run**, and keeps
old backups (that is the point of versioning/retention). Destroying a subject key
therefore destroys one live copy while N historical copies of that same key sit in the
bucket. The tombstone reconciliation repairs a key store *when it is opened by this
system* — it does nothing to a key-store object read directly by an auditor, an
attacker, a subpoena, or a future engineer with `aws s3 cp`. Under NIST's CE
preconditions and under the ICO's "put beyond use" test, that copy defeats the erasure
claim.
**CONDITIONS.** Retained historical key-store backups + key-destruction-based erasure.
This is a genuine tension between 5.1 (never-restored backups) and 6.1 (CE preconditions)
and it must be resolved deliberately.
**CLAIM + TEST.** *Claim: after erasing subject S, no retained artifact anywhere
contains material sufficient to decrypt S's facts.* Test: enumerate every key-store
object version in the bucket, pull each, and attempt to unwrap S's key from each;
assert zero successes. **This test will fail on the current design.** Candidate
resolutions to test instead: (a) re-wrap and re-upload the key store on erasure and
hard-expire prior versions (weakens ransomware protection); (b) store subject keys under
a per-subject KMS-held wrapping key so destroying that KMS key version neutralises every
historical copy — at the cost of 6.3's 24h–30d delay and one key version per subject;
(c) keep an append-only *revocation* layer whose absence makes the key store unusable.
**SOURCE.** https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r2.pdf ·
https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/individual-rights/individual-rights/right-to-erasure/
**APPLICABILITY.** SN. **The single highest-leverage finding in this document.**

#### 6.15 ICO: erasure *does* extend to backups, and the standard is "beyond use"
**WHAT GOES WRONG.** The common belief that backups are exempt is wrong. The ICO:
"If a valid erasure request is received and no exemption applies then you will have to
take steps to ensure erasure from backup systems as well as live systems." It then
gives the pragmatic accommodation: "It may be that the erasure request can be instantly
fulfilled in respect of live systems, but that the data will remain within the backup
environment for a certain period of time until it is overwritten. The key issue is to
put the backup data 'beyond use'… you must ensure that you do not use the data within
the backup for any other purpose." And: "You must be absolutely clear with individuals
as to what will happen to their data when their erasure request is fulfilled, including
in respect of backup systems." The four "beyond use" safeguards (from the ICO's deletion
guidance) are: not used to inform any decision about the individual; not disclosed to
any other organisation; surrounded by appropriate technical and organisational security;
and a commitment to permanent deletion when it becomes possible.
**CONDITIONS.** Any GDPR/UK-GDPR-scoped deployment.
**CLAIM + TEST.** *Claim: after erasure, no restore path can surface S's plaintext — and
the retention schedule guarantees the last copy is overwritten within a stated period.*
Test: (a) restore from the oldest retained backup, run the normal open path, assert
`:erased`; (b) assert the bucket's noncurrent-version expiry ≤ the period disclosed to
data subjects; (c) assert the disclosure text exists and names that period — a docs test.
**SOURCE.** https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/individual-rights/individual-rights/right-to-erasure/ ·
https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/data-protection-principles/a-guide-to-the-data-protection-principles/storage-limitation/
**APPLICABILITY.** SN. **The "commit to permanent deletion when possible" safeguard maps
directly onto the retention schedule — which makes it testable.**

#### 6.16 EDPB: encrypted personal data is still personal data
**WHAT GOES WRONG.** The EDPB's blockchain guidelines address key-deletion-as-erasure
directly and do not endorse it as a clean answer. Para 51: encrypting before storing
means "upon deletion of this decryption key, the encrypted data will be unintelligible,
**at least until the algorithm is broken, the decryption techniques advance sufficiently
to allow the decryption of the cipher text, or if the key had already been compromised
or leaked**. The EDPB recalls that encrypted personal data is still personal data and
encryption does not remove the need for GDPR compliance. Further, even state-of-the-art
encryption perfectly implemented will be overtaken by time if the [ledger] is retained
indefinitely." Paras 102–104: erasure must be complied with *by design*; data must be
"effectively rendered anonymous"; and it is "not advisable to register personal data" in
clear text, encrypted **or hashed** form on an immutable chain — store it off-chain.
Recommendation 16: technical implementation choices cannot restrict data-subject rights.
**CONDITIONS.** An immutable append-only log holding personal data, which is precisely
the SUT.
**CLAIM + TEST.** *Claim: the erasure story is stated with its residual-risk caveats
(algorithmic break, prior key leak, indefinite retention) and the log has a bounded
lifetime.* Test: assert a retention/expiry mechanism exists for the log itself, not just
for backups — an append-only log kept forever is, on the EDPB's reading, a growing
liability. Also assert an inventory: which fact kinds hold personal data at all
(the EDPB's preferred answer is "none on-chain").
**SOURCE.** https://www.edpb.europa.eu/system/files/2026-07/edpb_guidelines_202502_blockchain_v2_en.pdf
(paras 51, 63, 102–104, Rec. 16)
**APPLICABILITY.** SN. **Directly on point for a fact-log that never rewrites.**

#### 6.17 Encryption-with-key-retained is pseudonymisation, not anonymisation
**WHAT GOES WRONG.** WP29 Opinion 05/2014 (WP216) lists "encryption with secret key" as
a *pseudonymisation* technique, not an anonymisation one: "in the hands of the controller
at least, the original data are still available or deducible". EDPB Guidelines 01/2025 on
Pseudonymisation continue this line. So a fact whose key you still hold is personal data
for you; a fact whose key you have destroyed is arguably anonymised *for you* — and that
is the whole legal weight of the design. The CJEU's judgment in *EDPS v SRB* (C-413/23 P,
4 Sep 2025, on appeal from General Court T-557/20) confirms the **relative/contextual**
approach: whether pseudonymised data is personal depends on the means reasonably likely
to be used *by the party in question*. That helps the design — but it also means the
answer changes per recipient, and any party who holds a key copy (see 6.14) holds
personal data.
**CONDITIONS.** Any claim that erased facts are "anonymous".
**CLAIM + TEST.** *Claim: the system can enumerate every party with access to any key
tier, and that list is short and audited.* Test: an access-review assertion — the set of
principals with `kms:Decrypt` on the Cloud KMS key, plus read on the key-store bucket,
matches a committed allowlist; drift fails the build.
**SOURCE.** WP216 (Opinion 05/2014 on Anonymisation Techniques) ·
https://www.edpb.europa.eu/system/files/2025-01/edpb_guidelines_202501_pseudonymisation_en.pdf ·
CJEU C-413/23 P *EDPS v SRB* (4 Sep 2025), on appeal from T-557/20
**APPLICABILITY.** SN.

#### 6.18 CNIL's position: key destruction gets you "substantially equivalent", not equivalent
**WHAT GOES WRONG.** CNIL's blockchain analysis accepts that rendering data inaccessible
by cryptographic means can approach the effect of erasure — deleting the secret key of a
keyed hash, or the encryption key — while stating these are solutions that *approach*
compliance and whose equivalence must be assessed case by case. The CNIL's stronger
advice is not to put personal data in clear on an immutable structure at all. The
practical reading: crypto-shredding is a defensible answer, not a settled one, and it
must be documented as a reasoned assessment rather than asserted.
**CONDITIONS.** EU deployment; DPIA required for an immutable personal-data store.
**CLAIM + TEST.** *Claim: a written assessment exists mapping the erasure mechanism to
Art. 17, with residual risks named.* Test: a docs-presence test in `just check` — the
assessment file exists, names the algorithm and key sizes in use, and its recorded
algorithm/key-size values match what the code actually uses (parse both, compare).
That last part makes a compliance doc falsifiable instead of decorative.
**SOURCE.** https://www.cnil.fr/fr/technologies/blockchain-et-rgpd-quelles-solutions-pour-un-usage-responsable-en-presence-de-donnees-personnelles ·
AEPD technical note on blockchain and the right to erasure:
https://www.aepd.es/guias/Tech-note-blockchain.pdf
**APPLICABILITY.** SN.

#### 6.19 Cached data keys defeat erasure
**WHAT GOES WRONG.** Any cache of unwrapped subject or data keys — an LRU in the reader,
a memoized keyring, a connection-pooled worker — keeps answering after the key is
destroyed. The system reports erasure complete; reads keep returning plaintext until the
cache expires or the process restarts. AWS's data key caching feature is explicit that
reuse is a security/performance tradeoff bounded by max-age, max-messages and max-bytes.
**CONDITIONS.** Any key caching, including implicit caching in an ORM/pool.
**CLAIM + TEST.** *Claim: erasure invalidates all caches synchronously; a read issued
immediately after erasure returns `:erased`.* Test: warm the cache by reading S's facts,
erase S, read again *in the same process, with no restart, with no sleep*; assert
`:erased`. Then the multi-process version if there is more than one reader.
**SOURCE.** https://docs.aws.amazon.com/encryption-sdk/latest/developer-guide/data-key-caching.html
**APPLICABILITY.** SN. **Cheap, and it is the one people forget.**

#### 6.20 Key material in memory, swap and core dumps
**WHAT GOES WRONG.** Halderman et al., *Lest We Remember* (USENIX Sec 2008 / CACM 2009):
DRAM retains contents for seconds after power loss, longer when cooled, so keys survive
in RAM after the OS believes them gone. More mundanely: a process holding an unwrapped
master key will write it to swap, to a core dump, or to a crash-reporter payload. This is
CWE-226 (sensitive information uncleared before release). Mitigations are `mlock`,
disabled core dumps, and non-optimizable wipes (`explicit_bzero`, `sodium_memzero`) —
a plain `memset` on a dead buffer is legally removable by the compiler.
**CONDITIONS.** Any long-lived process holding unwrapped key material — which the SUT's
node is by construction.
**CLAIM + TEST.** *Claim (a): core dumps are disabled and swap is disabled or encrypted
on the node. Claim (b): key buffers are zeroed with a wipe the compiler cannot elide.*
Test (a): assert `RLIMIT_CORE == 0` at startup and that `/proc/swaps` is empty or the
swap device is dm-crypt; refuse to start otherwise. Test (b): in a test build, hold a
known 32-byte sentinel key, drop it, force a heap scan of the process' own memory, assert
the sentinel is absent. (Best-effort but it catches the compiler-elided-memset bug.)
**SOURCE.** https://dl.acm.org/doi/10.1145/1506409.1506429 · CWE-226
**APPLICABILITY.** SN.

#### 6.21 Key material in logs and error messages
**WHAT GOES WRONG.** Wrapped keys, and occasionally unwrapped ones, end up in debug
output: a struct printed with a derived `Debug`/`inspect`, an exception carrying the
failing input, a request tracer capturing an unwrap call. AWS warns specifically that
encryption context "is displayed in plaintext… and might appear in plaintext in audit
records and logs, such as AWS CloudTrail" — which is the *intended* case; the unintended
case is the key beside it. Logs are then shipped, retained, and backed up, outliving the
key they should never have contained.
**CONDITIONS.** Any structured logging over types that contain key material.
**CLAIM + TEST.** *Claim: no key material can be rendered by the logging path.* Test:
give key types a redacting formatter and assert `format(key)` contains no byte of the
key; then a broader test that runs the full write/read/erase flow with logging at max
verbosity and greps the entire captured log for the sentinel key bytes (hex, base64, raw)
— assert zero hits. Same test over any crash dump produced.
**SOURCE.** https://docs.aws.amazon.com/encryption-sdk/latest/developer-guide/concepts.html#encryption-context
**APPLICABILITY.** SN.

#### 6.22 KMS is an availability dependency: the database is down when KMS is
**WHAT GOES WRONG.** A three-tier scheme rooted in a hosted KMS means every cold start,
every master unwrap, and possibly every subject-key unwrap is a network call to a service
with its own availability, its own regional scope, and its own throttling. AWS KMS
publishes per-second request quotas (symmetric cryptographic operations default 100,000/s
in the largest regions, 1,000/s for RSA/ECC; management operations have separate, much
lower quotas) and returns `ThrottlingException` when exceeded — and those quotas are
shared across everything in the account and region, including work other services do on
your behalf.
**CONDITIONS.** Per-operation KMS calls rather than one unwrap at startup.
**CLAIM + TEST.** *Claim: the node makes O(1) KMS calls per process lifetime, not O(facts);
and it continues serving reads through a KMS outage of duration D.* Test: count KMS calls
while writing 10,000 facts and assert the count is bounded by a small constant. Then
block the KMS endpoint at the network level and assert reads continue for D (and that
writes fail cleanly with a stated reason rather than hanging).
**SOURCE.** https://docs.aws.amazon.com/kms/latest/developerguide/requests-per-second.html ·
https://docs.aws.amazon.com/kms/latest/developerguide/throttling.html
**APPLICABILITY.** SN.

#### 6.23 KMS as a cost dependency: one key version per subject does not scale
**WHAT GOES WRONG.** The tempting fix for 6.14 is a KMS key (or key version) per subject
so destruction is real. AWS charges per key per month plus per request, and charges
additionally for the first and second rotation of key material (capped at the second).
GCP charges per active key version. At 10^5–10^6 subjects this dominates the bill, and
key-count quotas become a hard ceiling. The SUT's design — one KMS key wrapping a
software master wrapping many subject keys — is the cost-correct choice; the erasure
weakness in 6.14 is the price paid for it, and that tradeoff should be recorded.
**CONDITIONS.** Any proposal to move subject keys into KMS.
**CLAIM + TEST.** *Claim: the cost and quota model of the chosen key hierarchy is
computed for the projected subject count.* Test: a unit test over the cost model —
`cost(subjects=10^6)` must be under a stated ceiling, and `keys_required(10^6)` under the
provider's quota. Not a runtime test, but it makes an architectural assumption
falsifiable and it fails loudly when the projection changes.
**SOURCE.** https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
(rotation pricing) · https://docs.cloud.google.com/kms/docs/key-states
**APPLICABILITY.** SN.

#### 6.24 "Encrypted at rest" defeated because the process holds the key
**WHAT GOES WRONG.** A single node that mounts the key material and serves queries is,
from the point of view of anyone who gets code execution on that node, an oracle for all
data. Encryption at rest defends against disk theft, snapshot exfiltration and object-store
compromise — not against the node. Claiming more than that in a security page is the
failure. Note this interacts with the repo's fabrication fence: the fence is *data
access*, so a process that can see the keys can see everything the keys open.
**CONDITIONS.** Always, for a single node with mounted keys.
**CLAIM + TEST.** *Claim: the threat model document states which adversaries encryption
at rest does and does not stop, and the code matches it.* Test: assert the key store is
not readable by any OS user other than the node's; assert file modes and ownership;
assert the KMS credential is not present in the environment of any other process. These
are cheap and they at least make the boundary real.
**SOURCE.** https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/security/encryption/encryption-scenarios/
**APPLICABILITY.** SN.

#### 6.25 Deriving vs storing subject keys
**WHAT GOES WRONG.** If subject keys are *derived* (KDF(master, subject_id)) rather than
stored, then destroying a subject key is impossible — anyone with the master can
regenerate it. Crypto-erasure requires the key to be a *stored secret* that can cease to
exist. Conversely, if subject keys are stored, they must be backed up (6.14's dilemma).
This is a genuine fork and the wrong branch silently voids the entire erasure design.
**CONDITIONS.** Any KDF-based key hierarchy.
**CLAIM + TEST.** *Claim: subject keys are stored random secrets, not deterministic
functions of a retained master.* Test: destroy subject S's key, then attempt to
regenerate a key for S from the master via every code path that creates subject keys;
assert the result cannot decrypt S's existing facts (i.e. a new subject key for the same
subject id is a *different* key). If it can, erasure is a no-op.
**SOURCE.** https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r2.pdf
**APPLICABILITY.** SN. **Trivially cheap test; catastrophic if it fails.**

#### 6.26 Erasure that is observable as a side channel
**WHAT GOES WRONG.** "An old snapshot name still answers, it answers `:erased`" is a
good design — but it also confirms existence. An unauthenticated or weakly authorised
caller who can distinguish `:erased` from `:not_found` learns that a given subject
existed and was erased, which is itself personal data (and, in an adversarial setting,
a partitioning oracle per 6.5). Timing differences between "decrypt failed" and "no key"
leak the same thing more subtly.
**CONDITIONS.** Any externally reachable read path.
**CLAIM + TEST.** *Claim: an unauthorised caller cannot distinguish `:erased` from
`:not_found`, by response or by timing.* Test: measure response distributions for
existing-erased vs never-existed subject ids over 10^4 samples; assert the distributions
are statistically indistinguishable at the chosen threshold, and that the response bodies
are byte-identical for unauthorised callers.
**SOURCE.** https://www.usenix.org/system/files/sec21-len.pdf
**APPLICABILITY.** SN.

#### 6.27 Tombstones make the erasure list a permanent, growing index of erasures
**WHAT GOES WRONG.** The tombstone fact is written into the same immutable log. It
necessarily names the subject. So the log permanently records "subject X requested
erasure on date D" — a fact about a person, in an append-only structure, that cannot
itself be erased. This is the recursion the EDPB flags: the mechanism for exercising the
right creates new personal data that is subject to the same right.
**CONDITIONS.** Tombstones carrying a raw subject identifier.
**CLAIM + TEST.** *Claim: a tombstone identifies the key to destroy without identifying
the person.* Test: assert the tombstone's payload contains no direct identifier — only an
opaque key handle whose mapping to a person lives in erasable (off-log) state; then assert
that after erasure, the log alone cannot be used to recover the subject identifier. Bonus:
assert tombstones are indistinguishable from one another beyond the key handle (no
timestamps at a resolution that re-identifies via correlation with request logs).
**SOURCE.** https://www.edpb.europa.eu/system/files/2026-07/edpb_guidelines_202502_blockchain_v2_en.pdf
(paras 102–104; "personal data needs to be erased or rendered anonymous")
**APPLICABILITY.** SN. **Subtle and structural; worth a design decision, not just a test.**

#### 6.28 HSM vs software keys, and what the choice actually buys
**WHAT GOES WRONG.** A software master key in the node's memory can be read by anything
that can read the node's memory (6.20). An HSM-backed or KMS-backed key cannot be
exported — but *use* of it can be, so an attacker with code execution gets an oracle
rather than the key. The distinction matters for erasure: an exportable key can be copied
before destruction and the copy is undetectable; a non-exportable one cannot. AWS notes
that keys in custom key stores (CloudHSM) support neither automatic nor on-demand
rotation, only manual — so the hardening costs you the rotation automation.
**CONDITIONS.** Any claim that key destruction is complete.
**CLAIM + TEST.** *Claim: the master key is never present in plaintext outside the node's
address space, and the Cloud KMS key is non-exportable.* Test: assert the KMS key's
protection level and that no code path calls an export/`GetPublicKey`-style operation on
it; assert the master is never written to disk unwrapped (a filesystem-wide sentinel scan
after a full run, as in 6.21).
**SOURCE.** https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html ·
https://docs.cloud.google.com/kms/docs/key-states
**APPLICABILITY.** SN.

#### 6.29 Key loss is the mirror of key destruction, and nothing distinguishes them
**WHAT GOES WRONG.** The system's success state after erasure (`:erased`) is byte-identical
to its failure state after losing the key store. A corrupted keyring, a botched restore, a
bug that drops entries during reconciliation — all present as "everything is erased,
working as intended". Nobody investigates a system that is behaving as designed.
**CONDITIONS.** `:erased` used both for "deliberately destroyed" and "cannot decrypt".
**CLAIM + TEST.** *Claim: `:erased` is returned only when a tombstone exists for that
subject; absence of a key with no tombstone is a distinct, alerting error.* Test: delete
a subject key directly from the key store *without* writing a tombstone; assert the read
returns a distinct `:key_missing` (or similar) and raises an alert, not `:erased`. This
converts silent total key loss into a page.
**APPLICABILITY.** SN. **Very cheap, very high leverage — one enum variant.**

#### 6.30 The subject-declaration race: the SUT's own stated gap, quantified
**WHAT GOES WRONG.** "A fact written before its subject was declared is not covered."
Concretely: facts land in the log under some default/none key; the subject is declared
later; erasure destroys the subject key; those earlier facts remain readable forever.
Because the log is immutable and nothing is rewritten, there is no remediation after the
fact — only prevention. This is 6.1's NIST precondition and it is the design's known hole.
**CONDITIONS.** Any ingestion path that can write a fact naming an undeclared subject.
**CLAIM + TEST.** *Claim: it is impossible to append a fact referencing an undeclared
subject — the write fails with the repair attached ("declare subject S first").* Test:
attempt to write a fact for an undeclared subject; assert rejection. Then the concurrent
version: declare and write from two processes with an injected delay between declaration
and key materialisation; assert no fact ever lands unkeyed. Then the scanner from 6.1 as
a permanent invariant over the whole log, reported by `verify`.
**SOURCE.** https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r2.pdf ·
https://www.edpb.europa.eu/system/files/2026-07/edpb_guidelines_202502_blockchain_v2_en.pdf
**APPLICABILITY.** SN. **Prevention is the only remedy in an append-only design — which
makes the write-path assertion mandatory, not optional.**

#### 6.31 Algorithmic obsolescence over an indefinitely-retained log
**WHAT GOES WRONG.** The EDPB says it directly: "even state-of-the-art encryption
perfectly implemented will be overtaken by time if the [chain] is retained indefinitely."
Crypto-erased bytes are noise *today*. An append-only log with no retention limit is a
bet that AES-256 and the wrapping algorithms outlive the data's sensitivity, including
against store-now-decrypt-later.
**CONDITIONS.** Indefinite retention of erased-but-present ciphertext.
**CLAIM + TEST.** *Claim: the log has a maximum age after which segments are actually
destroyed, and the algorithm suite in use is recorded per fact so a future audit can find
everything encrypted under a retired suite.* Test: assert every fact carries an algorithm
suite identifier; assert a query "all facts under suite X" is answerable in bounded time;
assert a retention/compaction path exists and is exercised in CI (even if the production
policy is long).
**SOURCE.** https://www.edpb.europa.eu/system/files/2026-07/edpb_guidelines_202502_blockchain_v2_en.pdf
(para 51) · https://eprint.iacr.org/2026/1109
**APPLICABILITY.** SN.

#### 6.32 Unauthenticated wrapping of the data key
**WHAT GOES WRONG.** If the per-fact data key is wrapped with a raw block-cipher or an
unauthenticated mode rather than an AEAD/key-wrap primitive (RFC 3394 AES-KW or an AEAD
with AAD), then flipping bits in the wrapped key yields a *different valid-looking* data
key. The subsequent AEAD decrypt of the fact body will fail — usually — but the failure
is indistinguishable from `:erased` (6.29), and in a non-committing construction the
attacker gets a decryption oracle to grind against.
**CONDITIONS.** Any hand-rolled wrapping.
**CLAIM + TEST.** *Claim: bit-flipping any byte of a wrapped data key produces a
distinguishable authentication failure at the wrapping layer, before the body is touched.*
Test: for each byte position in the wrapped key, flip a bit and assert an
`invalid_wrapped_key` error — not a body decrypt failure, and never `:erased`.
**SOURCE.** https://docs.aws.amazon.com/encryption-sdk/latest/developer-guide/concepts.html
**APPLICABILITY.** SN.

#### 6.33 Signature/authorship: anyone who can decrypt can also forge
**WHAT GOES WRONG.** AWS spells this out for symmetric envelope schemes: "because AES-GCM
uses symmetric keys, anyone who can decrypt the data key used to decrypt the ciphertext
could also manually create a new encrypted ciphertext". In an *immutable fact log* whose
value proposition is that facts are authentic, a reader-level compromise is also a
writer-level forgery capability against anything not otherwise signed — and appending a
forged fact to an append-only log is indistinguishable from a genuine one after the fact.
**CONDITIONS.** Symmetric-only protection with no signature over the record.
**CLAIM + TEST.** *Claim: a party holding only decrypt capability cannot produce a fact
the reader accepts.* Test: with subject-key read access but no write credential, construct
a well-formed fact and append it; assert the reader rejects it (requires a signature, a
chained hash over the log, or a write-side MAC under a key readers do not hold).
**SOURCE.** https://docs.aws.amazon.com/encryption-sdk/latest/developer-guide/concepts.html#digital-sigs
**APPLICABILITY.** SN. Becomes far more important if the log is ever multi-writer (DIST).

---

### Cross-cutting note

Two findings pull against each other and the resolution should be an explicit,
recorded decision rather than an emergent one:

- **5.1 / 5.29** say: keep many backup copies, in more than one place, for a long time,
  and prove restores work.
- **6.1 / 6.14 / 6.15** say: every retained copy of the key store is a copy of the thing
  whose destruction *is* the erasure guarantee.

The design currently satisfies the first and pays for it in the second. The candidate
resolutions listed under 6.14 each have a different cost; whichever is chosen, the test
in 6.14 ("enumerate every retained key-store version, attempt to unwrap the erased
subject's key from each, assert zero successes") is the assertion that says whether the
erasure claim is true.

---


## Section 4 — Jobs, Clocks, Tenancy: sourced hazard claims

Research for a claims-based testing framework against an immutable append-only fact-log
database (Elixir/OTP, single node, container on a mounted volume). Vocabulary of the system
under test: **facts** accumulate in **ledgers**; a **snapshot** is ledgers read at a
transaction, named by a client-constructible map; **jobs** are the only thing that reaches
outside and the only thing a schedule attaches to; **formulas** are pure derived data;
the wire surface is `open`/`ask`/`write`/`watch`; authorization is *which ledgers a caller
may name*.

Each item: WHAT GOES WRONG · CONDITIONS · CLAIM+TEST · SOURCE · APPLICABILITY.

Applicability legend: **now** = testable against the single-node system today;
**distributed** = only bites if a second node/scheduler ever exists;
**N/A** = architecturally excluded, recorded so the exclusion is deliberate.

---

### (7) SCHEDULING AND JOB EXECUTION HAZARDS

#### 7.1 Exactly-once delivery is impossible; only exactly-once *effect* is achievable
**What goes wrong.** A job that reaches the outside world (an HTTP POST, an S3 put, a
backup upload) cannot be both guaranteed-to-happen and guaranteed-not-to-happen-twice.
The acknowledgement can be lost after the effect landed. Designing `Job` as if the runner
"just runs it once" bakes in an impossible assumption; the real choice is at-least-once
(ack after effect, duplicates possible) or at-most-once (ack before effect, loss possible).
**Conditions.** Any job with a side effect plus any crash/restart/timeout window between
performing the effect and recording the fact that it happened.
**Claim + test.** *Claim:* the job subsystem is at-least-once, not exactly-once, and the
framework must state which. *Test:* run a job whose effect is an append to an external
counter file; SIGKILL the node in the window between effect and fact-write (inject a
`:erlang.halt/0` after the effect, before the result fact); restart; assert the counter is
2 and the ledger shows one or two run-facts. Whichever it is, it is now a documented
property rather than an assumption.
**Source.** https://bravenewgeek.com/you-cannot-have-exactly-once-delivery/ ;
https://cwiki.apache.org/confluence/display/KAFKA/KIP-98+-+Exactly+Once+Delivery+and+Transactional+Messaging
**Applicability.** now.

#### 7.2 Idempotency key / dedup is the only route to effectively-once
**What goes wrong.** Without a per-run idempotency key carried into the external call, a
retried job produces a second external effect. Kafka's answer is a producer id plus a
monotonic sequence number per partition, with the broker rejecting any sequence that is not
exactly one greater than the last committed one; Stripe's answer is a client-supplied key
whose first response (including 5xx) is replayed for 24 hours, and whose *parameters* are
compared so key reuse with different arguments is an error.
**Conditions.** Retryable jobs whose external endpoint accepts an idempotency key.
**Claim + test.** *Claim:* a job retried N times produces exactly one external effect iff
the run carries a stable idempotency key derived from (job name, scheduled instant), not
from `now()`. *Test:* a fake external endpoint that records keys; force 5 retries; assert
one effect and 5 identical replayed responses. Negative test: derive the key from wall
clock and show N effects.
**Source.** https://docs.stripe.com/api/idempotent_requests ;
https://cwiki.apache.org/confluence/display/KAFKA/KIP-98+-+Exactly+Once+Delivery+and+Transactional+Messaging
**Applicability.** now.

#### 7.3 The split-brain record: effect happened, fact did not
**What goes wrong.** The classic dual-write. The job does the thing, then writes the
"I did the thing" fact in a second, non-atomic step. A crash between them makes
`Job.last_run/2` answer "never succeeded" for work that succeeded; the next scheduled tick
redoes it. Conversely, writing the fact *first* makes `last_run` claim success for work
that never happened — a silent data-integrity lie that is worse, because nothing retries.
**Conditions.** Any external effect plus any separate fact-write.
**Claim + test.** *Claim:* the ordering is effect-then-fact (so failure mode is duplicate,
never phantom-success), and this is asserted, not assumed. *Test:* fault-inject a crash at
each of the two gaps; assert that in no interleaving does `Job.last_run/2` return a success
timestamp for a run whose effect did not occur.
**Source.** https://www.confluent.io/blog/dual-write-problem/ ;
https://authzed.com/blog/the-dual-write-problem
**Applicability.** now.

#### 7.4 Missed runs: catch-up vs skip vs N-runs-on-restart is a policy, and defaults differ
**What goes wrong.** Node is down across a scheduled window. On restart the scheduler
either (a) skips silently, (b) fires once to catch up, or (c) fires once per missed
interval — a burst. With a 900s backup job and a two-day outage, (c) is 192 immediate
backup runs. Real systems disagree: Quartz `MISFIRE_INSTRUCTION_IGNORE_MISFIRE_POLICY`
explicitly produces "several rapid firings … as the trigger attempts to catch back up";
`MISFIRE_INSTRUCTION_DO_NOTHING` discards; systemd `Persistent=true` catches up with a
*single* activation regardless of how many intervals were missed; plain cron skips silently.
**Conditions.** Downtime longer than one schedule interval.
**Claim + test.** *Claim:* after a simulated downtime of K intervals, the job fires exactly
once (or exactly zero times) — pick one and assert it. *Test:* freeze/advance the scheduler's
notion of time (or stop the node, move the volume's clock forward, restart) with K=200;
count run-facts appended in the first 60s after boot.
**Source.** https://nurkiewicz.com/2012/04/quartz-scheduler-misfire-instructions.html ;
https://wiki.archlinux.org/title/Systemd/Timers ;
https://github.com/quartz-scheduler/quartz/issues/239
**Applicability.** now.

#### 7.5 Quartz's misfire *threshold* means small delays are not misfires at all
**What goes wrong.** A grace window (Quartz default `misfireThreshold` = 60000 ms) means a
trigger 30 seconds late "just runs" and is never classified as a misfire, so misfire policy
never engages and monitoring that counts misfires reports zero while jobs run late.
**Conditions.** Scheduler latency below the threshold; alerting keyed on misfire counters.
**Claim + test.** *Claim:* lateness is observable independently of misfire classification —
each run-fact records both `scheduled_at` and `started_at`. *Test:* stall the scheduler
30s; assert the run-fact shows a 30s lateness even though no misfire was recorded.
**Source.** https://nurkiewicz.com/2012/04/quartz-scheduler-misfire-instructions.html
**Applicability.** now.

#### 7.6 Kubernetes CronJob's 100-missed-schedules cliff (fail-closed, silently)
**What goes wrong.** The CronJob controller counts missed schedules since the last scheduled
time; **if more than 100 were missed it refuses to start the job at all and only logs an
error**. A long outage therefore turns a periodic job permanently off until a human notices.
`startingDeadlineSeconds` changes the counting window (missed jobs within the deadline, not
since last run), which is why an unset-or-huge deadline plus `concurrencyPolicy: Allow`
is the only combination that "always runs at least once".
**Conditions.** Any external scheduler with a catch-up cap; also a design pattern to avoid
importing.
**Claim + test.** *Claim:* the system's scheduler has no silent give-up threshold; after any
downtime the job resumes on its next tick. *Test:* simulate 500 missed intervals; assert the
next tick fires and a fact records the gap.
**Source.** https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
**Applicability.** now (as an anti-pattern claim); distributed if a k8s CronJob ever fronts it.

#### 7.7 Overlapping runs: run N+1 starts while N is in flight
**What goes wrong.** No mutual exclusion means a slow backup (say the volume is degraded and
it takes 20 minutes) overlaps the next 900s tick, then the next, until concurrent backups
contend for the same volume, doubling IO and possibly writing a torn artifact. Quantum's
`overlap` setting **defaults to true** (overlap allowed); Kubernetes offers
`concurrencyPolicy: Forbid/Replace`; Oban's answer is unique-job options.
**Conditions.** Run duration > interval; no per-job lock.
**Claim + test.** *Claim:* at most one run of a given job is in flight. *Test:* make a job
sleep 3× the interval; assert exactly one run-fact-start exists at any instant and that
subsequent ticks record a `skipped: already_running` fact rather than nothing at all.
**Source.** https://hexdocs.pm/oban/periodic_jobs.html ;
https://github.com/lau/quantum-elixir ;
https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
**Applicability.** now.

#### 7.8 The zombie job: a lease that expired while the work continued (fencing tokens)
**What goes wrong.** A runner takes a lease/lock, then pauses — GC, a stop-the-world major
collection, a blocked NIF, a hypervisor steal, or a 90-second network delay (Kleppmann cites
a real GitHub incident of roughly that length). The lease expires; a second runner starts;
the first wakes and writes. Kleppmann's central point is that you **cannot** fix this by
re-checking expiry before the write, because "GC can pause a running thread at *any* point,
including … between the last check and the write operation." The fix is a fencing token: a
monotonically increasing number issued with the lock, which the storage layer uses to reject
any write bearing a lower token.
**Conditions.** Any lease-based mutual exclusion; even single-node if a supervisor restarts a
runner while the old process is still alive in a pause.
**Claim + test.** *Claim:* a run whose lease expired cannot append a result fact. *Test:*
acquire a lease, suspend the runner process (`:erlang.suspend_process/1`), let the lease
expire, start a second runner (higher token), resume the first, assert its write is rejected
with a fencing error, not merged.
**Source.** https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
**Applicability.** now (BEAM processes can be suspended/starved; a restart mid-run reproduces
it); becomes mandatory if distributed.

#### 7.9 A supervisor restart mid-run duplicates work with no crash visible
**What goes wrong.** OTP restarts the job-runner process after an unrelated sibling crash
(`:one_for_all`) or after the runner itself raises. If the job's "started" fact is not
written before the effect, the restart looks like a fresh first run and the effect repeats.
**Conditions.** Supervision strategy that restarts the runner; effect not idempotent.
**Claim + test.** *Claim:* a runner restart during flight yields at most one effect. *Test:*
kill the runner pid mid-effect via `Process.exit(pid, :kill)`; assert external effect count
is 1 given an idempotency key, and that a `crashed` fact exists.
**Source.** https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
(pause/restart equivalence); https://blog.appsignal.com/2021/05/12/three-ways-to-avoid-duplicate-sidekiq-jobs.html
**Applicability.** now.

#### 7.10 Two schedulers (deploy overlap, or a stray dev node on the same volume)
**What goes wrong.** During a rolling deploy, or when someone runs the container locally
against the mounted production volume, two scheduler loops attach to the same job. Both fire
at t=900s. Oban's answer is leader election ("duplicate jobs never enqueued across multiple
nodes"; `@reboot` in particular "depends on leadership").
**Conditions.** Deploy overlap; operator error; volume mounted twice.
**Claim + test.** *Claim:* two processes cannot both fire the same scheduled job for the same
scheduled instant. *Test:* start two schedulers against one volume; assert exactly one
run-fact per scheduled instant, and that the loser records a `not_leader` fact.
**Source.** https://hexdocs.pm/oban/periodic_jobs.html ; https://github.com/oban-bg/oban
**Applicability.** distributed — but *reachable now* via deploy overlap and the shared volume,
so worth a claim.

#### 7.11 Poison job: a job that crashes the runner every time it is retried
**What goes wrong.** A malformed fact, an OOM-inducing payload, or a NIF segfault makes the
job kill its runner. The scheduler restarts, retries, dies again — an unbounded loop that
consumes the node and, in the BEAM case, can trip the supervisor's max-restart-intensity and
take the whole application down. Sidekiq's mitigation is: detect jobs that were running when
the process died, and after repeated occurrences move them to a dead-letter queue for manual
handling.
**Conditions.** Deterministic crash triggered by job input; retry without a cap.
**Claim + test.** *Claim:* a job that crashes its runner is quarantined after K attempts and
never retried automatically again. *Test:* register a job that calls `:erlang.halt/0`
(or raises); assert exactly K run-facts with `crashed`, then one `dead_lettered` fact, then
silence — and crucially that the *application* is still up and other jobs still run.
**Source.** https://lobste.rs/s/r2q0gg/queue_despair_ordering_poison_messages ;
https://blog.appsignal.com/2021/05/12/three-ways-to-avoid-duplicate-sidekiq-jobs.html
**Applicability.** now.

#### 7.12 A poison job that takes the supervision tree with it
**What goes wrong.** Specific to OTP: repeated crashes inside the restart intensity window
escalate to the parent supervisor, which can terminate the whole application. A poison job
therefore becomes a total outage rather than a stuck queue.
**Conditions.** Job runner supervised with default intensity; crash rate above it.
**Claim + test.** *Claim:* job crashes are isolated — the job runner's supervisor never
escalates to the top. *Test:* crash a job 100 times in 5 seconds; assert `open`/`ask` still
serve and the root supervisor's pid is unchanged.
**Source.** https://lobste.rs/s/r2q0gg/queue_despair_ordering_poison_messages (poison
message class); OTP restart-intensity behaviour is the mechanism.
**Applicability.** now.

#### 7.13 Retry amplification and backoff without jitter
**What goes wrong.** Retries multiply load at every layer they exist at; a client retrying 3×
in front of a job that retries 3× is 9× amplification. Backoff alone does not fix the
synchronized-wave problem: without jitter, all failed callers retry at the same instants,
producing repeated spikes onto a service that is trying to recover. AWS's guidance is full
jitter (spread retries uniformly across the backoff window) plus a *retry token bucket* so
retries are capped as a fraction of traffic.
**Conditions.** Retries at more than one layer; deterministic backoff.
**Claim + test.** *Claim:* retry scheduling is jittered and the total retry rate is bounded by
a token bucket. *Test:* fail 1000 job attempts simultaneously; histogram the retry instants;
assert no bucket holds more than ~2× the mean, and assert the total retry count is capped.
**Source.** https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/ ;
https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
**Applicability.** now.

#### 7.14 Thundering herd: a fleet synchronized on the 15-minute boundary
**What goes wrong.** A 900s default means every deployment of this database, everywhere,
backs up at :00, :15, :30, :45 — and against a shared destination (object store, NAS, a
metering API) they arrive as one spike. On a single node it still matters: the backup
coincides with every other :00-aligned periodic task in the container.
**Conditions.** Fixed-period schedules with no per-instance phase offset.
**Claim + test.** *Claim:* the backup job's phase is offset by a deterministic per-instance
jitter (e.g. hash of node identity mod interval), so N instances do not align. *Test:*
instantiate 100 configs with different node ids; assert the scheduled instants are spread
across the interval with no mode above 5%.
**Source.** https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/
**Applicability.** now.

#### 7.15 Metastable failure: the system does not recover after the trigger is removed
**What goes wrong.** A transient stressor (a slow volume, a burst of `ask`s) pushes the system
into a state where its own recovery work — retries, catch-up runs, re-reads — sustains the
overload after the trigger is gone. The HotOS paper frames this as **stable / vulnerable /
metastable** states, with a **trigger** and a distinct **sustaining effect**, driven by
**work amplification**; the root cause is "not a specific hardware failure or a software
bug — it is an emergent behavior." Catch-up job runs are a textbook sustaining effect.
**Conditions.** Retries or catch-up that add load proportional to failure; capacity near
saturation ("vulnerable" state).
**Claim + test.** *Claim:* after a 60s injected stall is removed, throughput returns to
baseline within a bounded time and does not settle into a degraded steady state. *Test:*
saturate, stall, release; sample throughput for 10 minutes; assert recovery. Then repeat with
catch-up enabled to demonstrate the metastable variant, proving the mitigation matters.
**Source.** https://sigops.org/s/conferences/hotos/2021/papers/hotos21-s11-bronson.pdf ;
https://brooker.co.za/blog/2021/05/24/metastable.html ;
https://www.usenix.org/publications/loginonline/metastable-failures-wild
**Applicability.** now.

#### 7.16 Unbounded job runtime with no timeout
**What goes wrong.** A job blocked on a socket with no timeout holds its lease, its slot, and
its memory forever. Nothing distinguishes "still working" from "wedged", so `Job.last_run/2`
returns a stale success and no alert fires — the job is neither succeeding nor failing.
**Conditions.** Any outbound IO without an explicit deadline.
**Claim + test.** *Claim:* every job has a hard deadline; exceeding it produces a `timeout`
result fact and releases the lease. *Test:* point a job at a black-hole TCP endpoint; assert a
`timeout` fact within deadline+ε and that the next tick can run.
**Source.** https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/
(timeout selection and deadline propagation) ;
https://sigops.org/s/conferences/hotos/2021/papers/hotos21-s11-bronson.pdf (deadline
propagation as a metastability mitigation)
**Applicability.** now.

#### 7.17 A job that outlives a deploy
**What goes wrong.** Container replacement sends SIGTERM; a long backup is either killed
mid-write (leaving a partial artifact that looks like a backup) or ignores the signal and is
SIGKILLed after the grace period. Either way the run-fact is never written, so the record says
the backup never ran even though a partial file exists. Note the repo's own ground rule:
"deploys reset in-flight work."
**Conditions.** Deploy during a run; grace period shorter than the job.
**Claim + test.** *Claim:* SIGTERM during a run causes (a) a `interrupted` fact to be appended
before exit, and (b) any partial artifact to be named such that it can never be mistaken for a
complete one (write-to-temp-then-rename). *Test:* start a slow backup, send SIGTERM, assert the
`interrupted` fact and assert no file exists at the final artifact path.
**Source.** https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ (job
lifecycle/termination); repo ground rule.
**Applicability.** now.

#### 7.18 `@reboot` semantics and the boot-time burst
**What goes wrong.** Jobs that fire on start (`@reboot`, or "run immediately on schedule
registration") turn every restart into a burst — and a crash-loop into a repeated burst. Oban
notes `@reboot` specifically depends on leadership to avoid duplicate insertion.
**Conditions.** Any run-on-start job; a crash loop.
**Claim + test.** *Claim:* a crash-loop of K restarts within one interval produces at most one
run of a run-on-start job. *Test:* restart the node 20 times in 60s; count run-facts.
**Source.** https://hexdocs.pm/oban/periodic_jobs.html
**Applicability.** now.

#### 7.19 The schedule lives in the database the job might corrupt
**What goes wrong.** If schedules are stored as facts in a ledger, a corrupted or truncated
ledger loses the schedules — including the backup schedule, which is exactly the thing that
would have let you recover. Worse, a job that writes facts can (by bug or by design) mutate
the schedule ledger, making the failure self-perpetuating.
**Conditions.** Schedule state co-located with the data it protects; no out-of-band copy.
**Claim + test.** *Claim:* the backup job's schedule is recoverable without reading the
database — from config/env — and the DB copy is an override, not the source. *Test:* corrupt
the schedules ledger; restart; assert backups still run on the configured default.
**Source.** https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
(the general lesson: the recovery mechanism must not share the failure domain)
**Applicability.** now — high leverage for this design.

#### 7.20 The backup that silently never ran (and was never restored)
**What goes wrong.** GitLab's 2017 outage is the canonical case: the backup procedure "failed
silently because notifications were sent upon failure, but due to emails being rejected there
was no indication of failure", `pg_dump` backups "never actually ran due to a misconfiguration",
and restore "was not tested on a regular basis because there was no ownership". The
`Job.last_run/2` primitive is exactly the right shape to catch this — *if* something asserts on
it.
**Conditions.** Backup failures that are logged but not alerted; no restore rehearsal.
**Claim + test.** *Claim:* a health surface fails loudly when `Job.last_run(:backup, :success)`
is older than 2× the interval, and a restore of the newest artifact into a scratch instance
reproduces a known fact. *Test:* (a) break the backup destination, assert the health check goes
red within 1800s; (b) a restore-rehearsal test in CI that restores the artifact and reads back
a canary fact.
**Source.** https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
**Applicability.** now — highest leverage item in this section.

#### 7.21 A failed run that records nothing at all
**What goes wrong.** If the result-recording path itself depends on the thing that failed (the
volume is full, so the fact cannot be appended), the failure is invisible. This is the dual of
7.3: the *failure* is the unrecorded event. `Job.last_run/2` then reports the last *success*,
with no evidence that anything has been attempted since.
**Conditions.** Full disk, read-only remount, or a write path that raises.
**Claim + test.** *Claim:* `last_run` distinguishes "no attempt since T" from "attempts failing
since T"; attempts are recorded before outcomes. *Test:* remount the volume read-only; trigger
the job; assert the health surface reports "attempted, could not record" via an out-of-band
channel (log/metric), not silence.
**Source.** https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
**Applicability.** now.

#### 7.22 Queue depth as a capacity cliff (Little's Law)
**What goes wrong.** An unbounded job/request queue converts an overload into unbounded
latency rather than an error: by Little's Law, if arrival rate exceeds service rate the queue
grows without bound and latency with it, until memory or the client's patience gives out. The
bufferbloat literature is the same phenomenon in networking — large buffers hide the signal
that capacity was exceeded.
**Conditions.** Unbounded mailbox/queue; no load shedding or backpressure.
**Claim + test.** *Claim:* queues are bounded and overflow sheds with an explicit error
carrying the repair, rather than growing. *Test:* drive arrivals at 2× service rate for 60s;
assert p99 latency stays bounded and that excess work is rejected with a typed error; assert
BEAM process mailbox length stays under a cap.
**Source.** https://www.bufferbloat.net/projects/bloat/wiki/TechnicalIntro/ ;
https://gist.github.com/rponte/8489a7acf95a3ba61b6d012fd5b90ed3
**Applicability.** now.

#### 7.23 Jobs that write facts grow the log forever and move the snapshot name
**What goes wrong.** Every job run appends result facts. At 900s, the backup job alone appends
~96 facts/day forever. Two consequences: (a) the log grows without bound with data whose value
decays to zero, and (b) each write advances the transaction, so the *current* snapshot name
changes ~96 times/day even when no user data changed — defeating client-side caching that is
keyed on "the name I cached forever" and invalidating nothing meaningful. The event-sourcing
answer is compaction/snapshotting with retention.
**Conditions.** Job bookkeeping written into the same ledger space that participates in the
default snapshot name.
**Claim + test.** *Claim:* job-run facts live in a ledger that is excluded from the snapshot
name a client caches for user data, or the log has a retention/compaction policy for them.
*Test:* run for 1000 simulated intervals with zero user writes; assert the snapshot name a
client would cache is unchanged, and assert log growth is bounded.
**Source.** https://medium.com/towardsdev/event-sourcing-and-log-compaction-3959cba0cda4 ;
https://github.com/livestorejs/livestore/issues/136
**Applicability.** now — architecture-specific, high leverage.

#### 7.24 Periodic timer drift from relative `send_after`
**What goes wrong.** `Process.send_after(self(), :tick, 900_000)` rescheduled *after* the work
completes drifts by the work duration each cycle; over a day a 5-second job pushes the backup
~8 minutes late. The Elixir docs note `send_after` time is relative to *monotonic* time by
default but also accepts `abs: true` to schedule against an absolute monotonic instant, which
is the drift-free form.
**Conditions.** Reschedule-after-work loops; non-trivial job duration.
**Claim + test.** *Claim:* scheduled instants are computed from a fixed origin (absolute
monotonic), so the k-th run's scheduled instant is `origin + k*interval` regardless of run
duration. *Test:* run 50 cycles with a job that sleeps a random 0–30s; assert
`|scheduled_k − (origin + k*interval)| < ε` and that no cumulative drift appears.
**Source.** https://hexdocs.pm/elixir/Process.html (`send_after/4`, `abs:` option) ;
https://elixirforum.com/t/process-send-after-inaccuracy-anyone-know-what-causes-it/15184
**Applicability.** now.

#### 7.25 Retry storms propagating across services
**What goes wrong.** The metastable literature's canonical instance: retries prevent the
server from responding on time, causing more client retries, and "in the worst case, the retry
storm propagates to multiple services, leading to a collapse in availability."
**Conditions.** A job calling an external service that is itself degraded.
**Claim + test.** *Claim:* a circuit breaker opens after K consecutive failures to a given
external endpoint and the job records a `circuit_open` fact instead of attempting.
*Test:* black-hole the endpoint; assert attempt rate decays to the probe rate rather than
staying at the retry rate.
**Source.** https://sigops.org/s/conferences/hotos/2021/papers/hotos21-s11-bronson.pdf
**Applicability.** now.

---

### (8) TIME AND CLOCKS

#### 8.1 Erlang/OTP: `monotonic_time` for durations, `system_time` for calendar — never mix
**What goes wrong.** Using `System.system_time/0` (or `:os.system_time/0`) to measure a
duration produces wrong or negative results when the wall clock is adjusted. OTP 18 rewrote
the time API precisely for this: `erlang:monotonic_time/0` for elapsed time,
`erlang:system_time/1` for POSIX time, `erlang:unique_integer([:monotonic])` for ordering,
with the invariant *Erlang system time = Erlang monotonic time + time offset*.
`erlang:now/0` is deprecated and, notably, **its use prevents multi-time-warp mode**.
**Conditions.** Any duration, timeout, TTL, lease, or rate limit computed from wall clock.
**Claim + test.** *Claim:* no duration in the codebase is computed from a wall-clock source.
*Test:* static — grep/AST-scan for `System.system_time`, `:os.system_time`, `DateTime.utc_now`,
`:erlang.now` appearing in subtraction; dynamic — step the container clock backwards by 60s
mid-run and assert no measured duration is negative and no lease expires early.
**Source.** https://www.erlang.org/doc/apps/erts/time_correction.html
**Applicability.** now — the single most mechanical claim in this section.

#### 8.2 `:os.system_time` ≠ `System.system_time` — two POSIX times that can disagree
**What goes wrong.** The OS's view of POSIX time and Erlang's view are distinct; under
`no_time_warp` the runtime *adjusts the frequency of its monotonic clock* (up to 1% error) to
converge on the OS time rather than jumping, so the two differ transiently. Code that mixes
them — timestamping a fact with one and comparing against the other — sees inconsistent
ordering.
**Conditions.** Mixed timestamp sources; `no_time_warp` mode (pre-OTP 26 default).
**Claim + test.** *Claim:* exactly one function produces fact timestamps, and it is named
once in the codebase. *Test:* assert a single call site; property-test that two facts written
in program order never have decreasing timestamps.
**Source.** https://www.erlang.org/doc/apps/erts/time_correction.html
**Applicability.** now.

#### 8.3 Time warp mode: `+C` and whether the code is "time warp safe"
**What goes wrong.** Under `multi_time_warp` (the default since OTP 26 / ERTS 14) the time
offset can change at any moment: `System.system_time` can jump forwards *or backwards* while
the node is running. Code that assumes monotone wall clock — e.g. "the newest fact has the
largest timestamp" — breaks. The docs are explicit that multi-time-warp requires all code to
be time-warp safe.
**Conditions.** OTP 26+ default; NTP correcting a large offset.
**Claim + test.** *Claim:* the system is time-warp safe: a `erlang:system_flag(:time_offset,
:finalize)` or a simulated offset change (run under `+C multi_time_warp` and step the host
clock) leaves ordering, leases, and TTLs correct. *Test:* boot with each of the three `+C`
modes and run the full suite; assert identical results.
**Source.** https://www.erlang.org/doc/apps/erts/time_correction.html
**Applicability.** now.

#### 8.4 Wall clock must never order transactions
**What goes wrong.** If a transaction's identity or ordering derives from wall-clock time, an
NTP step backwards reorders history; two writes in the same millisecond collide; a clock ahead
means a fact from the future shadows later real writes. Cassandra's last-write-wins is the
industry's cautionary tale: "a write with timestamp 1000 can be overwritten by a later write
with timestamp 999 if it arrives from a node with a clock that's behind."
**Conditions.** Timestamps used as identifiers, versions, or tie-breakers.
**Claim + test.** *Claim:* transaction ordering is a monotonic counter, never a timestamp;
timestamps are metadata only. *Test:* step the clock back 1 hour between two writes; assert the
second write's transaction id is still greater and the snapshot ordering is unchanged. Also
property-test that 10,000 writes inside one millisecond yield 10,000 distinct, ordered ids.
**Source.** https://aphyr.com/posts/299-the-trouble-with-timestamps ;
https://www.datastax.com/blog/2013/09/why-cassandra-doesnt-need-vector-clocks
**Applicability.** now.

#### 8.5 The response to clock skew: TrueTime / HLC (why you don't need it, stated explicitly)
**What goes wrong.** Distributed databases pay real cost for clock uncertainty: Spanner uses
GPS+atomic clocks with bounded intervals and *commit-wait*; CockroachDB/MongoDB/YugabyteDB use
Hybrid Logical Clocks — a physical part plus a logical counter that advances "when two events
share the same physical millisecond" — with a static `max_offset` (500 ms in CockroachDB).
A single-node log needs none of this, but the claim should be recorded so that adding a second
node is forced to confront it.
**Conditions.** Only if the log ever spans nodes.
**Claim + test.** *Claim:* the transaction counter is node-local and the design has no
cross-node ordering requirement; a second node would require HLC or equivalent. *Test:* an
architectural assertion test — the counter allocation function has exactly one writer.
**Source.** http://muratbuffalo.blogspot.com/2014/07/hybrid-logical-clocks.html ;
https://cse.buffalo.edu/tech-reports/2014-04.pdf
**Applicability.** distributed (record now).

#### 8.6 NTP step vs slew: the clock can jump backwards on a running node
**What goes wrong.** chrony's `makestep` jumps the clock rather than slewing it — "abruptly
jumps the clock forward or back", creating gaps or overlaps in timestamps. The common default
`makestep 1.0 3` only steps during the first 3 updates after start, but `-1` (always step) is
widely configured, and a container that has been suspended will step on resume.
**Conditions.** Large offset correction; `makestep` configured permissively.
**Claim + test.** *Claim:* a −5 s and a +5 s clock step during operation cause no negative
durations, no early lease expiry, no duplicate transaction ids, and no fact ordering inversion.
*Test:* `date -s` / `clock_settime` inside the container mid-workload; run invariants.
**Source.** https://chrony-project.org/doc/3.4/chrony.conf.html ;
https://chrony-project.org/faq.html
**Applicability.** now.

#### 8.7 Leap second 2012: the Linux kernel livelock/futex bug
**What goes wrong.** On 2012-06-30 the inserted leap second left `hrtimer`s and futexes in a
state where "the futexes repeatedly expired, re-armed, and then expired immediately again",
burning ~100% CPU in JVMs, MySQL, Firefox; a separate defect livelocked the kernel on
`xtime_lock`. The workaround was famously `date -s "$(date)"`. This is the canonical proof that
a leap second is not merely a one-second arithmetic question — it can wedge the host.
**Conditions.** Kernel with the defect + a leap second (or a re-armed leap flag).
**Claim + test.** *Claim:* the system survives a simulated leap second insertion with no
runaway CPU, no timer starvation, and no missed job. *Test:* on a disposable VM, set the
kernel's `STA_INS` via `adjtimex` before a synthetic month boundary, or use a faketime
harness; measure CPU and job timeliness across the boundary.
**Source.** https://winningraceconditions.blogspot.com/2012/07/linuxs-leap-second-deadlocks.html ;
https://access.redhat.com/errata/RHBA-2012:1199 ;
https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1020285
**Applicability.** now (host-level).

#### 8.8 Leap second 2017: Cloudflare's negative duration panic
**What goes wrong.** At the 2017-01-01 leap second, Cloudflare's RRDNS computed
`rtt := time.Now().Sub(start)` and got a **negative** value, because Go's `time.Now()` "does
not guarantee monotonicity". "A number went negative when it should always have been, at worst,
zero", causing a panic. ~0.2% of DNS queries failed at peak across 102 data centres for about
6h45m. The fix was effectively one character: refuse to record negative RTTs.
**Conditions.** Duration computed from wall clock; clock steps backwards for any reason.
**Claim + test.** *Claim:* no code path can produce or store a negative duration; durations are
clamped at 0 and the anomaly is recorded as a fact. *Test:* property test over
`duration(t0, t1)` with `t1 < t0`; assert 0 plus a `clock_went_backwards` fact, never a
negative number, never a crash.
**Source.** https://blog.cloudflare.com/how-and-why-the-leap-second-affected-cloudflare-dns/
**Applicability.** now — best single illustration of the class.

#### 8.9 Leap smear implementations differ between clouds, so two machines disagree by up to a second
**What goes wrong.** Google smears a leap second linearly over 24 hours noon-to-noon; AWS and
Microsoft adopted 24-hour smears; historically Google used a 20-hour smear while others used 24
for the 2016-12-31 leap second; Bloomberg smears over 2000 s *after* the leap; UTC-SLS over
1000 s before. "It would be helpful if the smears were the same, since the purpose of clocks is
to read the same time in different places." During a smear window, a client and the server can
disagree by up to a second — enough to reject a freshly issued token or to make a "future"
timestamp.
**Conditions.** Client and server on different NTP providers during a leap event.
**Claim + test.** *Claim:* no protocol decision depends on client and server wall clocks
agreeing to better than ±2 s (tokens, snapshot names, freshness checks all tolerate it).
*Test:* skew the client clock ±1.5 s and run the full protocol suite; assert zero failures.
**Source.** https://developers.google.com/time/smear ;
https://news.ycombinator.com/item?id=19922259
**Applicability.** now.

#### 8.10 Timezone database updates change *past* timestamps
**What goes wrong.** The tz database "frequently updates past timestamps as new information
becomes available" — 2019 corrected timestamps back to 1866; 2025a corrected Philippine
timestamps before 1900 and 1937–1990. Any fact stored as local time + zone name is therefore
*mutable*: the same stored value renders as a different instant after a tzdata upgrade, which
is a silent violation of an immutable log's core promise.
**Conditions.** Local-time storage; container base image or Elixir `tzdata` package upgraded.
**Claim + test.** *Claim:* facts store an absolute instant (UTC or monotonic-derived), never a
local time + zone; rendering is a formula, not stored state. *Test:* write facts, upgrade the
tzdata version in the test harness (pin two versions), re-read; assert every stored instant is
byte-identical and every derived rendering is recomputed rather than cached.
**Source.** https://data.iana.org/time-zones/tzdb/NEWS ;
https://developers.redhat.com/blog/2020/04/03/whats-new-with-tzdata-the-time-zone-database-for-red-hat-enterprise-linux
**Applicability.** now.

#### 8.11 tzdata updates change *future* timestamps, breaking already-computed schedules
**What goes wrong.** Governments change DST rules with weeks of notice. A schedule whose next
fire instant was computed once and stored as an absolute UTC instant becomes wrong when the
rule changes; a schedule recomputed each tick from local rules is correct but may jump.
**Conditions.** Schedules expressed in local time; rule change between computation and firing.
**Claim + test.** *Claim:* next-fire instants are recomputed from the current rule set at each
tick, and the schedule ledger records the tzdata version used. *Test:* compute a next-fire under
tzdata version A, swap to version B with a changed rule, assert the fire instant is recomputed
and a `schedule_shifted` fact is appended.
**Source.** https://data.iana.org/time-zones/tzdb/NEWS
**Applicability.** now.

#### 8.12 DST: the 1:30am that happens twice, and the 2:30am that never happens
**What goes wrong.** Fall-back makes a local time ambiguous (two distinct instants map to it);
spring-forward makes a local time nonexistent. A job at 02:30 local is skipped on the
spring-forward date; a job at 01:30 local may run twice on fall-back — and implementations
differ: Debian/Ubuntu's cron does *not* re-run fixed-time jobs that fall in the repeated hour,
but "jobs which would have run in the time that was skipped will be run soon after the change".
Wildcard jobs (`*` in hour/minute, `@hourly`) are unaffected; only fixed-time jobs are.
**Conditions.** Any local-time schedule; twice a year.
**Claim + test.** *Claim:* schedules are UTC-based (or explicitly declare their DST policy), and
on both DST boundaries a fixed-time daily job fires exactly once. *Test:* run the scheduler
against a simulated `America/New_York` clock across both 2026 transitions; assert exactly one
run-fact per calendar day.
**Source.** https://blog.healthchecks.io/2021/10/how-debian-cron-handles-dst-transitions/ ;
https://cronjob.live/docs/dst-pitfalls
**Applicability.** now.

#### 8.13 Container defaults to UTC while operators think in local time
**What goes wrong.** "Most Docker containers default to UTC" and do not inherit the host zone,
so a job an operator set for "2am" fires at a different local hour; on Alpine, setting `TZ`
does nothing at all unless `tzdata` is installed, so the setting silently has no effect.
**Conditions.** Container deployment (which is the stated deployment model); `TZ` set without
tzdata; operator reasoning in local time.
**Claim + test.** *Claim:* the system refuses to start with an ambiguous timezone
configuration: either schedules are declared UTC, or `TZ` is set *and* the zone resolves.
*Test:* boot with `TZ=America/Chicago` in a tzdata-less image; assert a startup error naming the
repair, not a silent UTC fallback.
**Source.** https://www.howtogeek.com/devops/how-to-handle-timezones-in-docker-containers/ ;
https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ (`timeZone` field)
**Applicability.** now.

#### 8.14 `CLOCK_MONOTONIC` does not advance during suspend on Linux
**What goes wrong.** POSIX says monotonic should measure elapsed real time, but on Linux
`CLOCK_MONOTONIC` "does not measure time spent in suspend"; `CLOCK_BOOTTIME` does. A container
on a laptop, a VM that is paused, or a host that suspends will therefore see monotonic time
*stall*: a 900s timer set before suspend fires 900s of awake-time later, which may be days of
wall time. An attempt to make MONOTONIC behave like BOOTTIME was merged and then **reverted**
in 4.17 because watchdogs fired unexpectedly after resume.
**Conditions.** Host suspend/resume, VM pause, laptop dev environments, live migration.
**Claim + test.** *Claim:* the system detects a suspend gap by comparing a monotonic source
against wall time, and reconciles (records a `time_gap` fact; re-evaluates schedules) rather
than silently deferring work. *Test:* `echo mem > /sys/power/state` on a test host, or pause the
container for 10 minutes (`docker pause`); assert the backup job notices it is overdue and a
`time_gap` fact is appended.
**Source.** https://lwn.net/Articles/752757/ ; https://github.com/golang/go/issues/24595 ;
https://tigerbeetle.com/blog/2021-08-30-three-clocks-are-better-than-one/
**Applicability.** now — very likely to be a real bug source here.

#### 8.15 VM live migration / resume jumps the guest clock
**What goes wrong.** "When migrating VMs, the VM is paused, not restarted, so there can be a
time difference of several seconds or more when the VM resumes"; if the *host* suspends while
the guest runs, the guest sees a time jump on host resume, and "can't detect if the system went
into suspend or not by comparing `CLOCK_BOOTTIME` and `CLOCK_MONOTONIC`" — i.e. the usual
detection trick fails for host-side suspend.
**Conditions.** Any hosted/virtualized deployment (UpCloud, per the project's deployment note).
**Claim + test.** *Claim:* a forward wall-clock jump of 10 minutes with no monotonic advance
does not cause duplicate job runs, does not expire leases held by running work, and produces one
`time_gap` fact. *Test:* freeze the container (`docker pause`) for 10 minutes; resume; assert.
**Source.** https://documentation.suse.com/sles/15-SP7/html/SLES-all/sec-kvm-managing-clock.html ;
https://www.redhat.com/en/blog/avoiding-clock-drift-vms
**Applicability.** now.

#### 8.16 Negative durations produced by a backwards clock
**What goes wrong.** Generalization of 8.8. Any `t1 - t0` can be negative; downstream code that
assumes non-negativity divides by it, uses it as a sleep, indexes a histogram with it, or
panics. In Go this required a language change (monotonic readings embedded in `time.Time`); in
Erlang the correct primitive already exists but must actually be used.
**Conditions.** Wall-clock arithmetic anywhere.
**Claim + test.** *Claim:* every duration in the system is produced by one helper that is
total: it returns `{:ok, d}` with `d >= 0` or `{:error, :clock_went_backwards}`. *Test:*
property test with adversarial clock sequences (monotone, stepped back, stepped forward,
stalled); assert no crash, no negative, and that anomalies are counted.
**Source.** https://blog.cloudflare.com/how-and-why-the-leap-second-affected-cloudflare-dns/
**Applicability.** now.

#### 8.17 TTL / expiry computed against a clock that jumps
**What goes wrong.** A cache entry, lease, or snapshot retention computed as
`wall_now + ttl` expires immediately when the clock steps forward, or never when it steps back.
Cassandra's own docs flag "potential data loss if timestamps are used for TTL calculations"
under skew.
**Conditions.** TTLs stored as absolute wall instants.
**Claim + test.** *Claim:* TTLs are evaluated against monotonic elapsed time within a process
lifetime, and against wall time only with a tolerance band across restarts. *Test:* set a 3600s
TTL; step the clock +2h; assert the entry is not treated as expired-with-loss but re-validated;
step −2h; assert it does not become immortal.
**Source.** https://drdroid.io/stack-diagnosis/cassandra-node-clock-skew
**Applicability.** now.

#### 8.18 Certificate and token expiry when the clock is wrong
**What goes wrong.** TLS validation compares system time to `notBefore`/`notAfter`; a wrong
clock makes a valid certificate look expired or "not yet valid" and the handshake fails. For a
job that must reach the outside world, a clock 25 hours slow means **every** outbound job fails
with a certificate error that reads like a server problem. Symmetrically, JWT `exp`/`nbf` checks
on the `open` path reject valid tokens (or accept expired ones) when the server clock is off.
**Conditions.** Container without NTP (containers do not run their own NTP; they inherit the
host kernel clock), or a long-suspended VM.
**Claim + test.** *Claim:* startup asserts clock sanity (offset from a trusted source below a
threshold) and outbound TLS failures are classified distinctly from certificate-expiry-due-to-
local-clock. *Test:* set the container clock 3 days back; assert startup emits a
`clock_implausible` fact and that outbound job errors carry the `local_clock_suspect` repair
hint rather than a bare TLS error.
**Source.** https://shop.trustico.com/blogs/stories/how-time-synchronization-affects-ssl-certificate-validation-why-incorrect-clocks-cause-certificate-errors ;
https://groups.google.com/a/chromium.org/g/security-dev/c/oj2xXq3CF0E
**Applicability.** now.

#### 8.19 Two writes in the same millisecond
**What goes wrong.** Millisecond (or even microsecond) resolution is not enough at write rates a
BEAM node reaches easily. Cassandra's microsecond timestamps still "don't guarantee uniqueness
in high-frequency scenarios". If a snapshot name embeds a millisecond timestamp, two distinct
transactions can produce the *same* name — and clients cache names forever, so a colliding name
serves one transaction's data under another's identity, permanently.
**Conditions.** Snapshot names or transaction ids derived from time.
**Claim + test.** *Claim:* snapshot names are collision-free by construction (counter or
content hash), independent of clock resolution. *Test:* generate 1,000,000 transactions as fast
as possible with the clock pinned to a single millisecond; assert 1,000,000 distinct names.
**Source.** https://www.datastax.com/blog/2013/09/why-cassandra-doesnt-need-vector-clocks ;
https://aphyr.com/posts/299-the-trouble-with-timestamps
**Applicability.** now — architecture-specific, high leverage.

#### 8.20 Measuring job lateness with the wrong clock hides the outage
**What goes wrong.** If "did the backup run on time?" is answered by comparing wall-clock
timestamps, a clock that jumped forward makes a late run look punctual and a clock that jumped
back makes a punctual run look impossible (negative lateness). The observability of 7.20 depends
on 8.1 being right.
**Conditions.** Health checks built on `last_run` wall timestamps.
**Claim + test.** *Claim:* lateness is computed from monotonic elapsed time since the last
recorded run, cross-checked against wall time, and a divergence between the two emits a
`clock_divergence` fact. *Test:* step the clock ±1h; assert lateness reporting stays correct.
**Source.** https://www.erlang.org/doc/apps/erts/time_correction.html
**Applicability.** now.

#### 8.21 `erlang:now/0` and legacy timestamping block the modern time model
**What goes wrong.** Beyond being deprecated, `erlang:now/0` serialized on a global lock and its
presence prevents `multi_time_warp`. Any dependency (including a library) using it constrains
the whole node's time behaviour.
**Conditions.** Legacy code or a dependency using `now/0` / `:erlang.now`.
**Claim + test.** *Claim:* no code path, including dependencies, calls `:erlang.now/0`.
*Test:* scan compiled BEAM files of all deps for the `erlang:now/0` call; fail the build on a
hit (this is a `just check`-shaped lint).
**Source.** https://www.erlang.org/doc/apps/erts/time_correction.html
**Applicability.** now.

#### 8.22 Clock stall (not jump): time stops advancing
**What goes wrong.** Under heavy steal, a hung hypervisor, or a wedged timekeeping thread,
monotonic time advances far slower than real time. Timeouts never fire; leases never expire;
the scheduler never ticks; nothing crashes, so nothing alerts. This is the failure mode that
lease-based mutual exclusion cannot detect from the inside.
**Conditions.** Virtualized host under contention.
**Claim + test.** *Claim:* an external liveness signal (a fact written by a watchdog comparing
monotonic to wall progress) detects a stall of >30 s. *Test:* `SIGSTOP` the beam process for
60 s; on resume assert a `stall_detected` fact and that in-flight leases were treated as
suspect (see 7.8 — this is exactly the fencing scenario).
**Source.** https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html ;
https://sigops.org/s/conferences/hotos/2021/papers/hotos21-s11-bronson.pdf
**Applicability.** now.

---

### (9) MULTI-TENANCY AND AUTHORIZATION FAILURES

#### 9.1 The confused deputy (the original)
**What goes wrong.** Hardy's 1988 paper: a compiler with ambient authority over a billing file
is asked by a caller to write output to that file's name, and does so — the deputy used a
permission it legitimately held, for a purpose the caller chose. "Authority should be carried by
the invoker of an action, not merely held in ambient form by the program performing the action."
A job runner that holds broad ledger access and executes work *named by* a caller is precisely
this shape.
**Conditions.** A privileged component acting on caller-supplied names.
**Claim + test.** *Claim:* a job or formula executed on behalf of a caller runs with the
*caller's* ledger authority, never the runner's ambient authority. *Test:* caller A requests
a formula that names ledger B (which A cannot read); assert refusal, and assert the refusal
happens even though the runner process can read B.
**Source.** https://dl.acm.org/doi/10.1145/54289.871709 ;
https://docs.amazonaws.cn/en_us/IAM/latest/UserGuide/confused-deputy.html
**Applicability.** now — the central claim of this whole section.

#### 9.2 Cross-service confused deputy and the ExternalId analogue
**What goes wrong.** AWS's formulation: "an entity that doesn't have permission to perform an
action can coerce a more-privileged entity to perform the action", mitigated by requiring an
`sts:ExternalId` (plus `aws:SourceArn`/`aws:SourceAccount`) in the trust policy so the deputy
can only be invoked on behalf of a caller who knows the shared secret.
**Conditions.** Jobs that call outward carrying the system's credentials on a caller's behalf.
**Claim + test.** *Claim:* an outbound job's credentials are scoped per-tenant or the request
carries a tenant-specific discriminator; one tenant cannot cause the system to act with another
tenant's outbound identity. *Test:* tenant A schedules a job; assert the outbound request
carries A's discriminator and that substituting B's ledger name in the job spec is refused.
**Source.** https://docs.amazonaws.cn/en_us/IAM/latest/UserGuide/confused-deputy.html
**Applicability.** now.

#### 9.3 BOLA / IDOR: OWASP API1:2023
**What goes wrong.** "Every API endpoint that receives an ID of an object should implement
object-level authorization checks"; attackers "manipulate the identification of an object sent
within the request … to gain unauthorized access". Ranked #1 because "the server component often
does not comprehensively track the client's state." Here every ledger name in `ask`, `write`,
`watch` is such an ID.
**Conditions.** Any operation naming a ledger.
**Claim + test.** *Claim:* for each of `open`/`ask`/`write`/`watch`, naming a ledger the caller
does not hold is refused. *Test:* a matrix test — cartesian product of {4 operations} ×
{own ledger, other tenant's ledger, nonexistent ledger, ledger name with traversal characters}
— generated automatically, so a new operation without a check fails the suite by absence.
**Source.** https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/
**Applicability.** now.

#### 9.4 Broken Function Level Authorization: OWASP API5:2023
**What goes wrong.** "Using API functionality to modify, create, update and/or delete the
resources of another user"; administrative functions are the prime target, and "an unclear
separation between administrative and regular functions" is the cause. A `write` that any
authenticated caller can issue against a ledger they can only *read* is this bug.
**Conditions.** Read and write authority conflated into one grant.
**Claim + test.** *Claim:* read authority over a ledger does not imply write authority; the
grant model distinguishes them. *Test:* grant read-only on ledger L; attempt `write`; assert
refusal. Also attempt any admin-ish operation (create ledger, grant, run job now) as a
non-admin; assert refusal.
**Source.** https://owasp.org/API-Security/editions/2023/en/0xa5-broken-function-level-authorization/
**Applicability.** now.

#### 9.5 A client-constructible snapshot name that the server trusts
**What goes wrong.** The stated shape: "a snapshot name is a plain map that a caller can
construct by hand." That makes it an unsigned, unauthenticated capability. A caller can forge a
name that (a) references a ledger they do not hold, (b) references a transaction from another
tenant's timeline, (c) mixes ledgers from two tenants in one snapshot, or (d) names a
transaction that never existed, to probe for existence. This is BOLA with a composite key, and
the composite makes it worse: a check that validates "the caller may name ledger X" but iterates
the map's *other* entries without checking is the classic partial-validation bug.
**Conditions.** Any operation accepting a snapshot name.
**Claim + test.** *Claim:* every ledger entry in a snapshot name is authorized, independently,
on every operation that accepts one. *Test:* construct names with (1 authorized + 1
unauthorized) ledger in every position (first, last, middle, duplicated key, extra unknown key);
assert refusal in all cases and that the error does not reveal whether the unauthorized ledger
exists. Property-test: for a random name, the operation succeeds iff *every* named ledger is
held.
**Source.** https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/ ;
https://dl.acm.org/doi/10.1145/54289.871709
**Applicability.** now — the highest-leverage architecture-specific claim in this section.

#### 9.6 Naming a transaction from another tenant's timeline
**What goes wrong.** If transaction identifiers are global (one counter for the node), then a
snapshot name referencing transaction T for *my* ledger still reveals information about global
write activity: by binary-searching which T values are "valid", a tenant learns the global write
rate and can infer other tenants' activity. If the identifier is guessable and the check is
"does this transaction exist" rather than "is this transaction in your visible history", it may
also allow reading a ledger state at a point the tenant should not be able to address.
**Conditions.** Global monotonic transaction ids exposed in client-constructible names.
**Claim + test.** *Claim:* naming a transaction id outside the caller's own visible history is
refused with an error indistinguishable from "no such transaction". *Test:* tenant A observes
its max T; writes as tenant B advance the global counter; A names T+1..T+50; assert uniform
refusal and constant-ish timing (see 9.11), so A cannot infer B's write rate.
**Source.** https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/
**Applicability.** now.

#### 9.7 Authorization checked in the handler, bypassed by a second door
**What goes wrong.** The check lives in the HTTP handler; the websocket path, an internal
`Job` invocation, an admin console, a replication endpoint, or a test-only backdoor reaches the
same read function directly. Every added surface is a new place to forget. The multi-tenancy
literature is blunt: "the single most consequential decision is where the tenant filter is
applied … the last row is the only one that scales, because it's the only one where adding a new
surface doesn't add a new place to get it wrong."
**Conditions.** More than one entry point into the read/write core.
**Claim + test.** *Claim:* the authorization check is inside the ledger-access function, not in
the handlers; no callable path reaches ledger data without passing a caller capability.
*Test:* a structural test — enumerate every public function that returns fact data and assert
each requires an authorization argument of the capability type (a type-level/AST assertion, not
a runtime one). Plus a runtime test that exercises every surface with an unauthorized name.
**Source.** https://agnitestudio.com/blog/preventing-cross-tenant-leakage/ ;
https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/
**Applicability.** now.

#### 9.8 RLS-style bypass: the privileged path that ignores the policy
**What goes wrong.** Postgres's version is instructive even without Postgres: "Superusers and
roles with the BYPASSRLS attribute always bypass the row security system", and **table owners
bypass RLS by default** unless `FORCE ROW LEVEL SECURITY` is set — so an app connecting as the
table owner (very common) sees every tenant despite a carefully written policy. Views owned by a
BYPASSRLS role bypass entirely. The analogue here: any internal component (backup job, compaction,
formula evaluator, migration) that reads ledgers with ambient authority.
**Conditions.** Internal components with unrestricted read.
**Claim + test.** *Claim:* every component with ambient ledger read is enumerated, justified, and
cannot return data to a caller. *Test:* an allowlist test — the set of modules holding the
"ambient read" capability is a literal list checked into the repo; adding a module fails the
build until the list is updated (same discipline as the montology collision allowlist).
**Source.** https://www.postgresql.org/docs/current/ddl-rowsecurity.html ;
https://www.bytebase.com/blog/postgres-row-level-security-footguns/
**Applicability.** now.

#### 9.9 Connection/session context leaking between requests (the pooler bug)
**What goes wrong.** "Set the tenant per request with `SET LOCAL`, never plain `SET`, or a
connection pooler will leak one tenant's context into the next request." The BEAM analogue is a
process dictionary, a `:persistent_term`, an ETS-cached "current tenant", or a long-lived
GenServer that holds caller identity in state and serves the next caller with it.
**Conditions.** Any per-request identity stored outside the request's own call stack.
**Claim + test.** *Claim:* caller identity is passed explicitly and never stored in
process-global state. *Test:* interleave requests from tenants A and B on the same connection /
same GenServer, alternating rapidly under concurrency; assert no response ever contains the
other tenant's data. Also grep for `Process.put`/`:persistent_term.put` of identity.
**Source.** https://patotski.com/blog/postgres-row-level-security-multi-tenant/ ;
https://www.bytebase.com/blog/postgres-row-level-security-footguns/
**Applicability.** now.

#### 9.10 404 vs 403: existence leaks through the error code
**What goes wrong.** "By returning a 403, you have also made it clear that the resource does
exist." An attacker enumerating ledger names distinguishes "exists but forbidden" from "does not
exist" and maps the tenant space. The nuance matters: 403 is right when the caller is *supposed
to know* the resource exists; 404 when they are not.
**Conditions.** Distinct error codes/messages for unauthorized vs nonexistent.
**Claim + test.** *Claim:* for a caller with no grant on ledger L, the response is byte-identical
whether L exists or not — same status, same body, same headers. *Test:* create L; call as
unauthorized caller; delete/never-create L; call again; assert responses are identical including
any error id/detail field.
**Source.** https://developer.mozilla.org/docs/Web/HTTP/Status/403 ;
https://authress.io/knowledge-base/articles/choosing-the-right-http-error-code-401-403-404
**Applicability.** now.

#### 9.11 Existence leaks through *timing*
**What goes wrong.** Even with identical responses, "exists but forbidden" may take longer
(a lookup happened) than "does not exist" (early return). Measured differences of ~130 ms are
routinely exploitable; the standard fix is to do the same work in both branches (dummy hash
verification for nonexistent users is the login analogue).
**Conditions.** Authorization check ordered after/before existence check inconsistently.
**Claim + test.** *Claim:* the authorization decision is made *before* any existence lookup, and
response latency distributions for existing-but-forbidden vs nonexistent are statistically
indistinguishable. *Test:* 10,000 samples of each; assert the Kolmogorov–Smirnov statistic is
below a threshold, or simply that the median difference is under the measurement noise floor.
**Source.** https://portswigger.net/web-security/authentication/password-based/lab-username-enumeration-via-response-timing ;
https://github.com/mautic/mautic/security/advisories/GHSA-3ggv-qwcp-j6xg
**Applicability.** now.

#### 9.12 The `list` operation that leaks what you cannot read
**What goes wrong.** A "list my ledgers" or "list snapshots" that returns names filtered by
existence rather than by grant leaks the namespace. Even counts leak ("you have access to 3 of
47 ledgers"). Autocomplete, error messages that echo a valid-name suggestion, and pagination
totals are all instances.
**Conditions.** Any enumeration surface.
**Claim + test.** *Claim:* every enumeration returns exactly the set the caller is granted; no
count, total, cursor, or "did you mean" reveals anything outside it. *Test:* create 50 ledgers
across 5 tenants; for each tenant assert the listed set equals the granted set exactly, and that
pagination totals equal the granted count, not the global count.
**Source.** https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/ ;
https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html
**Applicability.** now.

#### 9.13 Cross-tenant leakage through a cache keyed without the tenant
**What goes wrong.** "The most common cache failure is simple: failing to prefix keys with the
tenant_id"; "cache keys that obviously didn't need a tenant prefix are what usually cause
incidents." Cross-tenant leaks are "almost always a missing WHERE clause, a missing cache key
prefix, or a background job that loads data without the tenant context." The 2026-06-05 Claude
API incident is a recent instance of a shared caching/connection layer returning one client's
data to another.
**Conditions.** Any memoization: formula results, parsed snapshot names, compiled queries, ETS
caches.
**Claim + test.** *Claim:* every cache key includes the authorization scope that produced the
value, not just the data identity. *Test:* structural — enumerate all ETS tables/`:persistent_term`
keys used as caches and assert the key tuple includes a tenant/grant component. Dynamic — tenant
A warms a cache; tenant B issues the identical request; assert B's response is computed fresh and
A's data never appears.
**Source.** https://cside.com/blog/ai-api-shared-cache-data-leaks ;
https://agnitestudio.com/blog/tenant-aware-caching-saas/
**Applicability.** now.

#### 9.14 A formula cached by snapshot name, where the name doesn't cover authorization
**What goes wrong.** The architecture-specific version of 9.13, and the sharpest one. A formula
is pure and deterministic, so caching it by (formula, snapshot name) looks obviously correct —
*and it is, for the value*. But if the formula's output depends on which ledgers the *caller*
could see, or if the cache is consulted before the authorization check, then tenant B naming the
same snapshot gets A's computed answer without ever being authorized for the inputs. The
determinism of formulas is exactly what makes this feel safe and be unsafe.
**Conditions.** Formula memoization keyed on snapshot name; authorization checked after cache
lookup.
**Claim + test.** *Claim:* the cache lookup happens strictly *after* the authorization decision,
and the cache key includes the set of ledgers the value was computed over. *Test:* tenant A
computes formula F over snapshot S (ledgers {L1,L2}); tenant B holds only L1 and names the same
S; assert B is refused (not served from cache), and assert via instrumentation that no cache
read occurred before the refusal.
**Source.** https://cside.com/blog/ai-api-shared-cache-data-leaks ;
https://cube.dev/articles/how-to-secure-multi-tenant-embedded-analytics
**Applicability.** now — architecture-specific, highest leverage.

#### 9.15 Web cache deception / cache-key confusion at any HTTP cache in front
**What goes wrong.** If a CDN or reverse proxy is ever put in front, a URL that the cache treats
as static (by extension) but the app treats as a personalized endpoint gets a private response
stored under a public key. PortSwigger's rule: "any input that influences the response content
must be reflected in the cache key"; parser discrepancies between cache and origin let an
attacker "change the meaning of the URL". The ChatGPT account-takeover case leaked auth tokens
this way.
**Conditions.** Any HTTP cache in front of the `ask` surface.
**Claim + test.** *Claim:* every authenticated response carries `Cache-Control: private,
no-store` and the deployment forbids a shared cache in front of `ask`. *Test:* request
`/ask/foo.css`, `/ask/foo;.js`, `/ask/foo%0A.jpg` etc. with A's credentials; assert responses are
uncacheable and that path-suffix tricks do not change routing.
**Source.** https://portswigger.net/research/gotta-cache-em-all ;
https://nokline.github.io/bugbounty/2024/02/04/ChatGPT-ATO.html ;
https://arxiv.org/pdf/1912.10190
**Applicability.** now if fronted by a CDN; otherwise a deployment-constraint claim.

#### 9.16 Derived data computed across tenants
**What goes wrong.** "Caches, pre-aggregated rollups, and materialized tables are shared by
design. If they aren't scoped, they're a cross-tenant channel that no amount of correct query
filtering will close." An "average query latency" or "total facts" statistic computed globally
and served per-tenant leaks the shape of other tenants' data; with few tenants, an aggregate can
be de-anonymizing outright.
**Conditions.** Any global statistic, index, or rollup exposed to tenants.
**Claim + test.** *Claim:* no value returned to a caller is a function of facts in ledgers the
caller cannot name. *Test:* a differential test — snapshot the full response set for tenant A;
have tenant B write 10,000 facts; re-run A's full response set; assert byte-identical output
(modulo A's own writes). Any difference is a cross-tenant channel.
**Source.** https://agnitestudio.com/blog/preventing-cross-tenant-leakage/ ;
https://learn.microsoft.com/en-us/azure/data-explorer/multi-tenant
**Applicability.** now — this differential test is cheap and catches a whole class.

#### 9.17 Authorization is by ledger only, so anything crossing ledgers needs its own check
**What goes wrong.** The stated model ("which ledgers a caller may name") is sound for a single
ledger read. It says nothing about a *join*: a formula reading L1 and L2, an index spanning
ledgers, a `watch` over a pattern, or a job whose output ledger differs from its input ledgers.
The natural bug is to check the ledger being *written* and not the ledgers being *read*, or vice
versa — producing an authorized write whose content is unauthorized data.
**Conditions.** Any operation whose inputs and outputs are different ledgers.
**Claim + test.** *Claim:* for a cross-ledger operation, the caller must hold *every* input
ledger and *every* output ledger; there is no "write-only" path that copies from an unheld
ledger. *Test:* grant write on L_out and nothing on L_in; submit a formula/job that reads L_in
and writes L_out; assert refusal. Then grant read on L_in only and assert the write is refused.
**Source.** https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/ ;
https://dl.acm.org/doi/10.1145/54289.871709
**Applicability.** now — the direct consequence of the stated authorization model.

#### 9.18 `watch` authorized at subscribe time only — revocation does not stop the stream
**What goes wrong.** The single most common websocket authorization bug. In the Shopify case,
"a malicious actor could disclose & execute GraphQL operations after their permission was
revoked via WebSocket"; the token is only presented at subscribe, and "if the client side does
not disconnect the WebSocket … the client will receive the publications of its existing
subscriptions", with the industry excuse being that "it's not practical to validate the auth
token on the server before each publication."
**Conditions.** Long-lived `watch` subscriptions; grants that can be revoked.
**Claim + test.** *Claim:* revoking a grant terminates in-flight `watch` subscriptions on that
ledger within a bounded time (assert a specific bound, e.g. before the next emitted fact).
*Test:* open a `watch` on L as tenant A; revoke A's grant on L; write a fact to L; assert A
receives no message and the subscription is closed with a typed reason.
**Source.** https://medium.com/@blackarazi/unauthorized-users-could-disclose-information-and-execute-graphql-operations-after-permission-961094edf7c8 ;
https://www.apollographql.com/docs/graphql-subscriptions/authentication
**Applicability.** now — likely a real bug; the `watch` operation makes it structural.

#### 9.19 Token expiry not enforced after the websocket upgrade
**What goes wrong.** The token is validated at `open`; the connection then lives for hours or
days. The token's `exp` passes and nothing notices. "Whether you neglect to set the expiration
time for a JWT or you set it incorrectly, your JWT will be treated as non-expiring."
**Conditions.** Auth at upgrade only; long-lived connections.
**Claim + test.** *Claim:* a connection whose credential has expired is closed at or before
`exp`, and no operation is served after it. *Test:* open with a token expiring in 5 s; wait 10 s;
issue `ask`; assert refusal and connection close, not a served response.
**Source.** https://www.akamai.com/blog/developers/the-dangers-of-the-never-expiring-jwt ;
https://www.apollographql.com/docs/graphql-subscriptions/authentication
**Applicability.** now.

#### 9.20 `alg: none` and algorithm confusion
**What goes wrong.** "Never let the token's own `alg` header choose which algorithm verification
uses. If you only ever issue HS256, your verifier must reject everything else — including none."
With `alg: none` accepted, an attacker edits the payload (e.g. the ledger grant list) and drops
the signature.
**Conditions.** Any JWT-shaped credential in `open`.
**Claim + test.** *Claim:* the verifier is pinned to one algorithm and rejects `none`, `HS256`
when RS256 is expected (key-confusion), and unsigned tokens. *Test:* forge tokens with
`alg: none`, `alg: NONE`, `alg: hS256`, and an RS256→HS256 confusion using the public key as the
HMAC secret; assert all four are refused.
**Source.** https://portswigger.net/web-security/jwt ;
https://portswigger.net/kb/issues/00200901_jwt-none-algorithm-supported
**Applicability.** now.

#### 9.21 Token in the query string (logged, refererred, cached)
**What goes wrong.** Browsers cannot set headers on a WebSocket handshake, so the common
workaround is `wss://host/socket?token=…`. Query strings land in access logs, proxy logs,
`Referer` headers, and browser history; a log shipped to an aggregator becomes a credential
store. Phoenix's idiom is `connect/3` params, which has the same exposure.
**Conditions.** WebSocket auth via URL parameter; any request logging.
**Claim + test.** *Claim:* credentials never appear in a URL, or if they must, they are
single-use and short-lived (a ticket exchanged at `open`). *Test:* capture the access log during
a full session; assert no substring of the credential appears. Assert a replayed ticket is
refused.
**Source.** https://hexdocs.pm/phoenix/Phoenix.Channel.html ;
https://www.akamai.com/blog/developers/the-dangers-of-the-never-expiring-jwt
**Applicability.** now.

#### 9.22 Per-topic authorization in the channel `join`, not the socket `connect`
**What goes wrong.** Phoenix's own guidance: "Your channels must implement a `join/3` callback
that authorizes the socket for the given topic." A system that authenticates at `connect` and
then lets any authenticated socket join any topic ("when a client attempts to join `user:1`
Channel, but they are user ID 2, you should reject") has authentication without authorization.
Topics are pattern-matched, so `ledger:*` subscriptions need per-name checks.
**Conditions.** Phoenix Channels or an equivalent topic-based `watch`.
**Claim + test.** *Claim:* joining a `watch` topic naming a ledger performs the same
authorization as `ask` on that ledger. *Test:* connect as A; attempt to join every ledger topic
in the system including wildcards and traversal-ish topic strings; assert only granted ones join.
**Source.** https://hexdocs.pm/phoenix/Phoenix.Channel.html
**Applicability.** now.

#### 9.23 A subscription that outlives the grant it was created under, via reconnect resume
**What goes wrong.** Resumable subscriptions (replay from a last-seen cursor after a dropped
connection) re-establish a stream from a stored cursor. If resume trusts the cursor and skips
re-authorization, a revoked caller resumes and receives everything since revocation.
**Conditions.** Any `watch` resume/replay from a client-supplied cursor — and note the cursor is
likely a snapshot name, i.e. client-constructible (9.5).
**Claim + test.** *Claim:* resume re-runs the full authorization check and additionally validates
that the cursor lies within the caller's own visible history. *Test:* subscribe, capture cursor,
revoke grant, reconnect with the cursor; assert refusal. Then re-grant and resume with a *forged*
cursor pointing into another tenant's transaction range; assert refusal.
**Source.** https://blog.platformatic.dev/resumable-graphql-subscriptions ;
https://medium.com/@blackarazi/unauthorized-users-could-disclose-information-and-execute-graphql-operations-after-permission-961094edf7c8
**Applicability.** now.

#### 9.24 Cross-tenant token/identity confusion in a shared service (AutoWarp)
**What goes wrong.** Orca's AutoWarp: Azure Automation's per-tenant sandboxes exposed a local
token endpoint on predictable ports, letting one tenant's job retrieve **another tenant's Managed
Identity token**. The parallel: a job runner shared across tenants where the credential-fetch
path is addressable from inside the job.
**Conditions.** Shared job execution environment; credentials fetched from an in-environment
endpoint.
**Claim + test.** *Claim:* a job's execution environment can obtain only its own tenant's
credentials, and the credential path is not addressable by the job's own code. *Test:* run a
hostile job that scans localhost ports and the filesystem for credential material; assert nothing
belonging to another tenant is reachable. (Reinforces the repo's existing fabrication fence:
network-blocked execution.)
**Source.** https://orca.security/resources/blog/autowarp-microsoft-azure-automation-service-vulnerability/ ;
https://www.darkreading.com/cloud-security/default-azure-automation-setting-cross-tenant-identity-takeover
**Applicability.** now.

#### 9.25 Noisy neighbour: one tenant's `ask` starves the others
**What goes wrong.** On a single BEAM node with no per-tenant quota, one tenant's expensive
formula or wide `ask` consumes schedulers, memory, and volume IO; everyone else's latency goes to
the roof. The standard controls are per-tenant statement timeouts (e.g. "Enterprise 60 s, Basic
15 s"), per-tenant connection caps, and fair queueing (SQS Fair Queues explicitly exist because
"a single 'noisy' tenant can flood the queue, starving quieter tenants").
**Conditions.** Shared execution with no per-tenant admission control.
**Claim + test.** *Claim:* under a hostile load from tenant A, tenant B's p99 latency degrades by
no more than a stated factor. *Test:* saturate with A's expensive queries; measure B's p99
against a quiet baseline; assert the ratio bound. Also assert a per-tenant concurrency cap and a
per-query deadline exist and fire.
**Source.** https://wa.aws.amazon.com/saas.question.REL_1.en.html ;
https://neon.com/blog/noisy-neighbor-multitenant ;
https://akkurtfurkan.medium.com/amazon-sqs-fair-queues-for-fairness-in-multi-tenant-environments-db70807a27be
**Applicability.** now.

#### 9.26 Memory as the cross-tenant denial channel on the BEAM
**What goes wrong.** Specific to a single-node BEAM: one tenant's unbounded `ask` result
materialized in a process heap triggers the OOM killer, killing the node for everyone. There is
no per-process memory quota by default; `max_heap_size` must be set explicitly.
**Conditions.** Unbounded result sets; no `max_heap_size` on request-serving processes.
**Claim + test.** *Claim:* a single request cannot exceed a per-request memory bound; exceeding
it kills that process with a typed error, not the node. *Test:* issue an `ask` designed to
materialize 10 GB; assert the caller receives a `result_too_large` error with the repair, other
tenants' requests continue, and the node's RSS stays bounded.
**Source.** https://neon.com/blog/noisy-neighbor-multitenant ;
https://wa.aws.amazon.com/saas.question.REL_1.en.html
**Applicability.** now.

#### 9.27 The backup job is the widest authorization hole in the system
**What goes wrong.** Backup, by nature, reads every ledger of every tenant with ambient authority
and writes them to an external destination. It is simultaneously the biggest confused deputy
(9.1), the biggest ambient-read component (9.8), and the only job whose output leaves the trust
boundary. A misconfigured destination, a destination named from a fact a tenant can write, or a
restore into the wrong instance is a total cross-tenant disclosure.
**Conditions.** Backup running every 900s with global read.
**Claim + test.** *Claim:* the backup destination is configured out-of-band and cannot be
influenced by any fact any tenant can write; backup artifacts are encrypted at rest with a key
the database does not hold; a restore requires an explicit instance identity check.
*Test:* attempt to influence the destination by writing facts containing URLs/paths; assert no
effect. Assert the artifact is unreadable without the external key. Attempt to restore instance
X's artifact into instance Y; assert refusal.
**Source.** https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html ;
https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
**Applicability.** now — highest-consequence item in this section.

#### 9.28 Job-run facts as a cross-tenant side channel
**What goes wrong.** Jobs "record their results as ordinary facts". If those facts land in a
ledger a tenant can read (or if `Job.last_run/2` is exposed without a ledger check), then job
names, timings, error messages, and target URLs from *other tenants'* jobs become readable.
Error messages are especially bad: they routinely contain the thing that failed, i.e. another
tenant's identifiers.
**Conditions.** A shared jobs ledger; `Job.last_run/2` exposed on the wire.
**Claim + test.** *Claim:* `Job.last_run/2` is subject to the same ledger authorization as `ask`,
and job result facts are partitioned by owning tenant. *Test:* tenant A queries `last_run` for a
job owned by B; assert a refusal indistinguishable from "no such job" (9.10). Assert error-detail
facts are redacted of identifiers before landing in any shared ledger.
**Source.** https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/ ;
https://owasp.org/API-Security/editions/2023/en/0xa5-broken-function-level-authorization/
**Applicability.** now — architecture-specific.

#### 9.29 A grant checked once and cached for the connection lifetime
**What goes wrong.** The dual of 9.18 for `ask`: the set of ledgers a caller may name is resolved
at `open` and cached in the socket's state for performance. Grant changes then take effect only
on reconnect — a revocation that does nothing, and (worse in the other direction) a *new* grant
the caller must reconnect to use, which trains operators to think revocation is also lazy.
**Conditions.** Grant resolution cached in connection state.
**Claim + test.** *Claim:* a grant revocation takes effect on the next operation on any existing
connection, within a stated bound. *Test:* open a connection, perform an `ask` on L successfully,
revoke, `ask` again on the same connection; assert refusal without reconnect.
**Source.** https://medium.com/@blackarazi/unauthorized-users-could-disclose-information-and-execute-graphql-operations-after-permission-961094edf7c8 ;
https://www.akamai.com/blog/developers/the-dangers-of-the-never-expiring-jwt
**Applicability.** now.

#### 9.30 Snapshot names cached "forever" outlive the authorization that produced them
**What goes wrong.** The design says clients cache snapshot names forever. A name handed to
tenant A while A held ledger L remains a valid, well-formed name after A's grant is revoked. If
any code path treats "the client presented a name we issued" as evidence of authorization —
rather than re-checking every ledger in the name on every use — revocation is unenforceable by
construction. This is why the name must be an *identifier*, never a *capability*.
**Conditions.** Any fast path that trusts a previously-issued name.
**Claim + test.** *Claim:* a snapshot name confers no authority; it is re-authorized on every use,
and an issued-then-revoked name is refused. *Test:* obtain a name as A with grant on L; revoke;
present the identical name; assert refusal. Additionally assert that a name the server never
issued but which is well-formed and names only granted ledgers *is accepted* — proving the server
does not rely on issuance, which would be a false sense of security.
**Source.** https://dl.acm.org/doi/10.1145/54289.871709 ;
https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/
**Applicability.** now — the sharpest statement of the architecture's central risk.

---

### Cross-cutting note on test construction

Three of the tests above are *generative* rather than example-based and are worth building first,
because they catch new code by construction rather than by enumeration:

1. **Operation × ledger-name matrix (9.3).** Generated from the list of wire operations, so a new
   operation with no authorization check fails by absence.
2. **Cross-tenant differential (9.16).** Snapshot tenant A's entire observable surface; have B do
   arbitrary work; re-snapshot; assert byte-identity. Any leak of any kind shows up as a diff.
3. **Adversarial clock harness (8.1, 8.6, 8.8, 8.14, 8.16).** One fixture that replays a clock
   sequence (monotone / stepped back / stepped forward / stalled / suspend-gap) under the whole
   suite, so every timing assumption is exercised against every clock pathology rather than only
   the happy one.

---


## Section 5 — Sandboxing / untrusted code, and operational / deployment hazards

Research for a claims-based test framework against LazyRiver (immutable append-only
fact-log, Elixir/OTP, single node, two-stage Docker image, volume-mounted ledger).

**One finding reframes the whole of Topic 10.** The brief describes "a sandbox" in
Elixir. `lib/lazy_river/formula/sandbox.ex` does **not** run guest code on the BEAM —
it runs it in **WebAssembly via Wasmex 0.15 (wasmtime through a Rustler NIF)**, with an
*empty* import map. That is the correct architecture and it moves most classical
BEAM-escape items to N/A-for-formulas. But it moves the risk somewhere else: the
sandbox as written configures **no fuel, no epoch deadline, and no `StoreLimits`**, so
the isolation is airtight on *capability* and wide open on *resource*. Items S20–S28
are where the real exposure is.

Items are tagged:
- **APPLICABILITY** — `single-node now` / `only if distributed` / `N/A` / `N/A for
  formulas, live for jobs` (the WASM/BEAM split above).

---

### Topic 10 — Sandboxing and untrusted code execution

#### Part A — Why in-process language sandboxes historically fail (the prior art)

##### S1. Java SecurityManager: permission-based in-process sandboxing was abandoned
**What goes wrong.** The canonical in-process sandbox — a policy layer inside the same
runtime as the untrusted code — was deprecated for removal after 25 years. The stated
reasons are the ones that generalise: making access-control decisions from permissions
is "unwieldy, slow, and falling out of favor"; it was rarely used to secure server-side
code; and it is costly to maintain. The recommended replacement is explicitly *not* a
better policy layer — it is "isolating the entire Java runtime from sensitive resources
via out-of-process mechanisms such as containers and hypervisors." JEP 486 then
permanently disabled it.
**Conditions.** Any design where untrusted code shares an address space and runtime with
trusted code and is restrained by a checked policy rather than by absence of capability.
**Claim + test.** *Claim:* LazyRiver's fence is structural (empty import map), not
policy — there is no allow/deny list anywhere in the formula path that a future commit
could widen by editing a constant. *Test:* grep the formula path for any list of
permitted operations; assert `Sandbox.imports/0` returns `%{}` and that no other
code path passes a non-empty `:links` map to `Wasmex.start_link`. Assert this in CI,
not by review — the failure mode is a later commit adding "just one" import.
**Source.** https://openjdk.org/jeps/411 · https://openjdk.org/jeps/486
**Applicability.** single-node now (as a design invariant to lock down).

##### S2. Python `rexec`/`Bastion`: introspection defeats attribute-level hiding
**What goes wrong.** `rexec` depended on class attributes staying "private" from
untrusted code. Python's introspection is heavily geared against that — there are many
"dark corners from which one can peer deep into the heart of classes." Both modules were
disabled in Python 2.3 for "various known and not readily fixable security holes" and
`Bastion` was removed in 3.0. The CPython position is that the C implementation was not
designed with security in mind and security is very hard to retrofit.
**Conditions.** Any sandbox whose boundary is "the guest cannot *name* the dangerous
thing," in a language with reflection, dynamic dispatch, or a module registry.
**Claim + test.** *Claim:* no LazyRiver sandbox control depends on the guest being
unable to name something. *Test:* the WASM guest's namespace is closed by construction
(imports it did not receive do not exist), so write the adversarial test as: a `.wat`
module that imports `env.anything` must fail at `Sandbox.mapping/3` build time with
`:wanted_something_it_was_not_given`, never at run time.
**Source.** https://docs.python.org/2.7/library/restricted.html
**Applicability.** single-node now.

##### S3. Ruby `$SAFE`/taint: a global mode flag deleted rather than fixed
**What goes wrong.** Ruby's taint/safe-level system — an ambient global that gated
dangerous operations — was deprecated in 2.7 with *no replacement*, reduced to a plain
global variable in 3.0, and the `Object#taint/untaint/trust/untrust` methods and C
functions removed in 3.2. A sandbox expressed as a mutable global process-wide mode is
one assignment away from being off.
**Conditions.** Any "we are in sandbox mode" boolean/level held in process state.
**Claim + test.** *Claim:* there is no runtime flag whose value determines whether a
formula is sandboxed. *Test:* assert there is no code path that runs a user-supplied
formula body outside `Sandbox`; specifically, assert `Formula.new/2` with a raw Elixir
closure is only reachable from trusted internal call sites, and that no HTTP surface
route accepts an Elixir term/AST as a formula body. This is the highest-value test in
the section — see S29.
**Source.** https://bugs.ruby-lang.org/issues/16131
**Applicability.** single-node now.

##### S4. Node `vm`: the runtime's own docs disclaim security
**What goes wrong.** Node's built-in isolation primitive states flatly: "The `node:vm`
module is not a security mechanism. Do not use it to run untrusted code." Teams use it
anyway because it looks like a sandbox.
**Conditions.** Adopting an isolation primitive from its API shape rather than its
security statement.
**Claim + test.** *Claim:* every isolation primitive LazyRiver depends on has a written
security model that covers the threat. *Test:* a docs/link check — assert
`sandbox.ex`'s moduledoc names wasmtime's security page and its *stated non-goals*
(side channels, Spectre; see S22). A sandbox whose limits are undocumented in-repo is
one nobody can reason about at 3am.
**Source.** https://nodejs.org/api/vm.html
**Applicability.** single-node now.

##### S5. vm2: the hardened JS sandbox died of repeated escapes
**What goes wrong.** vm2 was the "real" sandbox people moved to *from* `node:vm`. It was
broken repeatedly. CVE-2023-37466 (CVSS 9.8) escapes by bypassing Promise handler
sanitization via the `@@species` accessor; CVE-2023-37903 (CVSS 9.8) escapes via
Node's custom-inspect function, affecting all versions ≤ 3.9.19. The July 2023
disclosure led the maintainer to discontinue the project.
**Conditions.** Sandbox implemented by *wrapping and sanitizing* a rich host API surface
rather than by *not exposing* one. Every new host feature is a new escape candidate.
**Claim + test.** *Claim:* LazyRiver's guest surface has cardinality zero, so it does
not grow when the host does. *Test:* a golden test that snapshots the full set of
imports and host functions reachable from a formula, and fails on any addition. Pair
with a written rule that widening is one deliberate import at a time (already stated in
the moduledoc — make it enforced).
**Source.** https://nvd.nist.gov/vuln/detail/CVE-2023-37466 ·
https://nvd.nist.gov/vuln/detail/CVE-2023-37903
**Applicability.** single-node now.

#### Part B — BEAM/Erlang: there is no intra-node isolation

##### S6. The BEAM is explicitly not a sandbox — official position
**What goes wrong.** Erlang's own Secure Coding Guidelines state: "All loaded code is
assumed to be trusted. There is no built-in sand-boxing mechanism for running untrusted
Erlang code. Any code loaded and executed within the environment has unrestricted access
to the system." And: "a malicious BEAM module can do anything, including breaking the
memory safety protections of the runtime system and crashing the virtual machine." The
Erlang Ecosystem Foundation is blunter: "The BEAM runtime has very little support for
access control between running processes... It is therefore not possible to isolate
'untrusted' processes in some sort of sandbox," and recommends a dedicated runtime
(they name Lua; WASM is the modern equivalent).
**Conditions.** Any plan to accept Elixir/Erlang source, an AST, or a `.beam` binary
from a tenant and run it on the node.
**Claim + test.** *Claim:* no tenant-supplied artefact is ever compiled or loaded as
BEAM code. *Test:* assert no call to `Code.eval_string/2,3`, `Code.eval_quoted/2`,
`Code.compile_string/2`, `:erlang.binary_to_term/1` on request bodies, or
`:code.load_binary/3` exists anywhere outside test support. Add it to the
`--warnings-as-errors` CI job as a grep gate. **Note the process-isolation asymmetry the
same doc records:** processes *are* isolated for *fault* purposes (a crash is contained,
one process cannot block another) — which is exactly why engineers over-read it as
*security* isolation. Fault isolation ≠ privilege isolation.
**Source.** https://www.erlang.org/doc/system/secure_coding.html ·
https://security.erlef.org/secure_coding_and_deployment_hardening/sandboxing.html
**Applicability.** single-node now (a standing invariant; N/A for the WASM guest).

##### S7. Ambient authority available to any BEAM process
**What goes wrong.** Any process, with no capability handed to it, can call
`:os.cmd/1` (which "starts a shell", searches `PATH`, and expands environment
variables — the docs recommend `open_port/2` with `{spawn_executable, _}` instead),
`:erlang.halt/0` (kills the node, no supervisor sees it), the whole `File` module,
`:erlang.system_flag/2`, `Process.exit(pid, :kill)` on any pid (untrappable), sends to
any registered name, reads any `public`/`protected` ETS table, and reads/writes its own
process dictionary. None of this is gated.
**Conditions.** Any code running as a BEAM process — including a *Job*, which by design
is the thing allowed to reach the outside world.
**Claim + test.** *Claim:* Jobs are trusted operator code, not tenant code, and the
system says so. *Test:* assert the Job registration path requires an authority that a
tenant token cannot hold; write a negative test that a tenant-scoped token attempting to
register or schedule a Job gets 403 with a repair string. This is the boundary that
matters, because the fabrication fence protects *formulas* and Jobs are outside it.
**Source.** https://www.erlang.org/doc/system/secure_coding.html
**Applicability.** single-node now (Job path). Distributed: worse — a connected node has
unrestricted access to all others, and the cookie is not authentication.

##### S8. A NIF or port bypasses every guarantee above
**What goes wrong.** "A native function that crashes will crash the whole VM."
Execution is "not made in a safe environment" and the VM "cannot provide the same
services... such as pre-emptive scheduling or memory protection." The docs say "use this
functionality with extreme care." **Wasmex is itself a Rustler NIF** — so the sandbox's
own implementation is in the bypass class.
**Conditions.** Any dependency shipping native code. LazyRiver has at least
wasmex/rustler/rustler_precompiled.
**Claim + test.** *Claim:* the set of loaded NIFs and linked-in drivers is known,
pinned, and reviewed. *Test:* at boot, log `:erlang.system_info(:taints)` (the list of
modules that have loaded native code) and assert in a test that it equals an expected
allow-list. A new NIF appearing from a transitive dependency bump should fail CI. Also
assert `mix.lock` hashes are checked in (they are).
**Source.** https://www.erlang.org/doc/apps/erts/erl_nif.html
**Applicability.** single-node now.

##### S9. `binary_to_term` without `:safe` — atom table exhaustion DoS
**What goes wrong.** Atoms live in a global table, "entries are never removed," and the
table defaults to **1,048,576** entries (`+t`). Once full the VM aborts with
`system_limit` — the whole node, not one process. `binary_to_term/1` (no `:safe`)
creates atoms from the wire. So do `String.to_atom/1`, `binary_to_atom/1,2`,
`List.to_atom/1`, `Module.concat/1,2`, and atom interpolation. This is a live, currently
issued CVE class, not a museum piece: hackney turned every URL *scheme* into an atom
(CVE-2026-47067); Absinthe turned attacker-supplied GraphQL SDL names into atoms
(CVE-2026-42793). Both crash the BEAM with `system_limit`.
**Conditions.** Any attacker-influenced string reaching an atom-creating function —
attribute names, ledger names, snapshot names, JSON keys, header names, subject ids.
**Claim + test.** *Claim:* no request-derived string becomes a new atom. *Test:* (a)
static — grep for `String.to_atom`, `:erlang.binary_to_atom`, `Module.concat`,
`binary_to_term` without `:safe` outside test support; assert zero hits on the request
path. (b) dynamic — record `:erlang.system_info(:atom_count)`, replay 100k requests with
distinct random attribute/ledger/snapshot names, assert `atom_count` delta is 0. This is
a strong, cheap, high-signal test and it directly guards the naming surface LazyRiver
puts in tenants' hands. (`Application.start/2`'s moduledoc already shows awareness —
ledgers are registered under arbitrary terms in a `Registry` precisely to avoid this. The
test proves it stayed true.) Also monitor `atom_count` vs `system_info(:atom_limit)`.
**Source.** https://security.erlef.org/secure_coding_and_deployment_hardening/atom_exhaustion.html
· https://cna.erlef.org/cves/CVE-2026-47067.html ·
https://cna.erlef.org/cves/CVE-2026-42793.html
**Applicability.** single-node now. **Highest-leverage item in Topic 10 for the
non-WASM surface.**

##### S10. `:safe` does NOT prevent RCE — the deserialization class
**What goes wrong.** The `:safe` option prevents *atom creation*. It does **not** stop
function terms: "The safe option does not affect the deserialisation of functions and
other unsafe terms." An attacker-supplied anonymous function of arity 2 is especially
dangerous in Elixir because *the `Enumerable` protocol is implemented for 2-arity
functions* — so `Enum.map(deserialized, ...)` invokes attacker code without any
syntactic call. This is the Plug session-cookie RCE class (Griffin Byatt). The mitigation
is `Plug.Crypto.non_executable_binary_to_term/1,2`, which raises on unsafe terms — and
even that does not stop a crafted `Range` designed to burn CPU and memory.
**Conditions.** Any ETF crossing a trust boundary: signed cookies, cache entries, the
backup format, an inter-process wire format, a job payload.
**Claim + test.** *Claim:* LazyRiver never deserializes ETF from outside the trust
boundary; where it must (Phoenix signed session/token from `SECRET_KEY_BASE`), it uses
the non-executable variant. *Test:* (a) grep for `binary_to_term` in
`lib/lazy_river/wire.ex`, `backup*`, `snapshot.ex`; (b) an adversarial test that feeds a
`term_to_binary(fn a, b -> ... end)` payload to every deserializing entry point and
asserts a refusal, not an evaluation; (c) assert on-disk ledger/backup format is **not**
raw ETF, or if it is, that reads go through a validating decoder. **Note the direct
relationship to config:** `SECRET_KEY_BASE` is what makes a signed cookie trustworthy —
if it ever defaults, leaks, or is shared across tenants, the ETF payload inside becomes
attacker-controlled and this item becomes RCE.
**Source.** https://security.erlef.org/secure_coding_and_deployment_hardening/serialisation.html
· https://hexdocs.pm/plug_crypto/Plug.Crypto.html
**Applicability.** single-node now.

#### Part C — Resource exhaustion on the BEAM

##### S11. No per-process memory limit by default
**What goes wrong.** Erlang's own guidance: "Excessive resource usage is not prevented by
default. Unless safeguards are put in place (for example heap size limitations), a
process is free to consume enough resources to crash the whole program." `+hmax` defaults
to **0 — no maximum**. The `max_heap_size` process flag exists and takes
`%{size:, kill: true, error_logger: true, include_shared_binaries:}`; both `kill` and
`error_logger` default to `true` *once you set a size*, but nothing sets a size for you.
**Conditions.** Any single process assembling an unbounded result — a snapshot fold, a
formula answer set, a backup buffer, a large `Snapshot.find/2`.
**Claim + test.** *Claim:* the processes that can grow unboundedly carry an explicit
`max_heap_size`, and exceeding it kills that process rather than the node. *Test:* set
`Process.flag(:max_heap_size, %{size: N, kill: true})` on the Engine/Ledger/Backup
workers; write a test that asks for an absurd snapshot and asserts the *node survives*
and the supervisor restarts the worker. The documented rollout is to run with
`kill: false` first and read the error_logger reports to pick N.
**Source.** https://www.erlang.org/doc/apps/erts/erlang.html#process_flag/2 ·
https://www.erlang.org/doc/apps/erts/erl_cmd.html
**Applicability.** single-node now.

##### S12. Refc binary leak — the middleman pattern
**What goes wrong.** Binaries over 64 bytes are allocated off-heap and reference-counted;
they are freed only when *every* referencing process GCs. A "middleman" process that
routes binaries acquires a reference to each one and, if it is small and rarely GC'd,
holds them all. Sub-binaries (a slice of a larger binary) keep the *whole* original
alive. Result: RSS climbs to OOM while `erlang:memory(:processes)` looks modest.
**Conditions.** LazyRiver is a fact log — facts are binaries, and the Ledger GenServer,
the `Watchers` Registry fan-out, and the Backup worker are all middlemen by construction.
**Claim + test.** *Claim:* binary memory is bounded under sustained append + watch load.
*Test:* soak test — append 10^6 facts with 1KB values while a subscriber watches; sample
`:erlang.memory(:binary)` every 10s; assert it plateaus rather than climbs monotonically.
Use `:recon.bin_leak/1` to name the offender when it fails. Mitigations: `binary:copy/1`
on sub-binaries you retain, `hibernate` after bursts, do binary work in short-lived
processes.
**Source.** https://github.com/heroku/erlang-in-anger (ch. 7, Memory Leaks) ·
https://ferd.github.io/recon/recon.html
**Applicability.** single-node now.

##### S13. Unbounded message queue growth
**What goes wrong.** A GenServer that receives faster than it processes grows its mailbox
without limit; each message is also a GC root, so GC cost rises with queue length, which
slows processing, which grows the queue. Classic runaway. The EMQX/OTP-23 case in the
wild: a stuck process's mailbox grew until k8s OOM-killed every pod.
**Conditions.** `LazyRiver.Formula.Engine` is a single GenServer serialising *every*
formula answer for *every* ledger (`handle_call({:answer, ...})` runs `Formula.run`
**inside the server loop**). One slow formula blocks all of them and the mailbox grows.
**Claim + test.** *Claim:* a slow formula does not stall unrelated formulas. *Test:*
register formula A that sleeps 30s and formula B that is instant; call A from one
process, then B from another; assert B answers in <100ms. **This will currently fail** —
computation happens in `reply_with_answer/3` on the server. Fix is to compute in a `Task`
and reply asynchronously, or shard the engine. Also alarm on
`Process.info(pid, :message_queue_len)` for the Engine and each Ledger.
**Source.** https://www.erlang.org/doc/system/secure_coding.html (resource usage) ·
https://github.com/emqx/emqx/issues/8765
**Applicability.** single-node now. **High leverage — this is a correctness-visible
availability bug in checked-in code, not a hypothetical.**

##### S14. Scheduler starvation via long-running NIF / tight BIF
**What goes wrong.** "If a NIF takes 300ms, then the NIF will block a scheduler for
300ms," delaying every job assigned to that scheduler. The BEAM's pre-emption is by
reduction counting, which native code does not participate in. The remedies are
`enif_schedule_nif` chunking or a dirty scheduler.
**Conditions.** Wasmex executes guest code inside a NIF. A guest that loops forever holds
a scheduler thread (see S24).
**Claim + test.** *Claim:* a formula cannot degrade unrelated request latency. *Test:*
run a CPU-burning WASM formula on a loop; concurrently measure p99 latency of a trivial
`/append` request; assert it stays within 2× baseline. Instrument with
`:msacc` (microstate accounting) or `:scheduler.sample/0` utilisation.
**Source.** https://www.erlang.org/doc/apps/erts/erl_nif.html
**Applicability.** single-node now.

##### S15. ETS: no memory ceiling, and access rights are coarse
**What goes wrong.** ETS tables grow until the node dies; there is no per-table quota. A
`public` table is readable *and writable* by any process on the node; `protected` is
readable by any process. The `+e` table-count limit is documented as "partially obsolete"
and is not the limit you want anyway.
**Conditions.** Any ETS used for caching, sessions, or a symbol/attribute table.
**Claim + test.** *Claim:* every ETS table in the system is `private` unless a comment
justifies otherwise, and every cache has an eviction policy with a bound. *Test:*
enumerate `:ets.all/0` at boot and assert each table's `:protection` and that each has a
documented owner; separately assert `Formula.Engine`'s cache honours its `:cache` bound
(default 256) under 10k distinct snapshot names — that one *is* bounded and evicts
oldest-first, so this test should pass and lock the behaviour in.
**Source.** https://www.erlang.org/doc/apps/stdlib/ets.html ·
https://www.erlang.org/doc/apps/erts/erl_cmd.html
**Applicability.** single-node now.

##### S16. Port and file-descriptor limits
**What goes wrong.** `+Q` (max ports) defaults to **65,536**, raised toward the process
fd limit if the runtime can determine it is higher (Windows: 8,196; range
1,024–134,217,727). Every socket, every open file, every `os:cmd` is a port. Exhaustion
manifests as `emfile`/`system_limit` on *accept* — the node is up, the health check may
pass, and nothing new can connect. `+P` (max processes) defaults to **1,048,576**.
**Conditions.** A ledger-per-tenant design opening file handles at runtime, plus one
socket per connected watcher.
**Claim + test.** *Claim:* the node degrades legibly rather than silently at fd
exhaustion. *Test:* run with `ulimit -n 256`, open ledgers until failure, and assert
(a) the error returned to the caller names the limit and the repair, (b) the node stays
up, (c) existing ledgers keep serving. Export `erlang:system_info(:port_count)` /
`:process_count` against their limits in Vitals.
**Source.** https://www.erlang.org/doc/apps/erts/erl_cmd.html
**Applicability.** single-node now.

#### Part D — Non-determinism leaking into supposedly pure code

This is the section that decides whether "cached by snapshot name" is *correct* or merely
*fast*. The cache in `Formula.Engine` is keyed `{formula.id, Snapshot.name(snapshot)}`
with **no invalidation** — the moduledoc argues, correctly, that a name cannot go stale.
That argument holds **only if the compute function is a pure function of the snapshot**.
Every item below is a way for that premise to be false.

##### S17. Map iteration order is not insertion order and is not stable
**What goes wrong.** Elixir/Erlang maps change representation at **32 keys** — a flatmap
below, a hash-array-mapped trie at and above. Iteration order is not insertion order at
any size, and the order at ≥32 keys is a function of key hashing. Elixir's own docs state
maps "do not guarantee the order of their contents." Order is stable *within* a
version — not across them.
**Conditions.** A formula (or the host code assembling its answer) folds over a map and
the output depends on order: building a list, concatenating, subtracting floats,
picking "the first" of something.
**Claim + test.** *Claim:* no answer's value depends on map iteration order. *Test:*
property test — for a formula whose input has ≥40 attributes, build the input map by
inserting keys in N random permutations and assert byte-identical answers. Then the
brutal one: build the same map with 31 keys and with 33 keys (adding then removing one)
and assert the ordering-sensitive path agrees. The 32-key boundary is where this bug
hides, because every fixture written by a human has fewer than 32 keys.
**Source.** https://hexdocs.pm/elixir/Map.html · https://www.erlang.org/doc/system/expressions.html
**Applicability.** single-node now.

##### S18. `term_to_binary` is not canonical — do not use it as a cache key or hash
**What goes wrong.** The external term format specifies the *layout* of `MAP_EXT` pairs
but makes **no stability guarantee across releases**. EEP-18 is explicit: conversion is a
pure function *within a particular Erlang version*, but "different Erlang releases may
change the order of pairs, so you cannot expect exactly the same term from release to
release." Compiled match specs additionally round-trip to node-specific references that
may or may not still be valid. So `:crypto.hash(:sha256, :erlang.term_to_binary(term))`
is a *version-dependent* identity.
**Conditions.** Any content-addressed identity: a snapshot name derived from content, a
fact id, a dedupe key, a backup manifest checksum, an idempotency key.
**Claim + test.** *Claim:* no persisted identifier is derived from `term_to_binary`.
*Test:* (a) grep; (b) a golden-vector test — check in the hex digest of the identity of
a fixed 40-key map computed under the pinned OTP (27.3.4.4 per the Dockerfile) and assert
equality. That test *should fail loudly on an OTP bump*, which is the point: it converts a
silent cache-identity split into a red build. If the ledger is content-addressed this is
a **format-compatibility** issue too and belongs in O10.
**Source.** https://www.erlang.org/doc/apps/erts/erl_ext_dist.html ·
https://www.erlang.org/eeps/eep-0018
**Applicability.** single-node now.

##### S19. Term ordering: cross-type order, and integer/float conflation
**What goes wrong.** Erlang defines a total-ish order across types:
`number < atom < reference < fun < port < pid < tuple < map < nil < list < bit string`.
Sorting a heterogeneous answer set therefore groups by *type* before value, which is
almost never what a user means. Worse, `<` conflates integers and floats — `5 == 5.0`
is true, so `lists:usort` can drop one of them non-obviously and *which* one it keeps
depends on input order. Maps use a *different* order for keys: integers sort before
floats, so `#{2 => a} < #{1.0 => a}` is true. Sorting an attribute-name string vs an
atom is likewise not lexicographic.
**Conditions.** Any formula or query returning a sorted result over mixed-type answers.
**Claim + test.** *Claim:* every ordering LazyRiver exposes is defined by an explicit
comparator, not by `<` on raw terms. *Test:* assert `sort([1, 1.0, :a, "a", %{}])` in the
answer path produces a documented order, and property-test that `usort` never silently
collapses `1` and `1.0` into an arbitrary one of the two.
**Source.** https://www.erlang.org/doc/system/expressions.html ·
https://erlangforums.com/t/total-term-order/2477
**Applicability.** single-node now.

##### S20. `:rand` auto-seeds — an unseeded generator is non-deterministic per process
**What goes wrong.** "If the process dictionary has no stored implicit state,
`seed(default)` is called to create an automatic seed" — designed to be *unique to the
created generator instance*. So a formula (or host helper) calling `:rand.uniform/1`
without seeding gets a different sequence in every process, every run. Separately,
`normal/0,2` involve floating-point math that "on different platforms with different math
library implementations, optimizations, compilation flags such as gcc's `-ffast-math`"
may produce slightly different values — and those differences can change a recursive
retry path so "the produced sequences may derail and get out of sync."
**Conditions.** Any sampling, jitter, shuffling, or tie-breaking inside a cached
computation.
**Claim + test.** *Claim:* no cached computation calls `:rand`. *Test:* grep, plus a
runtime trap — in the test env, wrap the formula call in a process where
`:erlang.trace` or a `:meck`-style stub on `:rand` raises. Cleanest structural version:
because formulas are WASM with an empty import map, they *cannot* reach `:rand` at all
(that is the fence working). So this claim is really about the **host-side** compute
functions built with `Formula.new/2` — see S29.
**Source.** https://www.erlang.org/doc/apps/stdlib/rand.html
**Applicability.** single-node now (host-side); N/A for WASM guests.

##### S21. The other ambient non-determinism sources, enumerated
**What goes wrong.** Each of these is a pure-looking call that is not:
`System.monotonic_time/0` and `System.system_time/0` (wall clock; and see O16 on time
warps), `self()` and `node()` (PID text and node name change every boot and every
deploy), `make_ref/0` (unique per node incarnation), `System.unique_integer/0,1`
(monotonic *within a VM incarnation only* — resets on restart), process scheduling order
where results are assembled from concurrent tasks, locale/encoding (`LANG`/`LC_ALL` —
the Dockerfile pins `C.UTF-8`, which is correct and should be asserted), float printing
(`float_to_list/1` defaults to `{scientific, 20}`; the `short` option arrived in OTP 25
and OTP explicitly declined to change the default because "some applications might depend
on the default output being this specific format"), and float non-associativity —
`(a+b)+c ≠ a+(b+c)` — so a sum's value depends on fold order, which depends on S17.
**Conditions.** Any of the above inside a function whose result is cached by name.
**Claim + test.** *Claim:* `Formula.run/2` is a function of the snapshot alone. *Test:*
the **double-run differential test** — run every registered formula twice in *different
processes*, on *different nodes* (`--sname a` / `--sname b`), with the system clock
shifted by an hour between runs, and assert byte-identical answers. One test, catches
clock, PID, node name, ref, unique_integer, and most scheduling order at once. Add a
third run under a different `LANG` to catch locale.
**Source.** https://www.erlang.org/doc/apps/erts/time_correction.html ·
https://github.com/erlang/otp/pull/4719 (float `short`, and the refusal to change the
default) · https://www.erlang.org/doc/apps/erts/erlang.html
**Applicability.** single-node now. **Highest-leverage determinism test in the section.**

##### S22. WebAssembly's own non-determinism: NaN payloads and relaxed-SIMD
**What goes wrong.** WASM is *mostly* deterministic, not entirely. When a float operator
produces a NaN from non-NaN inputs, "the sign bit of the NaN result value is
nondeterministic"; with any non-canonical NaN input the payload "is picked
non-deterministically." Relaxed-SIMD instructions are non-deterministic *by design* —
"given the same inputs, two calls to the same instruction can return different results."
Memory/table `grow` "are allowed to non-deterministically succeed or fail" below the
declared maximum. Wasmtime *can* be configured deterministic
(`cranelift_nan_canonicalization`, disabling relaxed-SIMD, pre-allocating max memory,
fuel instead of epochs) — but none of that is on by default, and **Wasmex 0.15's
`EngineConfig` exposes none of those knobs** (it exposes `consume_fuel`,
`cranelift_opt_level`, `wasm_backtrace_details`, `debug_info`, `memory64`,
`wasm_component_model`).
**Conditions.** A formula doing float arithmetic that can produce NaN, or compiled with
SIMD. LazyRiver's `mapping/3` currently filters `is_integer(fact.answer)` so floats are
excluded *today* — the moment that widens to floats, this is live.
**Claim + test.** *Claim:* formula answers are bit-identical across machines. *Test:*
run the CI formula suite on x86_64 and arm64 runners and diff the answers byte-for-byte.
Until NaN canonicalization is reachable through Wasmex, **refuse float-valued formulas at
build time** and make that a tested refusal with a repair string.
**Source.** https://github.com/WebAssembly/design/blob/main/Nondeterminism.md ·
https://docs.wasmtime.dev/examples-deterministic-wasm-execution.html ·
https://hexdocs.pm/wasmex/Wasmex.EngineConfig.html
**Applicability.** single-node now.

##### S23. The cache key omits the code version — stale answers under a re-registered formula
**What goes wrong.** `Formula.Engine` keys its cache on `{formula.id, Snapshot.name}`.
`Engine.register/2` is a public API that overwrites `state.formulas[formula.id]` **while
leaving `state.kept` untouched**. Re-register formula `"doubling"` with a new WASM body
and every previously-cached snapshot still answers with the *old* code's output. The
moduledoc's correctness argument — "an answer at a named snapshot is the same answer
forever" — is true of *(data, code)*, and only the data half is in the key. This is the
same bug Bazel had (remote cache poisoning when the C++ compiler changed but the action
key did not) and Go had (module `go` version missing from the build cache key, causing
"spuriously-successful builds ... and there is no workaround for spurious success").
**Conditions.** Any re-registration, hot upgrade, or restart-with-new-code where the
formula id is stable and the body is not.
**Claim + test.** *Claim:* answering formula `F` at snapshot `S` after `F`'s body changes
returns the new body's answer. *Test:* register `id: :f` returning `x*2`; answer at
snapshot S; `register` `id: :f` returning `x*3`; answer at S again; assert the second
answer is `x*3`. **This test fails today.** Fix: make the key
`{formula.id, code_digest, Snapshot.name}` where `code_digest` is a hash of the WASM
bytes (or of the compute closure's module+fun+line for host formulas), or purge
`state.kept` entries for `formula.id` on register. Prefer the digest — purging loses the
"a miss costs time, never correctness" property under rollback.
**Source.** https://github.com/bazelbuild/bazel/issues/9296 ·
https://github.com/golang/go/issues/37804
**Applicability.** single-node now. **Highest-leverage finding in Topic 10.**

#### Part E — The WASM sandbox as actually configured

##### S24. No fuel and no epoch deadline: a guest infinite loop is unbounded
**What goes wrong.** Wasmtime prevents runaway guests with *fuel* (deterministic,
instruction-counted, traps at zero) or *epoch interruption* (wall-clock, cheaper, ~10%
overhead, non-deterministic). Wasmex's `EngineConfig` defaults `consume_fuel: false`, and
"a `Wasmex.Store` starts with no fuel." `Sandbox.mapping/3` calls bare
`Wasmex.Store.new()` — no engine config, no fuel, no epoch. So
`(loop $l (br $l))` in a formula runs forever inside a NIF. `Wasmex.call_function/4`'s
5000ms default timeout is a **GenServer call timeout**: it makes the *caller* give up; it
does not stop the guest. The guest keeps burning a scheduler thread (S14) with no owner
watching. Note wasmtime's own guidance for the determinism-sensitive case: "use
deterministic fuel-based interruption rather than non-deterministic epoch-based
interruption" — which matters here because LazyRiver caches answers, and an
epoch-interrupted formula could trap on one run and succeed on the next.
**Conditions.** Any tenant-supplied formula. It requires no cleverness — a `while(1)`.
**Claim + test.** *Claim:* a non-terminating formula is refused within a bounded time and
leaves no running work behind. *Test:* build a `.wat` with an infinite loop, call
`Formula.run`, assert (a) an error refusal with a repair string within N seconds, (b)
`:erlang.system_info(:process_count)` and scheduler utilisation return to baseline within
5s, (c) a second, ordinary formula still answers. Fix: `EngineConfig.consume_fuel(true)` +
`StoreOrCaller.set_fuel/2` with a per-formula budget — and make the fuel budget part of
the cache key, because a formula that traps out of fuel at 10^6 and succeeds at 10^7 has
two different answers.
**Source.** https://docs.wasmtime.dev/examples-interrupting-wasm.html ·
https://hexdocs.pm/wasmex/Wasmex.EngineConfig.html ·
https://hexdocs.pm/wasmex/Wasmex.StoreOrCaller.html
**Applicability.** single-node now. **Highest-leverage finding in Part E.**

##### S25. No `StoreLimits`: guest linear memory is unbounded
**What goes wrong.** `Wasmex.StoreLimits` controls `:memory_size` ("the maximum number of
bytes a linear memory can grow to"), `:table_elements`, `:instances`, `:tables`,
`:memories`. The docs state: "By default, linear memory will not be limited."
`Sandbox.mapping/3` passes no limits. A guest that calls `memory.grow` in a loop
allocates host memory until the BEAM is OOM-killed by the cgroup (O14) — taking the
ledger's in-flight appends with it.
**Conditions.** Any tenant formula.
**Claim + test.** *Claim:* a formula cannot allocate more than a stated budget. *Test:*
a `.wat` that grows memory unboundedly; assert it traps with a refusal naming the limit,
the node survives, and RSS returns to baseline. Fix:
`Wasmex.Store.new(%Wasmex.StoreLimits{memory_size: N, instances: 1, memories: 1,
tables: 1})`.
**Source.** https://hexdocs.pm/wasmex/Wasmex.StoreLimits.html
**Applicability.** single-node now.

##### S26. Store lifetime: "no form of GC is implemented"
**What goes wrong.** Wasmex's own docs: "A Store is intended to be a short-lived object...
No form of GC is implemented at this time so once an instance is created within a Store it
will not be deallocated until the Store itself is garbage collected. This makes Store
unsuitable for creating an unbounded number of instances." `Sandbox.mapping/3`'s compute
closure creates a **fresh Store, recompiles the module, and `Wasmex.start_link`s a new
guest GenServer on every evaluation** — and never calls `GenServer.stop` on it. Because
`start_link` links to the caller (the long-lived `Formula.Engine`), each cache miss leaks
one linked GenServer plus its Store plus a recompiled module. On the compile path
`instantiable/2` *does* stop the probe pid correctly; the run path does not.
**Conditions.** Every cache miss. Bounded by the 256-entry cache only in the sense that
misses are unbounded — 10k distinct snapshot names is 10k leaked guests.
**Claim + test.** *Claim:* evaluating a WASM formula N times leaves no residue. *Test:*
record `:erlang.system_info(:process_count)` and `:erlang.memory(:total)`, run a mapping
formula against 1,000 distinct snapshot names, force GC, assert process count returns to
baseline ±5 and memory plateaus. **This test fails today.** Fix: `GenServer.stop(guest)`
in an `after`, or hoist compile-once/instantiate-per-run, or run the guest in a
`Task.Supervisor` child that dies with the evaluation.
**Source.** https://hexdocs.pm/wasmex/Wasmex.Store.html
**Applicability.** single-node now. **Second-highest-leverage in Part E.**

##### S27. Wasmtime's sandbox has had real escapes — pin and watch
**What goes wrong.** The WASM boundary is strong but not infallible. CVE-2023-26489
(Cranelift, x86_64): an address-mode lowering bug computed a **35-bit** effective address
instead of WASM's defined 33-bit, letting guest code read/write up to ~34GB from the base
of linear memory — a guest-controlled OOB read/write, fixed in 4.0.1/5.0.1/6.0.1.
CVE-2026-34987 (Winch baseline compiler, non-default): guests can access host memory
outside their linear-memory sandbox — up to 32KiB before, ~4GiB after the base — fixed in
43.0.1/42.0.2/36.0.7.
**Conditions.** Any pinned wasmtime version, reached transitively through
`wasmex 0.15.1` → `rustler_precompiled`. Note that `rustler_precompiled` means the NIF
is a **downloaded binary**, so the wasmtime version is not visible in `mix.lock` and
`mix deps.get` does not rebuild it.
**Claim + test.** *Claim:* the deployed wasmtime version is known and not on an advisory.
*Test:* record the wasmtime version at boot (from the Wasmex NIF) into Vitals; add a CI
step that checks it against the Bytecode Alliance advisory feed; assert the precompiled
NIF's checksum matches a checked-in `checksum-*.exs`. A "we run WASM so we're safe"
claim with an unpinned, unaudited, precompiled native blob under it is not a claim.
**Source.** https://github.com/advisories/GHSA-ff4p-7xrq-q5r8 ·
https://github.com/bytecodealliance/wasmtime/security/advisories/GHSA-xx5w-cvp6-jv83 ·
https://bytecodealliance.org/articles/wasmtime-security-advisories
**Applicability.** single-node now.

##### S28. Timing side channels — what the sandbox explicitly does not cover
**What goes wrong.** Wasmtime's security page documents *partial* Spectre mitigations
(function-table bounds checks, `br_table` determinism, dynamic memory bounds checks) and
states that full Spectre protection remains incomplete; side channels generally are not
in the threat model. Concretely for LazyRiver: (a) a formula that can observe elapsed
time can infer facts it was never handed — but with an **empty import map it has no
clock**, which is a genuine structural win worth asserting; (b) the *host* leaks timing
— an answer that is a cache hit returns in microseconds and a miss in milliseconds, so an
unauthorized caller can probe which `{formula, snapshot}` pairs exist; (c) secret
comparison — `Plug.Crypto.secure_compare/2` is constant-time *but short-circuits on
length mismatch*, leaking the secret's length (a real fix in the wild is to SHA-256 both
sides first, normalising to 32 bytes).
**Conditions.** (a) requires granting the guest a clock — don't. (b) is live now. (c) is
live wherever a bearer token is compared.
**Claim + test.** *Claim (a):* a formula cannot read a clock. *Test:* a `.wat` importing
`wasi_snapshot_preview1.clock_time_get` must be refused at build time —
`instantiable/2` should already do this; make it an explicit named test, because it is
the load-bearing assertion for "pure."
*Claim (b):* cache-hit and cache-miss timing does not distinguish existence to an
unauthorized caller. *Test:* assert authorization is checked **before** the cache lookup
in `Surface.Authorize`, so a 403 costs the same either way; measure both paths 1000× and
assert the distributions overlap.
*Claim (c):* token comparison is constant-time and length-independent. *Test:* assert the
auth path calls `Plug.Crypto.secure_compare/2` on **fixed-width digests**, not on raw
tokens of caller-controlled length.
**Source.** https://docs.wasmtime.dev/security.html ·
https://hexdocs.pm/plug_crypto/Plug.Crypto.html ·
https://github.com/Logflare/logflare/commit/cedefffca6868c1be495e96f36f3e6d5f7c3e1f1
**Applicability.** single-node now.

##### S29. The two-tier formula path: `Formula.new/2` takes an arbitrary Elixir closure
**What goes wrong.** `Formula.new(id, compute)` accepts *any* 1-arity function and
`Formula.Engine.register/2` accepts *any* `%Formula{}`. `Sandbox.mapping/3` is one
producer of `%Formula{}` among possible others. Everything in Part D (S17–S21) and all of
Part B applies in full to a host-side closure, and the fabrication fence does not: an
Elixir closure can call `File.read!/1`, `:httpc`, `:os.cmd/1`. The sandbox is therefore a
*property of one construction path*, not of the `Formula` type.
**Conditions.** Any route, job, or admin path that can reach `Formula.new/2` with
caller-influenced content. Any future "trusted formulas can be Elixir" convenience.
**Claim + test.** *Claim:* every `%Formula{}` reachable from the network surface was
built by `Sandbox`. *Test:* tag the struct — add a `tier` field (`:wasm | :native`) set
only by its constructor, and assert `Engine.register/2` called from the Surface refuses
`:native`. Then a router-level test: no HTTP route accepts an Elixir source string,
quoted AST, or MFA tuple. This is the difference between "the fence is data access" being
true and being aspirational.
**Source.** https://www.erlang.org/doc/system/secure_coding.html ·
https://security.erlef.org/secure_coding_and_deployment_hardening/sandboxing.html
**Applicability.** single-node now. **Highest-leverage architectural claim in Topic 10.**

##### S30. The read set: a formula's declared reads must equal its actual reads
**What goes wrong.** `Formula.run/2` returns `{answers, reads}` and the cache's whole
correctness story rests on the snapshot name summarising what was read. If a compute
function reads data outside the declared `over:` pattern, the name no longer covers the
inputs and the cache serves an answer derived from data the name does not describe.
**Conditions.** Any widening of the guest interface beyond "one integer in, one integer
out" — precisely the widening the sandbox moduledoc warns about.
**Claim + test.** *Claim:* the read set is complete. *Test:* run a formula on snapshot S,
capture its read set R; construct S' identical to S except for facts *outside* R; assert
the answer is unchanged. Then construct S'' differing *inside* R and assert the answer
*does* change. Property-test over generated snapshots. This is the test that makes
"cached by name" a proven claim rather than an argued one.
**Source.** (design invariant; the caching rationale is in `formula/engine.ex` moduledoc)
**Applicability.** single-node now.

---

### Topic 11 — Operational and deployment hazards

#### Part A — Config that nothing reads, and components that never start

##### O1. Dead config: a setting documented, set in production, and consumed by nothing
**What goes wrong.** A config key exists, is documented, appears in the deploy
environment, and no code path reads it. Nothing fails; the system quietly runs on the
default. Xu et al. (OSDI '16, Best Paper) named this class **latent configuration (LC)
errors** — a setting whose consuming code is not reached until long after boot, so the
error surfaces at the worst possible moment — and found that **up to 93% of widely-used
software systems have no code at all for checking configuration correctness at
initialization time**.
**Conditions.** Any env-var-driven config read at boot into `Application` env and
consumed elsewhere.
**Claim + test.** *Claim:* every key `runtime.exs` sets is read by at least one non-test
module. *Test:* a CI check that enumerates every `config :lazy_river, KEY` in
`config/runtime.exs` and asserts a `grep -r "Application.get_env(:lazy_river, :KEY)"` hit
in `lib/`. **LazyRiver has already been bitten by exactly this** — `test/store_default_test.exs`
opens: *"`ledger_dir` was configured, documented, and never read, so every ledger in
production was in memory and every restart lost everything — including the grants that
say who may name what."* That test guards one key. The CI check guards all of them,
including future ones. Current audit: `ledger_dir` ✓ (`ledger.ex`), `key_dir` ✓,
`kms_key` ✓ (`keyring.ex:134`, `keyring/gcp.ex:123`), `gcp_credentials` ✓
(`keyring/gcp.ex:153`), `backup_target`/`backup_every` ✓ (`application.ex`),
`ledger_sync` ✓ (`ledger.ex:174`) — all live today, which is exactly why the *check*
matters more than the audit.
**Source.** https://www.usenix.org/conference/osdi16/technical-sessions/presentation/xu
**Applicability.** single-node now. **Highest-leverage item in Topic 11.**

##### O2. A component declared but never started
**What goes wrong.** A GenServer with a `start_link/1` that nothing calls, or a child spec
in a module never added to the Application's children list. It compiles, its tests pass
(they start it explicitly), and in production it is simply absent. The Elixir-specific
shape: `Application.start/2` builds `children` as a literal list, and forgetting to append
is invisible.
**Conditions.** `application.ex` builds `children` with two *conditional* appends:
`vitals()` returns `[]` when `:vitals_every` is nil, `backup()` returns `[]` when
`:backup_target` is nil. Both are deliberate and well-reasoned — but both mean "the worker
is absent" is a *normal* state indistinguishable from "the worker was forgotten."
**Claim + test.** *Claim:* every module implementing `child_spec/1` or `start_link/1` in
`lib/` is either in the supervision tree at boot or is explicitly listed as
started-on-demand. *Test:* (a) an inventory test — enumerate modules exporting
`start_link/1`, subtract `DynamicSupervisor`-started ones (Ledger, Subscription), assert
the remainder appear in `Supervisor.which_children(LazyRiver.Supervisor)` after boot;
(b) a **prod-shaped** boot test — start the app with `backup_target` and `vitals_every`
set, and assert `LazyRiver.Backup` and `LazyRiver.Vitals` are running children with
non-zero pids. Today nothing asserts the backup worker actually starts in the
configuration production uses.
**Source.** https://hexdocs.pm/elixir/Supervisor.html
**Applicability.** single-node now.

##### O3. `LEDGER_SYNC` defaults OFF, and the durable path is nearly untested
**What goes wrong.** The general class: a durability flag defaults off, every test runs
with it off, and the fsync path is never exercised — so the code that makes data survive
a crash is the least-tested code in the system. LazyRiver's instance:
`runtime.exs` sets `ledger_sync: System.get_env("LEDGER_SYNC") == "true"` (absent ⇒
**false**), `ledger.ex:174` reads it with default `false`, the Dockerfile's `ENV` block
sets `LEDGER_DIR`, `KEY_DIR`, `PORT` but **not** `LEDGER_SYNC`, and the CI deploy job's
boot test sets `LEDGER_DIR`/`KEY_DIR` but not `LEDGER_SYNC`. Exactly **one** test in the
tree puts it true (`test/store_default_test.exs:35`). So: production defaults to
un-fsynced appends, and the SIGKILL crash suite (`mix test --only crash`) runs against the
un-fsynced path.
**Conditions.** Container killed, host loses power, kernel panic — anything that discards
the page cache. Compounded by S? no: compounded by O11 (fsync errors are reported once).
**Claim + test.** *Claim:* with `LEDGER_SYNC=true`, a fact acknowledged to a client
survives `SIGKILL` of the BEAM. *Test:* append N facts with sync on, `kill -9` the node
mid-append, restart, assert every acknowledged fact is present and the log tail is not
torn. Then the *inverse* test, which is the valuable one: with sync **off**, assert
acknowledged facts *may* be lost — and make that a documented, tested property rather
than a surprise. Then run the **entire** crash suite in both modes in CI (a matrix
dimension, not a flag). Finally: decide whether the prod default should be `true`; a
durability flag that must be remembered is one that will be forgotten.
**Source.** https://wiki.postgresql.org/wiki/Fsync_Errors ·
https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai
**Applicability.** single-node now. **Second-highest-leverage item in Topic 11.**

##### O4. Test/prod default divergence generally
**What goes wrong.** Beyond durability: `config.exs` binds the endpoint to
`{127,0,0,1}:4000` and `runtime.exs` (prod) binds `{0,0,0,0,0,0,0,0}` — a different IP
*family*. Tests never exercise the IPv6-any bind. If the runtime image's stack is not
dual-stack, the process listens on `::` only and the Dockerfile's `HEALTHCHECK`, which
curls `http://127.0.0.1:4000/`, cannot reach it — a container that is healthy but reports
unhealthy, or (worse, if the check were laxer) the reverse. Similarly `server:` is
`config_env() != :test` in dev and `true` in prod; `secret_key_base` is a checked-in
constant in dev and required in prod; `key_dir` is `tmp/test_keys` vs `priv/keys` vs
`/data/keys`.
**Conditions.** Any config value whose *shape* (not just value) differs between envs.
**Claim + test.** *Claim:* the prod endpoint configuration accepts a loopback IPv4
connection. *Test:* boot the release with `MIX_ENV=prod` in the actual runtime image and
assert `curl http://127.0.0.1:$PORT/...` connects — the deploy job already boots the
release, so this is one extra assertion. More generally: a test that diffs the
*key sets* of dev/test/prod config and requires every difference to be annotated.
**Source.** https://www.usenix.org/conference/osdi16/technical-sessions/presentation/xu
**Applicability.** single-node now.

##### O5. Boot must fail loudly on missing config, and warnings are not failures
**What goes wrong.** `runtime.exs` raises without `SECRET_KEY_BASE` — good, that is
fail-fast done right. But two other conditions only `IO.warn`: no backup target ("Losing
/data loses every fact and every key") and unset `KEY_DIR`. `IO.warn` writes to stderr
during boot, is drowned by the release's startup output, and stops nothing. The
system-under-test's own comment says the failure a deployment must never have is the one
where "it looks configured and copies nothing" — and then warns instead of refusing.
**Conditions.** Any deploy where the operator did not read boot logs.
**Claim + test.** *Claim:* a production boot without a backup target is refused, or the
absence is visible in a machine-readable place. *Test:* boot with `MIX_ENV=prod` and no
`BACKUP_*`; assert either a raise, or that `/vitals` reports `backup: :unconfigured` and
that the deploy gate checks it. Prefer: require an explicit `BACKUP_TARGET=none` to opt
out, so "unbacked-up" is a decision someone typed rather than a variable someone forgot.
Same treatment for `LEDGER_SYNC` (O3).
**Source.** https://www.usenix.org/conference/osdi16/technical-sessions/presentation/xu
**Applicability.** single-node now.

##### O6. `String.to_integer` on env vars — a typo is a boot crash with no repair
**What goes wrong.** `runtime.exs` does `String.to_integer(System.get_env("PORT") || "4000")`
and `String.to_integer(System.get_env("BACKUP_EVERY") || "900")`. `BACKUP_EVERY=15m`
raises `ArgumentError: errors were found at the given arity` from deep in config
evaluation — before the logger is configured, with no indication of which variable or
what the valid form is. This is the "errors are data with the repair attached" ground rule
violated at the earliest possible moment.
**Conditions.** Any hand-typed deploy environment.
**Claim + test.** *Claim:* every malformed env var produces a message naming the
variable, the value, and the accepted form. *Test:* boot with `PORT=eighty`,
`BACKUP_EVERY=15m`, `BACKUP_BUCKET` set but `BACKUP_ENDPOINT` unset (currently
`System.fetch_env!` — which does at least name the key), and assert each message contains
the variable name and a repair.
**Source.** https://www.usenix.org/conference/osdi16/technical-sessions/presentation/xu
**Applicability.** single-node now.

#### Part B — On-disk format, versions, and the past

##### O7. Rollback compatibility: an old binary must read a new log
**What goes wrong.** Deploys roll forward and back. If v2 writes a record shape v1 cannot
parse, the rollback is not a rollback — it is an outage plus a corrupted-looking ledger.
Kafka's model is the reference: you roll new binaries first with
`inter.broker.protocol.version` and `log.message.format.version` pinned to the *old*
value, and **downgrade is only supported while those remain unbumped** — "a working
downgrade is not guaranteed after you've set inter.broker.protocol.version to x.y," and
you cannot revert if messages have been written with a newer log format. etcd made
downgrade a first-class feature only in v3.6, and it works by *migrating the schema down*
before the rolling downgrade, with validation first.
**Conditions.** LazyRiver is append-only with a mounted volume that outlives the
container — so **every** deploy is potentially a mixed-version read of one log, and
rollback is the normal recovery action.
**Claim + test.** *Claim:* N-1 compatibility holds in both directions. *Test:* two CI
jobs. (a) *Forward:* build the previous release tag, write a ledger with it, boot HEAD
against that directory, assert every fact reads back identically. (b) *Rollback:* write a
ledger with HEAD, boot the previous tag against it, assert it either reads everything or
refuses to start with a message naming the format version — **never** partially reads.
(b) is the one nobody writes and the one that matters. Add an explicit format-version
byte/header to each ledger segment so the refusal is possible at all.
**Source.** https://kafka.apache.org/documentation/#upgrade ·
https://etcd.io/docs/v3.6/downgrades/downgrade_3_6/
**Applicability.** single-node now.

##### O8. Append-only schema evolution: you cannot change the past
**What goes wrong.** In an immutable log, changing an attribute's *meaning* silently
reinterprets every historical fact. Datomic states the rule directly: "growth is providing
more schema while breakage is removing schema or **changing the meaning of existing
schema**... Never remove a name. Reusing that name to mean something substantially
different breaks programs that depend on that meaning. This can be even worse than
removing the name, as the breakage may not be as immediately obvious." The event-sourcing
formulation of the same rule: "Semantics never change. A field's meaning is permanent. If
the meaning changes, create a new field or a new event type." The concrete disaster is the
units change — `:price` going from cents to dollars — where every consumer of historical
facts computes wrong values with no error anywhere.
**Conditions.** Any attribute rename, unit change, nullable→required, or enum
re-purposing. Also: `Erasure` (tombstones) interacts here — an erased subject's facts
still occupy the log positions later readers walk.
**Claim + test.** *Claim:* an attribute's meaning is immutable once asserted. *Test:*
(a) a registry test — attributes are declared with a definition, and a CI check refuses a
*changed* definition for an existing name while allowing a new name (this is exactly what
montology does for the vocabulary; do it for ledger attributes too). (b) A replay test:
check in a golden ledger fixture written months ago and assert HEAD reads it to the same
values. (c) Assert `:db/valueType`-equivalent changes are refused at write time with a
repair string that names the new-attribute remedy.
**Source.** https://docs.datomic.com/reference/best.html ·
https://blog.datomic.com/2017/01/the-ten-rules-of-schema-growth.html ·
https://docs.proteanhq.com/patterns/event-versioning-and-evolution/
**Applicability.** single-node now.

##### O9. Crash consistency of the append itself
**What goes wrong.** "All File Systems Are Not Created Equal" (Pillai et al., OSDI '14)
tested eleven widely-used systems and found **60 crash vulnerabilities**, because
application update protocols depend on *persistence properties* — atomicity of appends,
ordering between writes, whether `rename` is atomic and durable — that vary widely across
six popular Linux filesystems. The specific traps for an append-only log: an append larger
than a sector can tear; a `rename` is not durable until the *parent directory* is
fsynced; and ordering between a data write and a metadata update is not guaranteed
without explicit barriers.
**Conditions.** Every `SIGKILL` crash test in the CI suite, and every real crash. The
crash suite exists (`mix test --only crash`), which is more than most projects — the
question is what it asserts.
**Claim + test.** *Claim:* after an arbitrary crash, the ledger's tail is either a
complete fact or absent — never a half-written one — and no acknowledged fact is missing.
*Test:* (a) per-record checksum, and a test that truncates the last record to every
byte length 1..len and asserts recovery discards exactly the incomplete tail and reports
it; (b) assert the directory containing a newly-created segment is fsynced, not just the
file; (c) run the crash suite on both `ext4` and `overlayfs`-over-`ext4` (see O13),
because the paper's whole point is that the guarantees differ.
**Source.** https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai
**Applicability.** single-node now.

##### O10. fsync errors are reported once — "fsyncgate"
**What goes wrong.** On Linux, a writeback failure marks the page `AS_EIO`; the *first*
`fsync()` returns `EIO` **and clears the flag**, so a retried `fsync()` on the same data
returns success. PostgreSQL retried its checkpoint fsync, got success, and *lost the
data*. The fix — backpatched to 9.4 — was to **PANIC on fsync failure** rather than retry.
**Conditions.** Any code that treats `:file.sync/1` returning `{:error, _}` as retryable.
On a network/overlay volume this is not exotic.
**Claim + test.** *Claim:* a failed sync is fatal to the ledger process, not retried.
*Test:* inject an fsync failure (via a fault-injection layer, `dmsetup` `error` target, or
a mocked `:file` module) and assert the ledger crashes/refuses rather than acknowledging
the write; assert the client sees a refusal, not an `:ok`. Then assert the supervisor's
restart does **not** silently re-acknowledge.
**Source.** https://lwn.net/Articles/752093/ · https://wiki.postgresql.org/wiki/Fsync_Errors
**Applicability.** single-node now.

#### Part C — Capacity cliffs

##### O11. ENOSPC on an append-only log — and recovery needing free space
**What goes wrong.** The PostgreSQL ENOSPC wiki describes the exact trap: if the error
arrives at the wrong layer, "you can't shut down (because that requires a checkpoint),
and if you crash then in crash recovery, you'll probably run into the same problem but now
it will be raised as **FATAL, so you can't even start up your database again, until you
make some space**." COW filesystems (btrfs, zfs, apfs) are more prone to hitting it during
data writes; overwrite filesystems tend to hit it while preallocating. etcd's answer is a
quota that trips a `NOSPACE` **alarm** putting the cluster into read/delete-only
maintenance mode *before* the disk is actually full — and even then, "deleting application
data does not reclaim the space on disk" without a defrag, and a documented bug report
shows compaction alone leaving the server still rejecting writes.
**Conditions.** A ledger that only grows, on a fixed-size mounted volume, with a backup
job also writing locally. Add inode exhaustion (many small segment files ⇒ `ENOSPC` with
`df` showing free bytes) and ext4's 5% root-reserved blocks (which is why a non-root
process hits ENOSPC at 95%).
**Claim + test.** *Claim:* at disk-full, LazyRiver refuses writes with a repair, keeps
serving reads, and **restarts cleanly**. *Test:* mount a 64MB `tmpfs`/loopback as
`LEDGER_DIR`, fill it, assert: (a) append returns a refusal naming ENOSPC and the repair;
(b) reads still work; (c) `SIGKILL` + restart on the *still-full* volume **boots
successfully** — this is the assertion that catches the "recovery requires free space"
class; (d) repeat with inodes exhausted (`mkfs.ext4 -N` small) rather than bytes.
Then implement a *reserve*: refuse new appends at 90% so there is room to recover, the
etcd alarm pattern.
**Source.** https://wiki.postgresql.org/wiki/ENOSPC ·
https://etcd.io/docs/v3.6/op-guide/maintenance/ · https://github.com/etcd-io/etcd/issues/14267
**Applicability.** single-node now. **Third-highest-leverage item in Topic 11.**

##### O12. Backups compete for the resource they protect
**What goes wrong.** `LazyRiver.Backup` runs every `BACKUP_EVERY` (default 900s). If the
target is `BACKUP_DIR` it writes to the *same volume* as the ledger, so the backup
accelerates the ENOSPC it exists to survive. If the target is S3 and it stages locally,
same. If a backup run overlaps the next tick, they pile up.
**Conditions.** `BACKUP_DIR` set to a path under `/data`. Slow or unreachable S3 endpoint.
**Claim + test.** *Claim:* a backup cannot fill the ledger volume, and runs do not
overlap. *Test:* (a) assert `Backup` refuses a `BACKUP_DIR` on the same filesystem as
`LEDGER_DIR` (compare `File.stat` device ids) with a repair; (b) make the target
unreachable and assert the worker does not accumulate concurrent runs or unbounded
mailbox; (c) assert a failed backup is *visible* — see O17.
**Source.** https://etcd.io/docs/v3.6/op-guide/maintenance/
**Applicability.** single-node now.

#### Part D — Container and volume hazards

##### O13. The volume that was never mounted — data on the ephemeral writable layer
**What goes wrong.** Docker: "By default all files created inside a container are stored
on a writable container layer... Data written to the container layer doesn't persist when
the container is destroyed." The failure is silent because the *path exists* — the
Dockerfile does `RUN mkdir -p /data/ledgers /data/keys`, so if the volume is not mounted,
writes succeed, into the image's layer, and vanish on the next deploy. Real incidents in
this exact shape: a vector DB whose real state lived in `/.local/share/…` while `/data`
was the advertised mount, losing 567 collections on a routine recreate with **no error**;
FalkorDB mounted at `/data` while writes went to `/var/lib/falkordb/data` through a
symlink into the writable layer, surviving `restart` but not `recreate`; a self-hosted
app where a CI change moved the host path and "Docker's `-v` option automatically creates
an empty directory if the host-side path does not exist. The fact that it doesn't cause an
error is troublesome." There is also an inode variant: if a deploy tool *deletes and
recreates* the host directory, the bind mount still points at the old inode and the
container sees an empty folder.
**Conditions.** Every deploy. LazyRiver is specifically exposed: `mkdir -p /data/…` in
the image guarantees the unmounted case looks healthy, and the container is replaced on
every deploy while "the ledger is not."
**Claim + test.** *Claim:* the process refuses to serve if `LEDGER_DIR` or `KEY_DIR` is
not on a mount. *Test:* at boot, read `/proc/self/mountinfo` and assert `LEDGER_DIR` and
`KEY_DIR` are on a different device than `/` (`File.stat!(dir).major_device !=
File.stat!("/").major_device`); refuse to boot otherwise with a repair naming the
`-v` flag. Then the integration test: `docker run` **without** `-v`, assert the container
exits non-zero with that message rather than starting. Also write a boot marker file
containing the previous boot's id and warn loudly if it is missing when facts exist. The
vectorizer maintainers' recommendation is exactly this: "Emit a startup warning when the
data dir is on the container's writable layer (no underlying mount). Detect via
`/proc/self/mountinfo`."
**Source.** https://docs.docker.com/engine/storage/ ·
https://github.com/hivellm/vectorizer/issues/300 ·
https://github.com/getzep/graphiti/issues/1452 ·
https://oscarchou.com/posts/troubleshoot/docker-compose-mount-empty-after-redeploy/
**Applicability.** single-node now. **Highest-leverage item in Part D. This is the
incident that ends the project.**

##### O14. Mount permissions and the container user
**What goes wrong.** The image runs as **root** (no `USER` directive) and creates
`/data/*` as root at build time. If a mounted volume is owned by a different uid, or if a
later hardening pass adds `USER app`, writes fail — sometimes silently, depending on how
errors are handled. Conversely, running as root means a container escape owns the volume.
**Conditions.** Adding a non-root user; moving to a managed volume with enforced
ownership; k8s `fsGroup`/`runAsUser`.
**Claim + test.** *Claim:* the process verifies it can write to `LEDGER_DIR` and
`KEY_DIR` at boot. *Test:* a boot-time write-and-delete probe of each directory that
refuses with a repair naming the path, the uid, and the observed owner. Then a container
test with the volume `chown`ed to a foreign uid, asserting the refusal. Separately: add
`USER` to the runtime stage and re-run the whole suite — a root-only correctness
assumption is a latent one.
**Source.** https://docs.docker.com/engine/storage/volumes/
**Applicability.** single-node now.

##### O15. OOM-killed with no core, and no last words
**What goes wrong.** The cgroup OOM controller fires when the container exceeds
`memory.max` after failed reclaim — "the host system can have gigabytes free — the cgroup
OOM does not care." The victim gets `SIGKILL`: uncatchable, no `erl_crash.dump`, no
graceful ledger close, exit code 137. Default behaviour kills *one process*, which for a
multi-process container "often leaves the container in a broken state: the orchestrator
sees the container still running, but a critical subprocess is dead" (`memory.oom.group`
fixes this). The BEAM's own out-of-memory path is different and also abrupt —
`binary_alloc: Cannot allocate N bytes` then `Aborted`.
**Conditions.** S11/S12/S13/S25 all lead here. So does a large `Snapshot.find`.
**Claim + test.** *Claim:* an OOM kill loses no acknowledged fact and the node recovers.
*Test:* run the container with `--memory=256m`, drive it to OOM, assert exit 137, then
restart on the same volume and assert every acknowledged fact is present (this is O3's
sync test under a different killer). Separately assert the BEAM is configured to emit a
crash dump where it *can* (`ERL_CRASH_DUMP` on the volume, not the ephemeral layer — O13),
and that Vitals exports `erlang:memory/0` so the climb is visible *before* the kill.
**Source.** https://kernel-internals.org/mm/memcg-oom/
**Applicability.** single-node now.

##### O16. SIGTERM, the 10-second cliff, and what the BEAM actually does
**What goes wrong.** `docker stop` sends `SIGTERM` and waits **10 seconds** by default
before `SIGKILL`; Kubernetes waits `terminationGracePeriodSeconds`, default **30**. What
the BEAM does on SIGTERM is better than folklore claims: since OTP 20 a `gen_event`
manager named `erl_signal_server` is started by default, and `erl_signal_handler`'s
default handler **calls `init:stop/0`** — a graceful runtime stop. So an Elixir release
*does* shut down gracefully on SIGTERM. The hazards are the ones around it:
(a) `init:stop/0` runs `Application.stop/1` and supervisor shutdowns, and a child whose
`terminate/2` takes longer than the remaining grace period is `SIGKILL`ed mid-flush;
(b) supervisor `:shutdown` timeouts (5000ms default per child) can sum past 10s;
(c) if `CMD` were the shell form, PID 1 would be `/bin/sh` and the signal would never
reach the BEAM — LazyRiver's `CMD ["/app/bin/lazy_river", "start"]` is exec form, which
is correct, and worth an explicit test rather than a reviewer's glance;
(d) `bin/lazy_river start` runs the release in the foreground so it *is* PID 1 — good.
**Conditions.** Every deploy. "Deploys reset in-flight work" is a standing ground rule in
this repo.
**Claim + test.** *Claim:* SIGTERM to the container flushes and closes every ledger
within the grace period, and no acknowledged fact is lost. *Test:* start appending
continuously, `docker stop` (10s default, do not extend it), assert (a) exit code 0 not
137, (b) elapsed shutdown < 10s, (c) every acknowledged fact present on restart, (d) no
partial record at the tail. Then the negative: hold a ledger's `terminate/2` for 20s and
assert the *system* still exits cleanly rather than being killed mid-write — i.e. the
flush is ordered before the slow work. If more time is genuinely needed, add
`os:set_signal(sigterm, handle)` plus a custom handler that drains first, and raise
`terminationGracePeriodSeconds` / `docker stop -t` to match — the app-side and
orchestrator-side numbers must be set together or the larger one is a lie.
**Source.** https://github.com/erlang/otp/blob/master/lib/kernel/src/erl_signal_handler.erl
· https://www.erlang.org/doc/apps/kernel/kernel_app.html ·
https://docs.docker.com/reference/cli/docker/container/stop/ ·
https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
**Applicability.** single-node now.

##### O17. Shallow health checks — a probe that returns 200 while storage is dead
**What goes wrong.** AWS's Builders' Library distinguishes *liveness* checks (basic
connectivity and "the presence of a server process"), *shallow* health checks (on-box:
processes running, filesystem health), and *deep* health checks (which "test interactions
with off-box dependencies"). The failure mode is a probe that proves the HTTP listener is
up and nothing else — the process serves 200s while the ledger volume is read-only, the
disk is full, or the keyring cannot reach KMS. The counter-hazard the same article raises
is that deep checks produce correlated false positives and can take out a whole fleet.
**Conditions.** LazyRiver's `HEALTHCHECK` POSTs `/open` and greps for `401`. That proves
routing and authorization are wired — genuinely more than a bare `/health` — but it
touches **no storage**: a container whose `/data` is unmounted (O13), full (O11), or
read-only reports healthy indefinitely. (I verified the mechanics: `curl -sf -o /dev/null
-w '%{http_code}'` *does* still emit the code on a 401 despite exiting 22, so the grep
matches and the check works as intended. The gap is what it checks, not how.)
**Claim + test.** *Claim:* the health check fails when the ledger is unwritable.
*Test:* remount `/data` read-only (or fill it) on a running container and assert the
health check transitions to unhealthy within `interval × retries`. Implement as a
`/vitals`-backed check asserting: ledger dir writable, last append succeeded, keyring
reachable, backup age < 2× `BACKUP_EVERY`. Keep it single-node-shallow (no dependency on
S3 liveness) to avoid the correlated-failure trap.
**Source.** https://aws.amazon.com/builders-library/implementing-health-checks/ ·
https://d1.awsstatic.com/builderslibrary/pdfs/implementing-health-checks.pdf
**Applicability.** single-node now.

#### Part E — The deploy gate, identity, secrets, and the drill

##### O18. The 401-only smoke test proves almost nothing
**What goes wrong.** The deploy job boots the release and asserts one thing: an
unauthenticated `POST /open` returns `401`. A release that 401s *everything* — including
authenticated requests — ships. A release that cannot open a ledger, cannot append,
cannot read a key, or writes to the wrong directory ships. The gate proves the router and
the auth plug are mounted; it does not prove the system works.
Three further weaknesses in the same job:
(a) the readiness loop is `curl -sf -o /dev/null http://…/open && break` — a **GET** to a
POST route, under `-f`, so it never succeeds and never breaks; the loop always runs its
full 60 × 0.5s and the real assertion races the boot;
(b) the boot environment sets `LEDGER_DIR`/`KEY_DIR` but **not** `LEDGER_SYNC`,
`BACKUP_*`, or `KMS_KEY` — so the gate exercises a configuration production does not
have, and the backup/KMS paths are never booted in CI at all;
(c) `workflow_dispatch` bypasses the `check` gate entirely
(`if: …conclusion == 'success' || github.event_name == 'workflow_dispatch'`).
**Conditions.** Every deploy.
**Claim + test.** *Claim:* the gate exercises one full round trip in the shipped artefact.
*Test:* extend the deploy job to: mint a token, `POST /open`, append a fact, read it back,
assert the value; restart the release process and assert the fact survives; assert a
second, *unauthorized* token gets 403 (not 401 — proving authorization, not just
authentication); assert `/vitals` reports the backup target it was given. Fix the
readiness loop to poll a real readiness endpoint without `-f`. Boot the gate with
`LEDGER_SYNC=true` and a `BACKUP_DIR`.
**Source.** https://aws.amazon.com/builders-library/implementing-health-checks/
**Applicability.** single-node now. **Second-highest-leverage in Topic 11 alongside O3.**

##### O19. Deploys reset in-flight work
**What goes wrong.** The container is replaced on every deploy. Anything mid-flight —
a formula computing, a backup uploading, a subscription draining, a ledger compacting —
is abandoned. If any of those is non-idempotent or leaves a partial artefact (a
half-uploaded backup object that looks complete, a partially written segment), the next
boot inherits a corrupt-looking state. The repo's own ground rules record v1 losing three
measurement rounds to exactly this and building a lock file in response.
**Conditions.** Every deploy, plus O15 (OOM) and O16 (SIGTERM timeout).
**Claim + test.** *Claim:* every long-running operation is either atomic or resumable,
and a partial one is detectable. *Test:* kill the node at N random points during a backup
run; assert the remote target never contains an object that *looks* complete but is not
(write to a temp key and rename/copy on completion; assert no bare object exists without
its manifest). Same for compaction/erasure. Add a boot-time reconciliation that names any
partial artefact it found and what it did about it.
**Source.** https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai
**Applicability.** single-node now.

##### O20. Backup/restore never rehearsed — the GitLab lesson
**What goes wrong.** GitLab, 2017: an operator deleted 300GB of production data and
discovered that **none of five** backup/replication mechanisms was working or set up.
`pg_dump` silently produced nothing because the client was 9.2 against a 9.6 server; Azure
snapshots were enabled on the NFS server but not the DB servers; LVM snapshots were 24h
old; replication had fallen behind and the WAL had been purged. They lost six hours of
data. Every one of those is a backup that *existed* and was never *restored from*.
**Conditions.** LazyRiver has one node and one volume, `BACKUP_EVERY` defaults to 900s,
and the backup worker only starts if a target is configured (O5). Nothing in the tree
restores.
**Claim + test.** *Claim:* a backup taken by the running system can be restored into an
empty volume and produces a byte-identical ledger. *Test:* a **CI restore drill** —
write N facts, run a real backup to a local target, wipe `LEDGER_DIR` and `KEY_DIR`,
restore, assert every fact and every key round-trips and erasure tombstones still
reconcile. Run it on every commit, not quarterly. Second test: assert backup *age* is
exported and alarmed, so a silently failing backup is loud. Third: verify the restore path
handles the **key** side — a ledger restored without its keyring is an encrypted brick,
and `runtime.exs` already warns that `KEY_DIR` on ephemeral storage "erases every
subject."
**Source.** https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
**Applicability.** single-node now. **Highest-leverage item in Part E.**

##### O21. Secrets in the image
**What goes wrong.** `ARG` and `ENV` values persist in image metadata and are readable
via `docker history --no-trunc`; deleting a file in a later layer does not remove it from
the earlier layer. Multi-stage builds discard an intermediate stage's *filesystem* but
metadata travels with any layer a later stage references. Docker's own build check says
"setting secrets in a Dockerfile using `ENV` or `ARG` is insecure because they persist in
the final image."
**Conditions.** LazyRiver's Dockerfile sets
`ENV SECRET_KEY_BASE=build-time-placeholder-000…` in the **build** stage only, and the
runtime stage is a fresh `FROM debian` that copies only the release directory — so the
placeholder does not reach the shipped image, and it is a placeholder anyway. The design
is right. The risk is drift: a future `ARG BACKUP_SECRET_ACCESS_KEY` or an `ENV` moved
into the runtime stage.
**Claim + test.** *Claim:* the shipped image contains no secret material. *Test:* a CI
step running `docker history --no-trunc "$IMAGE"` and `docker save "$IMAGE" | tar -x` +
grep, asserting no match for a secret-shaped pattern (`SECRET`, `KEY`, `TOKEN`,
`PASSWORD`, base64 blobs) outside the known placeholder; and `docker run --rm "$IMAGE" env`
asserting no secret-named variable is set. Add `--secret` mounts if a build-time
credential is ever needed. Also assert the release does **not** ship
`config/runtime.exs`-adjacent dev secrets — `config.exs`'s
`String.duplicate("lazyriver-not-a-production-secret", 3)` is compiled in; assert it is
never the value in use at prod boot.
**Source.** https://docs.docker.com/build/building/secrets/ ·
https://docs.docker.com/reference/build-checks/secrets-used-in-arg-or-env/ ·
https://trufflesecurity.com/blog/how-secrets-leak-out-of-docker-images
**Applicability.** single-node now.

##### O22. Identity churns on redeploy: hostname, node name, PIDs, refs
**What goes wrong.** A replaced container gets a new hostname, so the Erlang node name
changes; every pid, port, and `make_ref/0` is unique only within a VM incarnation;
`System.unique_integer/1` with `:monotonic` restarts its sequence. Anything persisted that
embeds one of these — a fact id, a lock owner, a lease holder, a subscription id, a backup
object name — silently changes meaning across a deploy, or collides with a pre-deploy
value.
**Conditions.** Every deploy. Also relevant to `Cluster` if distribution is ever enabled.
**Claim + test.** *Claim:* no persisted identifier embeds runtime identity. *Test:*
write facts, capture the on-disk bytes, restart the node under a *different hostname*, and
assert (a) all ids still resolve, (b) newly minted ids cannot collide with old ones. Grep
the persistence path for `node()`, `self()`, `make_ref`, `System.unique_integer`. Pair
with S21's differential test — same root cause, different blast radius.
**Source.** https://www.erlang.org/doc/apps/erts/erlang.html ·
https://www.erlang.org/doc/apps/erts/time_correction.html
**Applicability.** single-node now; **critical** if distributed.

##### O23. Clock jumps: system time is not monotonic
**What goes wrong.** Erlang system time "can jump backward or forward" from NTP steps,
manual adjustment, or leap seconds; monotonic time cannot. The docs are explicit: measure
elapsed time with `erlang:monotonic_time/0` and subtraction, and "Do not use
`erlang:now/0`" — when system time warps backward `now/0` "behaves bad," freezing for
potentially "years, decades." OTP 26 made multi-time-warp mode the default; the legacy
no-time-warp mode adjusts monotonic clock *frequency* instead, introducing up to 1% error.
**Conditions.** A fresh container on a host whose clock has just been NTP-corrected —
common right after a VM starts. Ordering facts by wall time, expiring caches, timing
`BACKUP_EVERY`, computing a fact's timestamp.
**Claim + test.** *Claim:* no duration is computed from system time, and fact ordering
does not depend on the wall clock being monotonic. *Test:* grep for
`System.system_time`/`:os.system_time` used in subtraction; step the container clock
backward by 1 hour mid-run (`date -s`, or a faketime shim) and assert (a) facts appended
after the step still order after facts appended before, (b) `BACKUP_EVERY` still fires,
(c) no cache entry becomes immortal. If facts carry a wall-clock timestamp *as data*,
that is fine — assert it is documented as "the node's opinion of the time," not as an
ordering key.
**Source.** https://www.erlang.org/doc/apps/erts/time_correction.html
**Applicability.** single-node now.

##### O24. Absent logs and metrics at the moment you need them
**What goes wrong.** The information you need to diagnose an incident is the information
the incident destroyed. Specific shapes here: `IO.warn` at boot (O5) goes to stderr before
the logger is configured and is lost if the supervisor restarts; an OOM `SIGKILL` (O15)
produces no crash dump; a crash dump written to `/app` or `/tmp` dies with the container
(O13); `config.exs` sets `:logger, level: :info` in prod, so `:debug` context is gone;
`Vitals` does not run at all unless `:vitals_every` is configured, and `runtime.exs`
never sets it in prod — `config.exs` sets it to 60 for non-test, so it does run, but
that is a *dev* config file supplying a *production* behaviour, which is the O1 pattern
inverted.
**Conditions.** Every incident.
**Claim + test.** *Claim:* after any abnormal termination, there is durable evidence on
the volume. *Test:* set `ERL_CRASH_DUMP=/data/crash/erl_crash.dump`; kill the node three
ways (`SIGKILL`, BEAM OOM abort, `:erlang.halt/1`) and assert what evidence each leaves;
assert the boot sequence logs — at `:info`, through the real logger, after it is
configured — the resolved values of every config key (with secrets redacted), the mount
device of `LEDGER_DIR`, the fact count, and the last-backup age. Assert `Vitals` is
running in a prod-shaped boot (O2).
**Source.** https://aws.amazon.com/builders-library/implementing-health-checks/
**Applicability.** single-node now.

##### O25. Restart storms and the restart budget
**What goes wrong.** `Supervisor.start_link(..., max_restarts: 10, max_seconds: 5)` — the
comment explains that 3-in-5 was too tight because restarting a component is a legitimate
operation. Fair. But 10-in-5 also means a component crash-looping on a *persistent*
condition (unwritable volume, corrupt segment, unreachable KMS) burns ten restarts in five
seconds and then takes the **whole application** down, which the container runtime
restarts, which repeats — a crash loop at the container level, where each cycle re-reads
the ledger from disk. On a large ledger that is an availability outage that looks like a
deploy problem.
**Conditions.** Any condition that a restart cannot fix. O11, O13, O14 all produce it.
**Claim + test.** *Claim:* an unfixable-by-restart condition produces a *stable* refusal,
not a loop. *Test:* make `LEDGER_DIR` read-only and start the container; assert it either
exits once with a clear message (preferred — let the orchestrator back off) or reaches a
steady degraded state serving reads; assert it does **not** restart more than twice in 60
seconds. Distinguish in code between "crash, a restart may help" and "refuse, it will
not."
**Source.** https://hexdocs.pm/elixir/Supervisor.html · https://kernel-internals.org/mm/memcg-oom/
**Applicability.** single-node now.

##### O26. Single-node: state the availability claim rather than discovering it
**What goes wrong.** `LazyRiver.Cluster` exists in the tree. A single-node append-only
store has an honest and defensible availability story — one machine, one volume, restore
from backup — but only if it is *written down and tested*. The undocumented version fails
the first time someone assumes replication exists.
**Conditions.** Any growth in expectations; any move to distribution (at which point S7's
"a connected node has unrestricted access to all other nodes, and the cookie is not
authentication" becomes the governing constraint).
**Claim + test.** *Claim:* durability is "survives process death and container
replacement; survives host loss only to the last backup, RPO ≤ `BACKUP_EVERY`." *Test:*
the restore drill (O20) *is* the test of this claim — assert measured RPO ≤
`BACKUP_EVERY` + one run duration, and publish that number. Separately: assert
distribution is **off** (`Node.alive?() == false`) in the shipped release, so the
distributed threat model is not silently in scope.
**Source.** https://security.erlef.org/secure_coding_and_deployment_hardening/sandboxing.html
· https://www.erlang.org/doc/system/secure_coding.html
**Applicability.** single-node now; the second half is only-if-distributed.

---

### Cross-cutting test harness suggestions

1. **The differential runner** (S21): every formula, twice, in different processes, on
   different node names, with the clock shifted, on two architectures. One harness, kills
   most of Part D.
2. **The prod-shaped boot** (O2, O4, O5, O18): a CI job that boots the *release* in the
   *runtime image* with the *full* production env (`LEDGER_SYNC=true`, a backup target, a
   KMS key against a fake) and runs the round trip. Most of Topic 11's items are one
   assertion added to this job.
3. **The hostile filesystem matrix** (O9, O11, O13, O14): the crash suite, run against
   read-only, full, inode-exhausted, unmounted, and foreign-owned volumes.
4. **The restore drill** (O20): on every commit.
5. **The config census** (O1): mechanical, cheap, and it catches the bug this codebase has
   already shipped once.

---


## Section 6 — Testing Methodology: how database teams actually gain confidence

Research target: **Lazy River** — single-node, append-only immutable fact-log DB in
Elixir/OTP. Framing `<<size::32, crc32::32, payload>>`, optional fsync, checkpoint
sidecars written-then-renamed, S3 incremental backup, envelope encryption with Cloud
KMS, sandboxed pure formulas (Wasmex), scheduled jobs, Phoenix HTTP + websocket
surface. Existing suite already has a real-process SIGKILL crash test
(`test/crash_recovery_test.exs`), load tests, and a GCP-KMS-tagged test.

Every item below carries: **what it is · what class of bug it finds · cost ·
practical here? · concrete first test · source**.

Verdict key: **YES** = adoptable this week; **WORK** = adoptable but needs a harness
or a Linux CI runner; **NO** = do not attempt, with the reason.

---

#### Observations about the system under test that the recommendations lean on

Read from the tree before researching, so the "concrete first test" lines are real:

- `LazyRiver.Store.File.append/2` writes `<<size::32, crc::32, payload>>` and fsyncs
  only when `sync: true`. `replay/1` returns an in-memory list; `append` does
  `state.facts ++ facts` (O(n) per transaction).
- Checkpoints: `maybe_checkpoint/1` writes `<tmp>.checkpoint.writing` then
  `File.rename!`. The checkpoint payload is `{at, byte_offset, facts}`. **Nothing
  fsyncs the checkpoint file or its directory before or after the rename.**
- Recovery: `read_checkpoint` trusts the checkpoint's `byte_offset` and scans the log
  from there. `scan/2` stops at the first CRC mismatch or short tail.
- `Snapshot.facts/1` flat-maps over a map of `{ledger => tx}` and sorts by `fact.tx` —
  ordering across ledgers at equal `tx` is decided by map iteration order.
- `Store.File.filename/1` is `term_to_binary |> Base.url_encode64` — unbounded length
  against a 255-byte filesystem limit.
- Erasure destroys a KMS-wrapped subject key and writes a tombstone; the keyring
  *reconciles against tombstones whenever it opens*. That reconciliation is a state
  machine, and it is the highest-value thing in the repo to specify formally.

These five facts generate most of the "first test" suggestions below.

---

### A. The Jepsen family

#### 1. Jepsen (the framework)
**What it is.** A Clojure harness that runs a distributed system, drives it with
concurrent single-threaded logical processes, injects faults, records a *history* of
operation invocations/completions, and runs *checkers* over that history. Five moving
parts: `db` (setup/teardown), `client` (one per process, issues ops), `nemesis` (a
special process that injects faults), `generator` (schedules both ops and nemesis
ops), `checker` (analyses the history).
**Bugs found.** Safety violations expressed as history anomalies: lost updates, stale
reads, non-atomic transactions, split brain, data loss after crash/corruption; plus
availability and liveness regressions.
**Cost.** High for a full test: a Clojure project, SSH-reachable nodes, a DB
automation layer. Low if you only reuse its *ideas* (history + checker) or its
*checkers* via elle-cli (item 3).
**Practical here?** **WORK** — as a fault *vocabulary* and a history *format*, yes,
immediately. As a running Jepsen test against a single Elixir node, it is possible
(the SUT's language is irrelevant; Jepsen only needs SSH and a client) but the payoff
is smaller than for a distributed store, because the network-partition nemeses are
inapplicable.
**Concrete first test.** Don't write a Clojure test yet. Instead steal the *history
record shape* (`{:process, :type, :f, :value, :index, :time}`) and have the ExUnit
concurrency test emit one JSON line per operation. That artefact unlocks items 2–4
for free.
**Source.** https://github.com/jepsen-io/jepsen · https://jepsen-io.github.io/jepsen/

#### 2. Elle (the isolation checker)
**What it is.** A black-box transactional-safety checker that infers an Adya-style
dependency graph from client-observed transactions and reports cycles. From the VLDB
2021 paper: *"Elle can detect every anomaly in Adya et al's formalism (except for
predicates), discriminate between them, and provide concise explanations of each"*,
and is *"efficient (polynomial in history length and concurrency)"* — linear in
history length and effectively constant in concurrency in practice.
**What it detects.** G0 (write cycle), G1a (aborted read), G1b (intermediate read),
G1c (cyclic information flow), G-single (read skew), G2 / G2-item (anti-dependency
cycles), plus internal inconsistency, dirty update, garbage read.
**What it cannot detect.** (a) **Predicate anomalies** — Adya's predicate-based
phenomena are explicitly out of scope. (b) It is **sound, not complete**: absence of a
cycle is not proof of serializability, only absence of evidence. (c) It infers nothing
the client cannot observe — a system that never exposes an intermediate state hides
the bug. (d) Real-time / external-consistency violations need the strict-serializable
variant plus wall-clock ordering, which is weak evidence on one node.
**Cost.** Low *if* you feed it a history; the checker is a library, not a service.
**Practical here?** **WORK, and worth it** — with the important caveat below.
**A single node still learns three real things from Elle:**
  1. **Concurrency on one node is still concurrency.** BEAM schedulers preempt; a
     `write` that appends to a ledger while a `watch` streams and a formula evaluates
     is a genuine interleaving. If `Ledger.append` and `Snapshot.open` race, the
     history shows a read that saw tx *n* and then tx *n−1*.
  2. **Process-crash nemesis still applies.** SIGKILL the node mid-history and
     restart; the recovered database must not lose an operation that returned `:ok`
     (already the shape of `crash_recovery_test.exs`) *and* must not resurrect one
     that did not.
  3. **Disk-fault nemesis still applies, and is the big one here.** Bitflip or
     truncate the `.ledger` and `.checkpoint` files between runs, then check the
     recovered history. Jepsen ships exactly these as first-class nemeses (item 5).
**Concrete first test.** Generate a list-append history against a single ledger:
`append` = write fact `{key, "log", unique_value}`; `read` = `Snapshot.find(snap,
id: key)` returning the ordered list of values. Run 20 concurrent processes for 30 s,
crash the node twice, emit JSON, check with `elle-cli --model list-append`. The
expected verdict is "strict serializable"; anything less is a bug in `Snapshot`
ordering (see the `sort_by(& &1.tx)` tie-break observation above).
**Source.** http://www.vldb.org/pvldb/vol14/p268-alvaro.pdf ·
https://github.com/jepsen-io/elle

#### 3. Why list-append is the preferred datatype
**What it is.** Elle's strongest inference rules require *traceable* writes. With
append-only lists, a read of the list reveals a **complete prefix of the Adya version
order for that key from a single read** — you learn the whole write ordering, not just
the last writer. Registers ("writes blindly replace values") give only "weaker
inference rules, but applicable to basically all systems".
**Bugs found.** The extra inference is what makes G-single and G2 detectable at all;
with registers many cycles are simply invisible.
**Cost.** You must make writes *unique and traceable* — a monotonic per-process
counter is enough.
**Practical here?** **YES, and it is nearly free** — a Lazy River ledger *is* an
append-only list. This is the rare case where the checker's ideal datatype is the
system's native one. Do not model it as a register.
**Concrete first test.** As item 2. Ensure the appended value is globally unique
(`{process_id, counter}`) so Elle can order versions.
**Source.** https://github.com/jepsen-io/elle/blob/main/README.markdown

#### 4. elle-cli — driving Elle from a non-JVM system
**What it is.** Verified: `ligurio/elle-cli` is a standalone JAR frontend that
*"operates with operations history both in EDN and JSON formats"* and wraps Elle's
`list-append` and `rw-register`, Jepsen's `bank`/`counter`/`long-fork`/`set`/
`set-full`/`sequential`, and Knossos's `cas-register`/`mutex`. Invocation:
`java -jar elle-cli-0.1.8-standalone.jar --model list-append history.json`.
Record shape: `{"type":"invoke","f":"read","process":2,"time":53137939465,"index":0}`
then `{"type":"ok", ..., "value": ...}`.
So: **yes, Elle can check a history produced by Elixir.** The only JVM requirement is
a JDK on the CI runner, and the only integration is writing newline-delimited JSON.
Elle's own README confirms the intended path: *"you can write your history to a file
or stream, and call a small wrapper program to produce output."*
**Bugs found.** Same as item 2.
**Cost.** Very low. `Jason.encode_to_iodata!/1` per operation plus a `java -jar` step
in `just check` (or a nightly job — it is slow enough to not want on every commit).
**Practical here?** **YES.** This is the single highest leverage/effort item in the
whole document.
**Concrete first test.** A `test/history_test.exs` tagged `:elle` that writes
`tmp/history.json`, plus a `just elle` recipe that shells out to the JAR and fails on
a non-`:valid true` verdict.
**Source.** https://github.com/ligurio/elle-cli

#### 5. Jepsen's disk-fault nemeses (`jepsen.nemesis.file`, `jepsen.nemesis/bitflip`)
**What it is.** A fault library for *files on disk*, independent of any distributed
concern. `corrupt-file-nemesis` divides a byte region into chunks and, per chunk, can
**copy** another chunk over it (deliberately producing "valid-looking structures which
might be dereferenced by later pointers"), **bitflip** at a per-bit probability,
**snapshot** a chunk, **restore** a snapshot (a time-travel/rollback fault), or
**truncate** the file. `helix-gen` spreads corruption across *different* offsets per
node. The implementation is a small standalone C program
(`jepsen/resources/corrupt-file.c`) — usable outside Jepsen entirely.
**Bugs found.** Exactly the class that eats append-only log databases: torn tails that
still checksum, a checkpoint sidecar that survives while the log it indexes does not,
a restored-from-backup file that is *older* than the keyring expects, silent
truncation, and pointer/offset dereference into corrupt data.
**Cost.** Trivial. Compile one C file, or reimplement the four modes in ~60 lines of
Elixir (`:file.pread`/`pwrite`).
**Practical here?** **YES — the strongest single-node application of Jepsen.** Note
Jepsen's own TigerBeetle report found that TigerBeetle's internal tests *"corrupted
entire sectors, rather than single bits"*, which **masked** a padding-corruption bug.
Granularity of the fault is itself a test-design decision.
**Concrete first test.** `erasure_durability`-style: write 10 000 facts with a
checkpoint every 500; close; then for each of {bitflip p=1e-4 in the log, bitflip in
the `.checkpoint`, truncate the log to 90 %, truncate the log to *just past* the
checkpoint's recorded offset, restore an older snapshot of the checkpoint over a newer
log}, reopen and assert: (a) no crash, (b) the recovered prefix is a *prefix* of what
was committed, never a permutation or a gap, (c) `stats/1` reports the truncation
honestly. The "restore an older checkpoint over a newer log" case is the one I expect
to fail today: the checkpoint's `byte_offset` is trusted without checking it against
the log's actual length.
**Source.** https://jepsen-io.github.io/jepsen/jepsen.nemesis.file.html ·
https://github.com/jepsen-io/jepsen/blob/main/jepsen/resources/corrupt-file.c

#### 6. Maelstrom
**What it is.** *"A workbench for writing toy implementations of distributed
systems"*, built **on top of the Jepsen library**. Its key property: nodes are *"plain
old binaries written in any language"* that *"read 'network' messages as JSON from
STDIN, write JSON 'network' messages to STDOUT, and do their logging to STDERR"*,
newline-delimited. It ships workloads (echo, broadcast, g-set/CRDT, lin-kv,
txn-list-append/"Datomic", raft) and nemeses (**partition, kill, pause**), plus
simulated latency and message loss, and verifies *"up to strict serializability"*.
**Bugs found.** Consensus/replication bugs; for a transactional-KV workload, the same
Elle anomalies.
**Cost.** Low to try (a JAR + a stdin/stdout binary), but the *fit* is the problem.
**Practical here?** **NO, for the real system — YES as a learning/mirror exercise.**
Lazy River is single-node with an HTTP+websocket surface; wrapping it in a
JSON-over-stdio node means writing an adapter that speaks Maelstrom's message envelope
and then not using two of the three nemeses (partition is meaningless; kill and pause
are already better covered by SIGKILL against the real port). The genuinely useful
half of Maelstrom — the checkers — is reachable more directly via elle-cli (item 4)
without the protocol adapter. Revisit if `cluster.ex` ever becomes real replication.
**Source.** https://github.com/jepsen-io/maelstrom ·
https://github.com/jepsen-io/maelstrom/blob/main/doc/protocol.md

---

### B. Deterministic simulation testing (DST)

#### 7. FoundationDB's simulation
**What it is.** FDB is written in **Flow**, *"a novel syntactic extension to C++ adding
async/await-like concurrency primitives"* providing an actor model. Because *"all
database code is deterministic and multithreaded concurrency is avoided (one database
node is deployed per core)"*, a simulator can *"abstract all sources of nondeterminism
and communication, including network, disk, time, and pseudo-random number
generator"*. Every new feature is tested under a myriad of injected faults.
**Bugs found.** Rare interleaving + fault-timing bugs; the FDB claim is that this is
why they can ship features fast without Jepsen finding anything.
**Cost.** Enormous, and structural: the *language* was built for it.
**Practical here?** **NO in the FDB form.** The prerequisites are (i) single-threaded
execution of all node code, (ii) every source of entropy pluggable, (iii) no
third-party library with hidden randomness. The BEAM violates (i) by construction.
See item 13 for the honest BEAM assessment and item 14 for the substitute.
**Concrete first test.** N/A — read it for the *fault taxonomy* (disk, network, clock,
process, and "buggify" — deliberately taking rare code paths).
**Source.** https://www.foundationdb.org/files/fdb-paper.pdf ·
https://apple.github.io/foundationdb/testing.html

#### 8. Antithesis (deterministic hypervisor)
**What it is.** The FDB team's company. Rather than requiring the SUT be built for
determinism, they *"run regular non-deterministic software inside a deterministic
hypervisor"* ("the Determinator"), simulating hardware, networking and time; then fuzz
inputs, inject faults, and use **RL-guided exploration** to seek new states. Failures
get a **deterministic time-travelling debugger**.
**Bugs found.** Anything a hostile environment plus randomized input reaches: crashes,
invariant violations, data loss under fault timing. MongoDB has used it since 2021 for
the core server, WiredTiger, and sharded clusters across eight network topologies
including upgrade/downgrade; there is a published Ethereum-merge case study.
**Cost.** Commercial platform; containerized SUT + a "test template" client + declared
properties. Not free, but note the *properties-not-tests* model: *"Instead of writing a
vast test harness, you simply state that your system should have certain properties."*
**Practical here?** **WORK (commercial).** The BEAM's non-determinism is invisible to a
hypervisor — this is the one route to real DST for an Elixir system without rewriting
it. But it is a spend, not a Tuesday.
**Steal this for free:** **"sometimes assertions."** Antithesis argues coverage tools
are *"equivalent to adding assertSometimes(true) to every line"*, while a hand-placed
`assert_sometimes` says "this rare state must be reachable, and my tests must reach
it". Cheap and immediately useful (see item 44).
**Concrete first test.** Not applicable without the platform. Instead: add
`assert_sometimes` counters at (a) torn-tail detected during replay, (b) checkpoint
CRC mismatch on open, (c) keyring reconciliation corrected a restored key store, (d)
S3 backup retried. Fail the suite if any never fires.
**Source.** https://antithesis.com/docs/introduction/how_antithesis_works/ ·
https://antithesis.com/docs/concepts/properties_assertions/sometimes_assertions/ ·
https://antithesis.com/case_studies/mongodb_productivity/ ·
https://antithesis.com/blog/deterministic_hypervisor/

#### 9. TigerBeetle's VOPR
**What it is.** The Viewstamped Operation Replicator: TigerBeetle's deterministic
simulator, with *"injectable controls for all non-determinism including virtual clock,
deterministic RNG, simulated network and disk I/O, a failure-injection scheduler,
workload generators, state snapshotting, and a seed-based replay mechanism."* Faults
include packet drop/reorder/partition and **corruption of disk reads and writes** — up
to ~8 % corruption probability on the storage read path and ~9 % on the write path per
replica. *"One minute of VOPR time is equivalent to days of real-world testing."*
Reproduction is by **(seed, git commit)**. They run 10 VOPRs 24/7. A checker asserts
data files are **byte-for-byte identical across caught-up replicas**.
**Bugs found.** Consensus safety, recovery-from-corruption, and — after the split into
**liveness mode** (item 10) — livelocks and resonance bugs.
**Cost.** Very high; the storage and network layers must be interfaces from day one.
**Practical here?** **Partially, and the partial part is valuable.** You cannot make
the BEAM deterministic, but you *can* make `LazyRiver.Store` a fault-injectable
interface — it already is a behaviour with three functions. Add
`LazyRiver.Store.Faulty` implementing `LazyRiver.Store` with a seeded RNG that
corrupts, short-writes, delays, or `EIO`s a configurable fraction of appends and
replays. That gives ~70 % of the VOPR's storage-fault value for ~1 % of the cost,
because the seam already exists ("*the ledger is the seam*", per the moduledoc).
**Concrete first test.** `Store.Faulty` wrapping `Store.File`, seeded from
`System.get_env("LR_SEED")`, defaulting to a random seed printed on failure. Property:
for any seed, after any sequence of faulty appends and a reopen, the recovered facts
are a **prefix** of the facts whose `append` returned `{:ok, _}`.
**Source.** https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md

#### 10. Safety mode vs liveness mode (TigerBeetle)
**What it is.** Uniform random fault injection checks *safety* but hides *liveness*
bugs, because every fault eventually heals and every replica eventually restarts. So
they added a liveness mode: pick a quorum "core", heal all faults inside the core,
**freeze all faults outside it permanently**, and require the core to make progress.
**Bugs found.** A real one: aggressive parallel repair + round-robin repair targets
"resonated" so replica A perpetually asked the wrong peer for each missing op —
invisible in safety mode because a restart reset the counter.
**Cost.** Low conceptually; it is a change to how the fault schedule is generated.
**Practical here?** **YES, in miniature.** The lesson generalizes to any system with
retries and background work: *make one fault permanent and require progress anyway.*
**Concrete first test.** Make the S3 backup target permanently fail (not
intermittently) and assert the DB keeps serving writes, the backup lag metric in
`Vitals` grows monotonically, and the retry loop does not busy-spin a scheduler. Same
for a permanently unavailable KMS: `Keyring.GCP` must degrade to "cannot write new
subjects" without wedging reads of already-unwrapped keys.
**Source.** https://tigerbeetle.com/blog/2023-07-06-simulation-testing-for-liveness/

#### 11. Vortex — the deliberately *non*-deterministic companion
**What it is.** TigerBeetle's admission that DST has a blind spot. Vortex is a
*"generative full-system test suite"* against **stock release binaries** and real
client libraries, wiring everything through a TCP proxy for network faults (delay,
loss, corruption) and killing/pausing real processes. Rationale: the network and
storage implementations are *stubbed out* in DST, and language bindings are not
covered at all. Four months old at time of writing → two bugs (a client batching bug
creating open chains of linked events; a double-termination on connection close).
**Bugs found.** Everything in the layer the simulator replaced with a mock: real I/O,
real FFI, real process lifecycle.
**Cost.** Moderate — a supervisor process, a proxy, and real binaries.
**Practical here?** **YES, and it is what the existing `crash_recovery_test.exs`
already is.** That test spawns a real `elixir -S mix run` writer via `Port.open` and
SIGKILLs it. Extend rather than replace it.
**Concrete first test.** Extend the crash harness: put the ledger directory behind a
fault filesystem (item 36 or 37), add a second writer process on a second ledger, and
add a *reader* process that continuously reopens snapshot names recorded before the
crash — asserting that a name that answered X before the crash answers X after it.
That last assertion is the repo's central doctrine ("*an answer at a name is the same
answer forever*") and nothing currently tests it across a crash.
**Source.** https://tigerbeetle.com/blog/2025-02-13-a-descent-into-the-vortex/

#### 12. The Rust DST ecosystem — madsim, turmoil, shuttle, loom
**What they are, and why they are the right comparison.**
- **madsim** — *"Magical Deterministic Simulator"*: a Tokio-API-compatible runtime
  that intercepts libc (`gettimeofday`, `clock_gettime`, `getrandom`, `sysconf`) and
  patches third-party crates via Cargo `[patch]`. Used by RisingWave for continuous
  end-to-end simulation. Key constraint stated plainly: *"all [code] on all nodes must
  be executed on a single thread"*, and *"third-party libraries with internal
  randomness cannot be used."*
- **turmoil** (Tokio) — simulates hosts, time and network, running *"multiple
  concurrent hosts within a single thread"*; you swap `tokio::net` types for turmoil's
  behind a feature flag.
- **shuttle** (AWS) — **randomized** concurrency testing (PCT algorithm), explicitly
  *not sound* but scales far past loom's exhaustive search: *"randomized testing is
  successful at finding most concurrency bugs, which tend not to be adversarial."*
  This is the one AWS used to check ShardStore's linearizability (item 47).
- **S2's "mad-turmoil"** — combines both, and adds a CI **meta-test** that reruns the
  same seed and diffs TRACE logs byte-for-byte to prove determinism did not rot.
**Bugs found.** Interleaving-dependent bugs, reproducibly.
**Cost.** For Rust, moderate. For us, this is a **design lesson**, not a tool.
**Practical here?** **NO directly; the lessons transfer.** The transferable ones:
(1) put the environment behind an interface and swap it in tests — Lazy River already
does this for `Store` and `Keyring` and `Backup.Target`; (2) **randomized scheduling
beats exhaustive scheduling on real code** (shuttle's thesis) — which is exactly why
item 20/25 matter more than item 26 here; (3) a **determinism meta-test** is cheap and
catches determinism rot.
**Concrete first test.** Seed-driven `Store.Faulty` (item 9) plus a meta-test: run the
same seed twice and assert the two recovered fact lists are equal. If they differ, the
"deterministic" harness isn't.
**Source.** https://github.com/madsim-rs/madsim · https://tokio.rs/blog/2023-01-03-announcing-turmoil ·
https://github.com/awslabs/shuttle · https://s2.dev/blog/dst ·
https://risingwave.com/blog/deterministic-simulation-a-new-era-of-distributed-system-testing/

#### 13. **Is DST feasible on the BEAM? — the honest answer: no, and here is why**
Four independent blockers, in order of severity:

1. **Preemptive, multi-core, reduction-counted scheduling.** The BEAM preempts a
   process after a reduction budget, across N scheduler threads bound to cores. There
   is no seed, no hook, no supported way to make the scheduler replay a decision
   sequence. `erl +S 1` (one scheduler) reduces the *interleaving space* but does not
   make it deterministic — preemption points still depend on reduction counts that
   depend on runtime data, GC and JIT.
2. **Time is a system service, not an argument.** `System.monotonic_time/0`,
   `:erlang.now`, `receive ... after`, `:timer`, and `Process.send_after` all read the
   VM's time source. There is no `tokio::time::pause` equivalent. Replacing time means
   replacing every call site behind your own module — feasible in your own code,
   impossible in OTP, Phoenix, Bandit and `:ssl`.
3. **Concurrency is the unit of structure.** A gen_server per ledger, a supervision
   tree, a websocket process per subscriber. Collapsing all of that onto one
   deterministic thread is not a test harness, it is a different program. madsim/FDB
   both require exactly this collapse and say so.
4. **NIFs and ports.** Wasmex (formula sandbox), `:ssl`/`:inets` (S3, KMS) and any
   crypto are native code with their own entropy and their own threads. Concuerror's
   own FAQ says it *"cannot intercept, instrument or perform race analysis in modules
   using NIFs and is very likely to crash if such modules are used"* — the same
   fundamental problem a BEAM simulator would hit.

**Has anyone done deterministic replay on the BEAM?** The closest real artefact is
**PULSE** (item 25): a *user-level* scheduler implemented in Erlang, with an
instrumenting compiler, that takes control of message sends/deliveries and spawns for
*instrumented* processes only. Its authors were explicit about why: *"Erlang's
scheduler is built into its virtual machine—and we did not want to modify the virtual
machine itself... we decided to implement PULSE in Erlang, as a user-level scheduler."*
It gives **repeatable schedules from a seed** for the instrumented subset — real
determinism, but scoped, and it does not control time, disk or the OS. **Concuerror**
(item 26) achieves the same "one process at a time, replayable" property by
instrumentation, and pins non-deterministic function results per exploration branch.
Both are ~15-year-old research lineages that never became "run your database under a
simulator".

**Therefore: do not attempt BEAM DST. The practical substitute is a four-part stack:**
- **(a) Fault-injectable seams** instead of a simulated world — `Store.Faulty`,
  `Keyring.Faulty`, `Backup.Target.Faulty`. Seeded, replayable *inputs* even though
  the *schedule* is not.
- **(b) Stateful property-based testing** (items 15–19) for interleaving-free logic and
  `proper`'s parallel mode for the racy parts.
- **(c) Trace-based testing** (item 24, snabbkaffe) as the BEAM's native answer to
  "check a history rather than a state".
- **(d) Real-process crash + disk fault injection** (items 5, 32–38) for the durability
  claims, since those are OS-level and don't need a simulator at all.
**Source.** https://smallbone.se/papers/finding-race-conditions.pdf ·
https://parapluu.github.io/Concuerror/faq/ · https://www.erlang.org/doc/apps/erts/erlang.html

#### 14. Seeded fault injection as the DST substitute (`Store.Faulty`)
**What it is.** The 20 %-of-DST that gets 80 % of the value on a runtime you cannot
make deterministic: keep the schedule non-deterministic, make the *faults* seeded and
replayable.
**Bugs found.** Recovery bugs, error-path bugs, partial-write handling, retry storms.
Note this is precisely what AWS did for ShardStore crash consistency (item 47) — they
did not simulate the world, they wrote a reference model and injected crashes.
**Cost.** Low. One module implementing an existing behaviour.
**Practical here?** **YES. Do this first among the DST-ish items.**
**Concrete first test.** `LazyRiver.Store.Faulty` with fault modes {`:short_write` (n
bytes of the record land), `:corrupt_write` (flip a bit), `:eio_on_append`,
`:eio_on_sync`, `:delay`, `:silent_drop`}. Property over 1000 seeds: recovered log is
a prefix of acknowledged appends; a `:short_write` never yields a CRC-valid record
that decodes to a *different* fact.
**Source.** https://jamesbornholt.com/papers/shardstore-sosp21.pdf

---

### C. BEAM property-based and model-based testing — the core of the recommendation

#### 15. PropEr (Erlang) and PropCheck (Elixir wrapper)
**What it is.** PropEr is the open-source QuickCheck for Erlang; **PropCheck** wraps it
for Elixir and *"allows to define properties, which are automatically executed via
ExUnit when running mix test"*, storing counterexamples in `_build/propcheck.ctex` so a
failure replays. Deps: `{:propcheck, "~> 1.4", only: [:test, :dev]}`.
**Bugs found.** Everything an example-based test forgot: boundary values, empty and
huge inputs, unicode, non-ASCII ledger names, unusual term shapes.
**Cost.** Very low to start. One known limitation: PropCheck *"does not support
PropEr's capability to derive automatically type generators from type specifications"*
in Elixir — write generators by hand.
**Practical here?** **YES.**
**Concrete first test.** `forall facts <- list(fact())` : write to a `Store.File`,
close, reopen, assert `replay/1` equals the input. Then the same with
`checkpoint_every` drawn from `1..50`. This alone should shake out the checkpoint
`byte_offset` path.
**Source.** https://hexdocs.pm/propcheck/readme.html · https://github.com/alfert/propcheck

#### 16. StreamData / ExUnitProperties (built-in)
**What it is.** Elixir's in-tree property testing: `check all a <- StreamData.binary(),
b <- StreamData.binary() do ... end`, with automatic **shrinking** to a minimal failing
input. 100 runs by default, configurable.
**Bugs found.** Same class as PropEr for *stateless* properties.
**Cost.** Near zero — no new dependency category, familiar syntax, good docs.
**Limitation that matters here.** StreamData has **no stateful/model-based mode** — no
`StateM`, no command sequences, no parallel testing. For a database, that is the
feature you actually want (item 17).
**Practical here?** **YES for pure functions; NOT SUFFICIENT for the ledger.** Use
StreamData for `Wire`, `Symbol.Text`, `Fact` encoding, `Formula` evaluation; use
PropCheck.StateM for `Ledger`/`Store`/`Keyring`.
**Concrete first test.** `check all fact <- fact_generator() do assert
Wire.decode(Wire.encode(fact)) == fact end` — a round-trip property for the wire
format, and a second one asserting `Store.File.filename/1` output is ≤ 255 bytes for
any ledger name (I expect this to fail immediately for a long binary name).
**Source.** https://hexdocs.pm/stream_data/ExUnitProperties.html

#### 17. **Stateful / model-based property testing (`proper_statem`, PropCheck.StateM) — the highest-value technique for this system**
**What it is.** You write an *abstract state machine* — a model — and PropEr generates
random **symbolic command sequences** against both the model and the real system,
checking after each step that the system evolved as the model says. Five callbacks:
`initial_state/0`, `command/1` (generate the next call given model state),
`precondition/2` (is this call legal now?), `next_state/3` (how the model changes),
`postcondition/3` (did the system's actual return match the model?). On failure,
*"the shrinking mechanism attempts to find a minimal sequence of calls provoking the
same error."* Symbolic generation matters because *"the generation phase is
side-effect free and this results in repeatable test cases, which is essential for
correct shrinking."* PropCheck adds `PropCheck.StateM.ModelDSL`, a friendlier
`command :name do ... end` layer. Lineage: Quviq `eqc_statem` → `proper_statem` →
PropCheck.
**Parallel mode.** `parallel_testcase`: a sequential prefix puts the system in a random
state, then *"a random suffix (up to 12 commands)"* is split into two sequences run in
**two separate spawned processes**, and the result must be explicable by *some*
sequential interleaving — i.e. a linearizability check. That is race detection with a
model, on the real BEAM scheduler.

**Bugs found.** This is the technique with the best industrial record on the BEAM.
John Hughes's *"Experiences with QuickCheck: Testing the Hard Stuff and Staying Sane"*
reports the AUTOSAR/Volvo Cars programme — acceptance tests for AUTOSAR C code,
clustering per-component models into integrated subsystem models, plus a race-detection
method that resolved a notorious Klarna bug. Basho used `eqc_statem` on `riak_dt`,
`riak_core` and the leveldb bindings for the same reason: CRDT merge laws and log/
compaction invariants are *stateful*, and unit tests cannot cover the state space.

**Cost.** Moderate — a day to get the first model right, then cheap forever. The model
must be *simpler* than the implementation or it is worthless; AWS's ShardStore rule is
the one to copy: reference models were *"1 % of the implementation code"*, and *"the
reference model for a log-structured merge tree implementation is a hash map."*

**Practical here?** **YES — this is the single best fit for Lazy River.** The system's
semantics are unusually model-friendly: a ledger is a list, a snapshot is a `{ledger =>
tx}` map, an answer at a name is a pure function of the facts ≤ tx. The model is
**one page of Elixir**: `%{ledgers: %{name => [fact]}, erased: MapSet.t()}`.

**Concrete first test — write this one.**
```
commands: open_ledger(name) | append(ledger, facts) | open_snapshot([ledgers])
        | find(snapshot_name, pattern) | close_and_reopen(ledger)
        | checkpoint_now(ledger) | erase(subject) | crash_and_reopen(ledger)
model:    %{ledgers: %{name => [fact]}, tx: n, subjects: %{id => subject},
             erased: MapSet.new(), snapshots: %{name => %{ledger => tx}}}
postconditions:
  1. find(name, pattern) == model_find(name, pattern)            # correctness
  2. find(old_name, pattern) is invariant under later appends    # THE doctrine
  3. after erase(s): every fact whose subject is s answers :erased,
     and every other fact is unchanged                           # erasure
  4. after close_and_reopen: replay == model's fact list         # durability
  5. after crash_and_reopen: replay is a PREFIX of the model's list
     (proper prefix allowed only when sync: false)               # crash safety
```
Then flip on `parallel_testcase` for `append`/`find` to hunt races in `Ledger`'s
gen_server.
**Source.** https://hexdocs.pm/propcheck/PropCheck.StateM.html ·
https://hexdocs.pm/propcheck/PropCheck.StateM.ModelDSL.html ·
https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quviq-testing.pdf

#### 18. `proper_fsm` — the finite-state-machine flavour
**What it is.** A variant of `statem` where the model state is an explicit *named
state* plus data, with per-state command generators. Better than `statem` when the
system genuinely has modes.
**Bugs found.** Illegal transitions; commands accepted in a state where they should be
refused.
**Cost.** Same as `statem`; use whichever fits.
**Practical here?** **YES for two components specifically**: the **backup lifecycle**
(`idle → snapshotting → uploading → verifying → idle | failed`) and the **keyring
reconciliation** (`fresh → loaded → reconciling → corrected | consistent`). Both are
mode machines that a flat `statem` model would blur.
**Concrete first test.** Model `Keyring`: states `{:no_store, :store_loaded,
:reconciled}`; commands `create_subject`, `erase_subject`, `restore_old_key_store`,
`reopen`. Postcondition: after `restore_old_key_store` + `reopen`, any subject with a
tombstone is *not* usable — the restored key must have been destroyed again. This is
the erasure guarantee, and it is currently only covered by example tests.
**Source.** https://hexdocs.pm/propcheck/PropCheck.StateM.html

#### 19. Targeted property-based testing (TPBT)
**What it is.** PropEr/PropCheck's `PropCheck.TargetedPBT`: instead of uniform random
generation, a search strategy (simulated annealing) steers generation toward
user-defined "interesting" measures.
**Bugs found.** Deep states random generation rarely reaches — e.g. a ledger with many
checkpoints *and* an erasure *and* a torn tail simultaneously.
**Cost.** Low incremental cost once a `statem` model exists; you add a utility
function.
**Practical here?** **YES, later.** Adopt after item 17 is running and you notice the
generator never produces sequences that both checkpoint and erase.
**Concrete first test.** Target: maximize `number_of_checkpoints × number_of_erasures ×
crash_count` in a sequence, then assert the same postconditions.
**Source.** https://hexdocs.pm/propcheck/readme.html (TargetedPBT section)

#### 20. Differential testing against an in-memory reference model
**What it is.** Run two implementations of the same interface on the same input and
diff. AWS S3's ShardStore made this a discipline: *"executable reference models as
specifications"*, written **in the implementation language and committed beside the
code**, reused as mocks in unit tests, checked by property-based testing for functional
correctness, by property-based testing *with crashes* for crash consistency, and by
stateless model checking (shuttle) for linearizability. Result: **16 issues prevented
from reaching production**, with reference models at 1 % and the total harness at
~12–13 % of the implementation's 40k lines of Rust; 18–20 % of the model code was later
written by non-formal-methods engineers.
**Bugs found.** Any divergence: wrong answer, wrong ordering, wrong error, wrong
post-crash state.
**Cost.** Low here — **the reference implementation already exists**:
`LazyRiver.Store.Memory` is a 20-line list-append store implementing the same
behaviour as `Store.File`. That is a reference model that shipped by accident.
**Practical here?** **YES, and it is nearly free.** This is the cheapest high-yield
item after elle-cli.
**Concrete first test.** One property: for any command sequence, `Store.File` and
`Store.Memory` produce the same `replay/1`. Then extend the diff across a
`close`/`open` cycle (Memory loses everything by design — so the property becomes
"File ⊇ Memory-at-close", which is exactly the durability claim stated as a diff).
**Source.** https://jamesbornholt.com/papers/shardstore-sosp21.pdf ·
https://aws.amazon.com/blogs/storage/how-automated-reasoning-helps-us-innovate-at-s3-scale/

#### 21. Metamorphic testing for query engines (SQLancer: PQS, NoREC, TLP)
**What it is.** You cannot know the right answer to a random query, so instead you
derive a *second* query whose answer must relate to the first in a known way.
- **PQS** (Pivoted Query Synthesis): pick a random row, synthesize a query guaranteed
  to fetch it; if it doesn't, that's a bug. **121+ unique logic bugs.**
- **NoREC**: translate an optimizable query into one where hardly any optimization
  applies; results must match. **51 optimization bugs.**
- **TLP** (Ternary Logic Partitioning): a predicate `p` is TRUE, FALSE, or NULL, so
  `Q` decomposes into three partitioning queries whose union must equal `Q`. Works on
  WHERE, GROUP BY, HAVING, aggregates and DISTINCT. The TLP paper reports **175 bugs
  in MySQL, TiDB, SQLite and CockroachDB, 125 fixed, 77 of them logic bugs.**
Rigger's SQLancer has found hundreds of bugs across mature DBMSs, and SQLite's own
testing page credits him with finding *incorrect answers*, not just crashes.
**Bugs found.** **Logic bugs** — wrong result sets that no crash reveals and no user
notices. For a database this is the most dangerous bug class in existence.
**Cost.** Moderate. You need a query generator and one metamorphic relation.
**Practical here?** **YES, adapted — and under-appreciated for this system.** Lazy
River has no SQL, but it has a query surface: `Snapshot.find/2` patterns, formulas, and
the `ask` operation. The metamorphic relations are obvious and strong:
  - **Partitioning:** `find(s, id: x)` == `find(s, id: x, attribute: a) ∪ find(s, id: x,
    attribute: ≠a)` for every attribute `a` present.
  - **Snapshot monotonicity:** for `tx1 ≤ tx2`, `find` at `tx1` ⊆ `find` at `tx2`
    (modulo erasure).
  - **Composition:** `find` over a snapshot of ledgers {A,B} == `find` over {A} ∪ `find`
    over {B}, always, in any order — this directly tests the `Snapshot.facts/1`
    map-iteration ordering concern.
  - **Formula equivalence (NoREC-style):** a formula's declared derivation must equal
    the same computation done naively over `Snapshot.facts/1` with no index. If
    `index.ex` ever optimizes a lookup, this catches the optimization being wrong.
**Concrete first test.** The composition relation, as a StreamData property over
randomly generated multi-ledger snapshots. It is three lines and it tests the one
place ordering is decided by a map.
**Source.** https://www.manuelrigger.at/preprints/TLP.pdf · https://github.com/sqlancer/sqlancer ·
https://www.usenix.org/system/files/osdi20-rigger.pdf (PQS) · https://arxiv.org/abs/2007.08292 (NoREC)

#### 22. Dialyzer (success typing)
**What it is.** OTP's static analyser: finds *definite* type discrepancies from
success typings; never reports a false positive by design, and correspondingly misses
a lot.
**Bugs found.** Impossible pattern matches, calls that can never succeed, unreachable
clauses, wrong arity, misuse of opaque types, functions that always raise. In a system
with `@behaviour` callbacks (Store, Keyring, Backup.Target) it catches signature drift
across implementations.
**Cost.** One-time PLT build (slow), then minutes per run; a `dialyzer` entry in
`mix.exs` plus caching in CI.
**Practical here?** **YES — and it is a gap right now** (no `:dialyxir` in `mix.exs`).
**Concrete first test.** `just check` runs `mix dialyzer` with the PLT cached. Expect
it to flag at least the `Store` callback return shapes and any `File.read` result
handling that ignores `{:error, reason}`.
**Source.** https://www.erlang.org/doc/apps/dialyzer/dialyzer.html · https://hexdocs.pm/dialyxir/

#### 23. Gradient / gradualizer (Elixir gradual typing)
**What it is.** A gradual type checker for Elixir built on Erlang's `gradualizer`,
checking against `@spec`s more aggressively than Dialyzer. (Note: Elixir 1.18+ ships
its own set-theoretic type inference for pattern matching, which now overlaps.)
**Bugs found.** Spec/implementation mismatch, nil-ability errors, wrong return shapes.
**Cost.** Low, but noisier than Dialyzer; expect to suppress.
**Practical here?** **Marginal.** Given the repo is on Elixir ~> 1.18, the built-in
type warnings plus Dialyzer cover most of it. Adopt only if `@spec` coverage is high
and you want it enforced.
**Concrete first test.** Skip. Prefer item 22.
**Source.** https://github.com/esl/gradient

#### 24. Trace-based testing (snabbkaffe) — the BEAM's native answer to Elle
**What it is.** *"If humans can find bugs by reading the logs, so can computers."*
Snabbkaffe (from the EMQX team, used heavily in the Mria replication database) splits a
test into a **run stage** that emits a structured event trace and a **check stage**
that validates the trace against composable specs. Trace points become ordinary
structured log messages in release builds. It also supports **fault and delay
injection** at those same trace points, to test supervision-tree correctness and rare
code paths.
Their motivating argument is precisely the BEAM problem this document keeps hitting:
state is partitioned across a supervision tree and self-heals, so *"state of a
self-healing system... is very hard to model"* — therefore analyse the **sequence of
actions**, not the state.
**Bugs found.** Ordering bugs, livelocks, missing/duplicate effects, a supervisor
restart that silently loses work, an effect that happened twice, an effect that
happened in the wrong phase.
**Cost.** Low-moderate: manual instrumentation at meaningful points, plus the check DSL.
Erlang library, usable from Elixir.
**Practical here?** **YES, and it is the closest thing to "Jepsen for one BEAM node."**
It composes with items 5 and 17 rather than competing.
**Concrete first test.** Instrument: `append_written`, `fsync_done`,
`checkpoint_written`, `checkpoint_renamed`, `torn_tail_detected`, `replay_started`,
`replay_finished`, `key_destroyed`, `tombstone_written`, `backup_uploaded`. Then the
check: **`key_destroyed` must never appear without a preceding `tombstone_written` for
the same subject, and `checkpoint_renamed` must never precede the `fsync_done` of the
last transaction it claims to cover.** That second spec is the crash-consistency bug I
suspect exists (see item 33).
**Source.** https://github.com/kafka4beam/snabbkaffe ·
https://www.emqx.com/en/blog/advanced-testing-of-erlang-and-elixir-applications

---

### D. BEAM concurrency, chaos, and observability

#### 25. PULSE (Quviq user-level scheduler)
**What it is.** *"A randomizing scheduler for Erlang, which can be used to find race
conditions in concurrent Erlang code"*, from the ICFP 2009 paper. Instruments modules
at compile time; takes control of spawns, sends, receives and registry ops for
instrumented processes; runs one at a time; picks the next randomly at each decision
point; **same seed ⇒ same schedule**, so tests are repeatable. Maintains per-pair
message queues to respect Erlang's only ordering guarantee. Detects deadlock when all
processes block with no deliverable message. Ships a GraphViz trace visualizer.
Combined with `eqc_par_statem` it found two race conditions and an API design flaw in
an industrial process registry — including a *simpler* minimal counterexample than the
built-in scheduler produced.
The paper's diagnosis of why unit tests miss races is the key sentence for this
document: *"The Erlang virtual machine runs processes for relatively long time-slices,
in order to minimize the time spent on context switching—but as a result, it is very
unlikely to provoke race conditions in small tests."*
**Bugs found.** Races, deadlocks, atomicity violations in gen_server-mediated state.
**Cost.** **Commercial** (part of Quviq QuickCheck). That is the blocker.
**Practical here?** **NO (licensing)** — but its free descendants are usable:
PropCheck's `parallel_testcase` (item 17) gives the *generation* half, and Concuerror
(item 26) gives the *systematic* half.
**Concrete first test.** N/A. Use `parallel_testcase` instead.
**Source.** https://smallbone.se/papers/finding-race-conditions.pdf ·
https://quviq.com/documentation/pulse/overview-summary.html

#### 26. Concuerror (stateless model checking with DPOR)
**What it is.** *"A stateless model checking tool for Erlang programs"* that
systematically explores all "meaningfully different" schedulings, so it can **verify
the absence** of race/deadlock errors, not merely search for them. It instruments and
reloads modules automatically via the code path, runs one process at a time, logs
shared-state operations, finds racing pairs, and replays with reversed orders —
**Optimal Dynamic Partial Order Reduction** — with `--show_races`, `--graph`, and
`--interleaving_bound` for when the space is too big.
**Hard limits, from its own FAQ, all of which matter here:**
- It needs a **terminating** test. An infinite loop or an unstopped supervisor never
  finishes an interleaving.
- Time: it *"normally disregards the actual timeout values"*; a `receive ... after`
  clause is always assumed reachable, and `send_after` messages may arrive any time
  until cancelled. `--after-timeout N` treats larger timeouts as infinity.
- Non-determinism: the first result of a non-deterministic function is **recorded and
  replayed** on later branches, which can produce nonsense like elapsed-time deltas
  growing every interleaving.
- **NIFs: "Concuerror cannot intercept, instrument or perform race analysis in modules
  using NIFs and is very likely to crash if such modules are used."**
- No random-testing mode; only schedule bounding.
- Complexity is exponential in the general case; the model must be kept small.
**Bugs found.** Genuine race conditions and deadlocks — with a proof of absence for the
scoped test.
**Cost.** Moderate-high. Erlang escript (`bin/concuerror`), works on Elixir-compiled
BEAM files with setup (point it at `_build/test/lib/lazy_river/ebin`, call the test
function by MFA). Must isolate a small, terminating, NIF-free unit.
**Practical here?** **WORK, narrowly scoped.** Do **not** point it at the application;
Wasmex, `:ssl` and `:crypto` are NIFs and it will crash. Do point it at a hand-built
harness that starts a `Ledger` gen_server and two client processes.
**Concrete first test.** A 30-line Erlang/Elixir entry point: start one `Ledger` with
`Store.Memory`, spawn two processes that each `append` once and then `Snapshot.open`,
wait for both, halt. Concuerror must report no deadlock and no unexpected result across
all interleavings. If `Ledger` ever reads-then-writes its `tx` counter outside the
gen_server, this finds it exhaustively.
**Source.** https://parapluu.github.io/Concuerror/ · https://parapluu.github.io/Concuerror/faq/ ·
https://github.com/parapluu/Concuerror · https://concuerror.com/assets/pdf/ICST2013.pdf

#### 27. `mix test --repeat-until-failure` and `--seed`
**What it is.** Since Elixir 1.17: *"sets the number of repetitions for running the
suite until it fails... useful for debugging flaky tests within the same instance of the
Erlang VM."* Combine with `--max-failures 1` to stop instantly. `--seed` seeds the
randomized test order; `--seed 0` disables randomization.
**Bugs found.** Flakes — which in a database are usually *real* concurrency or
durability bugs wearing a costume.
**Cost.** Zero. It is a flag.
**Caveat from the docs, worth internalizing:** *"if there is any leftover global state
after running the tests, re-running the suite may trigger unrelated failures"* — and
re-running with the same seed does **not** guarantee the same async interleaving.
**Practical here?** **YES, today.**
**Concrete first test.** A nightly CI job: `mix test --include crash
--repeat-until-failure 500 --max-failures 1`. Any failure is a ticket.
**Source.** https://hexdocs.pm/mix/Mix.Tasks.Test.html

#### 28. ExUnit `async: true` hazards
**What it is.** ExUnit runs *modules* (not tests within a module) concurrently, up to
`--max-cases` (default 2× cores). Async is safe only when tests share **no** global
state: no named processes, no shared ETS, no shared files, no application env, no
singleton GenServer.
**Bugs found (in the tests, and sometimes in the code).** Cross-test interference,
order-dependent passes, and — usefully — genuine concurrency bugs surfaced by
accidental parallelism.
**Cost.** Zero to audit.
**Practical here?** **YES, and there is a specific hazard in this repo**: ledger files
live under a `dir` option, and `Store.File.filename/1` is a pure function of the ledger
name — two async tests using the same ledger name and the same default `dir`
(`priv/ledgers`) will collide. `Application.put_env`-style config (`LEDGER_DIR`,
`KMS_KEY`) is global and cannot be set per-async-test.
**Concrete first test.** Audit: `grep -L "async: true" test/*.exs` to find sync tests,
then verify every async test uses a unique tmp dir (as `crash_recovery_test.exs`
already does with `System.unique_integer`). Add a `setup` helper that mints a unique
ledger name **and** dir, and make using the default `priv/ledgers` in tests a lint
failure.
**Source.** https://hexdocs.pm/ex_unit/ExUnit.Case.html ·
https://blog.appsignal.com/2021/12/21/eight-common-causes-of-flaky-tests-in-elixir.html

#### 29. `:sys` and `:erlang.trace` — white-box observation without mocks
**What it is.** `:sys.get_state/1`, `:sys.get_status/1`, `:sys.statistics/2`,
`:sys.trace/2`, `:sys.replace_state/2` (an OTP-blessed way to inspect and *corrupt* a
gen_server's state), plus `:erlang.trace/3` + `:erlang.trace_pattern/3` for
call/return/send/receive tracing, and `:dbg`/`recon_trace` on top.
**Bugs found.** State that drifts from what the process claims; messages sent that
shouldn't be; a gen_server that never receives a message it waits for; missing
back-pressure.
**Cost.** Zero (in OTP). Danger: `:sys.replace_state` in production is a foot-gun; in
tests it is a fault injector.
**Practical here?** **YES.**
**Concrete first test.** Use `:sys.replace_state/2` to corrupt a `Ledger`'s in-memory
`tx` counter to a *lower* value, then `append` and assert the system either refuses or
recovers — never silently writes a fact with a duplicate `tx`. Duplicate `tx` would
break `Snapshot`'s sort and therefore the "same name, same answer" doctrine.
**Source.** https://www.erlang.org/doc/apps/stdlib/sys.html ·
https://www.erlang.org/doc/apps/erts/erlang.html#trace/3

#### 30. Mox / `:meck` for fault injection at behaviour boundaries
**What it is.** **Mox** — *"a library for defining concurrent mocks in Elixir"*, with
four rules: no ad-hoc mocks (only from `@behaviour`s), no dynamic module generation
during tests, **concurrency support so tests using the same mock can still be
`async: true`**, and assertion by pattern matching. Per-process expectations, with
explicit allowances or global mode for multi-process work. `:meck` (Erlang) is the
heavier hammer: it can mock *any* module, including OTP's, by reloading it.
**Bugs found.** Unhandled error returns from every I/O boundary — the single most
under-tested code in any database.
**Cost.** Very low. **The repo is already shaped for Mox**: `Store`, `Keyring` and
`Backup.Target` are `@behaviour`s selected by config, which is exactly Mox's
prescribed `impl()` pattern.
**Practical here?** **YES — do this immediately.**
**Concrete first test.** `MockKeyring` that returns `{:error, :unavailable}` for
`unwrap/1` on the *third* call: assert a `find` over a snapshot containing three
encrypted facts returns a partial answer with an explicit error rather than a crash or
a silently-empty result. Then `MockBackupTarget` that fails mid-upload: assert the next
run resumes rather than restarting, and that a half-uploaded generation is never marked
complete. Use `:meck` only where the boundary is not a behaviour (e.g. `:file.sync/1`).
**Source.** https://hexdocs.pm/mox/Mox.html · https://github.com/eproxus/meck

#### 31. Chaos on the BEAM — killing supervised processes
**What it is.** Randomly killing processes to prove the supervision tree actually
works. BEAM-flavoured tools: **chaos-spawn** (Elixir; keeps a list of processes and
periodically terminates them at random — *"the intention is that this should force the
design of an app's supervision tree to actually work"*), **chaosmonkey-elixir**, and
**Havoc** (kills random processes *and* TCP/UDP connections).
**Bugs found.** Supervision strategies that are wrong (`:one_for_one` where
`:rest_for_one` was needed), state lost on restart that should have been rebuilt,
restart storms hitting `max_restarts`, resources (file handles, KMS sessions) leaked on
abnormal exit.
**Cost.** Very low.
**Practical here?** **YES, and there is a specific durability question it answers.**
`Store.File` holds an open `:file` handle in gen_server state. If the `Ledger` process
is killed and restarted mid-transaction, does the new process reopen cleanly, and does
`bytes` (tracked manually, per the moduledoc's own warning about `:append` mode) come
back correct?
**Concrete first test.** Under load (reuse `load_test.exs`), kill the `Ledger` process
for a ledger every 200 ms for 30 s with `Process.exit(pid, :kill)`, while a client
appends and records acknowledgements. Assert: every acknowledged tx is present after
the run; the file handle count (`:erlang.system_info(:port_count)`) does not grow; the
supervisor never exceeds `max_restarts`.
**Source.** https://github.com/meadsteve/chaos-spawn ·
https://github.com/dnsbl-io/chaosmonkey-elixir · https://principlesofchaos.org/

---

### E. Crash consistency and disk fault injection

#### 32. ALICE / BOB (OSDI '14, "All File Systems Are Not Created Equal")
**What it is.** The first comprehensive study of application-level crash-consistency
protocols. **BOB** empirically tests which *persistence properties* a file system
actually provides (atomicity of appends, ordering between operations, etc.) —
demonstrating they *"vary widely among six popular Linux file systems"*. **ALICE**
analyses an application's update protocol and finds **crash vulnerabilities**: protocol
code that is only correct if a particular persistence property happens to hold.
**Findings.** **60 vulnerabilities across 11 applications** — 5 silent failures, 12
losses of durability, 25 leading to inaccessible applications, 17 returning errors.
Applications studied included databases, KV stores, VCS and distributed systems.
**Bugs found.** "This works on ext4 with default options and corrupts on XFS", "this
rename is not atomic the way you assumed", "this append is not atomic past a sector".
**Cost.** ALICE itself is research software and dated; the *checklist* is free.
**Practical here?** **The tool: NO. The finding: directly applicable, YES.**
Lazy River's checkpoint protocol is `write(tmp)` → `rename(tmp, final)` with **no
fsync of tmp before the rename and no fsync of the directory after it**. ALICE's whole
thesis is that this is a crash vulnerability whose severity depends on the filesystem
and mount options. On ext4 with `data=ordered` you usually get away with it; you should
not be relying on "usually".
**Concrete first test.** A property test that, for each of {no fsync, fsync file only,
fsync file + dir}, simulates a crash at every write boundary and asserts the checkpoint
either doesn't exist or is fully valid *and* consistent with the log's length. Then fix
the protocol: `:file.sync` the tmp file, rename, then `:file.sync` the **directory**
handle.
**Source.** https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf ·
https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai

#### 33. CrashMonkey and ACE (OSDI '18, bounded black-box crash testing)
**What it is.** **B³** — bounded black-box crash testing. **ACE** exhaustively
generates all workloads within a bound (number of file-system operations, which
operations to include); **CrashMonkey** is *"a record-and-replay framework which tests a
given workload on the target file system by simulating power-loss crashes while the
workload is being executed, and checking if the file system recovers to a correct state
after each crash."*
**Findings.** Reproduced **24 of the 26** crash-consistency bugs reported in the
previous five years, and found **10 new bugs** in mature Linux file systems, **seven of
which had existed since 2014** — plus a bug in **FSCQ, a formally verified file
system**. Consequences included broken rename atomicity and loss of persisted files.
**Bugs found.** Crash inconsistency at *every* crash point in a bounded workload, not
just the ones a human thought of.
**Cost.** The tool targets file systems, not applications; adapting it is a project.
**The idea, however, is cheap:** bound the workload space and test **every** crash
point, rather than crashing at a random moment.
**Practical here?** **The idea: YES.** This is the correct generalization of the
existing `crash_recovery_test.exs`, which crashes once at a semi-random time.
**Concrete first test — "bounded exhaustive crash points".** Instrument `Store.File`
with a `crash_after: n` option that halts the VM (`:erlang.halt(1)`) after the *n*-th
`:file.write`/`:file.sync`/`:file.rename` syscall. Then for a fixed 20-transaction
workload with a checkpoint at 10, run *every* n from 1 to the syscall count, restart,
and assert the prefix invariant. That is ~80 subprocess runs, a few minutes, and it is
**exhaustive** over that bound. This is the single most valuable durability test you
can write, and the SQLite harness does the same thing (item 41: *"the snapshot point
advances through the loop"*).
**Source.** https://www.cs.utexas.edu/~vijay/papers/osdi18-crashmonkey.pdf ·
https://www.usenix.org/conference/osdi18/presentation/mohan

#### 34. Torturing Databases for Fun and Profit (OSDI '14)
**What it is.** A framework to expose and diagnose ACID violations under **power
faults**: workloads that exercise ACID guarantees, a record/replay subsystem for
controlled injection of simulated power faults, a **ranking algorithm to prioritize
where to fault** based on the authors' experience, and a multi-layer tracer for root
cause. The atomicity checker is beautifully simple: *"if a fault occurs after commit,
all transaction rows should be present; otherwise, none of the rows should be
present—if only some rows are present, this is an atomicity violation."*
**Bugs found.** ACID violations in commercial and open-source databases under power
loss.
**Cost.** Framework is research code; the **checker** is 5 lines.
**Practical here?** **The checker: YES, verbatim.**
**Concrete first test.** Lazy River's unit of atomicity is one transaction = one
record. Post-crash assertion: for every transaction in the recovered log, **all** of
its facts are present or **none** are — never a partial set. Given the `<<size, crc,
payload>>` framing this *should* hold by construction, which makes it exactly the kind
of "obviously true" claim that deserves an executable assertion.
**Source.** https://www.semanticscholar.org/paper/Torturing-Databases-for-Fun-and-Profit-Zheng-Tucek/274e495824827f5a9dc1ba3ab62620445e6b3d4b

#### 35. "Can Applications Recover from fsync Failures?" (ATC '20 / TOS)
**What it is.** CuttleFS: a study of how ext4, XFS and Btrfs behave when `fsync` fails,
and how five applications react. Commonalities across file systems: **pages are always
marked clean** after a failed fsync (so a retry cannot flush them), and certain block
write failures always cause unavailability; differences in page content and error
reporting.
**Findings, application by application.** *"Although applications use many
failure-handling strategies, none are sufficient: fsync failures can cause catastrophic
outcomes such as data loss and corruption."* PostgreSQL can lose **both new and old
data** on update and chooses to **crash**; **Redis doesn't even check fsync return
codes**; LMDB, LevelDB and SQLite revert in-memory state. **None** of them retry fsync
— developers know a second fsync won't flush the lost pages. This is the "fsyncgate"
lineage: Linux cleared the error flag after the first failed fsync, so a retry returned
success while the data never reached disk.
**Bugs found.** The specific, brutal one: *code that treats a failed fsync as
retryable*.
**Cost.** Reading it: an hour. Acting on it: a design decision.
**Practical here? YES — and there is a live question in the code.** `Store.File.append`
does `if state.sync, do: :ok = :file.sync(state.io)`. The `:ok = ` match means a failed
sync raises `MatchError`, which kills the `Ledger` gen_server, which the supervisor
restarts, which **reopens the same file and continues appending** — i.e. it behaves as
if fsync were retryable. Per this paper, that is the wrong behaviour: the dirty pages
are already gone.
**Concrete first test.** With `:meck` on `:file.sync/1` (or a FUSE layer, item 36),
return `{:error, :eio}` once, then succeed. Assert the system does **not** report the
transaction as committed, does **not** continue appending to the same handle as if
nothing happened, and surfaces the failure to the caller. Decide and document the
policy — PostgreSQL-style crash is a defensible answer; silent continuation is not.
**Source.** https://www.usenix.org/system/files/atc20-rebello.pdf ·
https://dl.acm.org/doi/10.1145/3450338

#### 36. CharybdeFS (FUSE fault-injecting filesystem)
**What it is.** ScyllaDB's *"FUSE-based error injecting pass-through filesystem"* with
a **Thrift RPC interface** so faults are scriptable at runtime (unlike PetardFS's static
XML). It sits between the application and a real filesystem, can return *"basically all
the errors living in `<errno.h>`"* from any syscall Scylla uses (EIO, ENOMEM, EEXIST,
EDQUOT, ...) including under Linux AIO, can match faults by **filename or path regex**,
can fire with a **configurable probability**, can **delay** operations (simulating SSD
latency spikes), and — the key feature — can **`kill -9` the calling process on `sync`
or `flush`**, then you restart and check consistency.
**Bugs found at Scylla.** *"ScyllaDB was missing a consistent strategy to handle disk
errors"* — early releases only logged a debug message; the fix (shut down cleanly on
I/O error to preserve data) was rolled out across the code because of what this found.
**Cost.** Moderate: build a FUSE binary, run as root or in a privileged container,
drive it over Thrift from a test script (their examples are Python).
**Practical here?** **WORK — and it is the best fit of the disk-fault tools**, because
Lazy River's fault surface is *ordinary buffered file I/O in a userspace process*, which
is exactly what CharybdeFS intercepts. Requires a Linux CI runner with FUSE (privileged
container). Not usable on the macOS dev laptop without a Linux VM.
**Concrete first test.** Mount CharybdeFS as `LEDGER_DIR`. Three scenarios: (a) EIO on
`write` for `*.ledger` at p=0.01 — assert append returns an error and the log stays
scannable; (b) EIO on `fsync` — see item 35; (c) `kill -9` on `sync`, restart, assert
the prefix invariant. Scenario (c) is exactly the ScyllaDB test they describe.
**Source.** https://github.com/scylladb/charybdefs ·
https://www.scylladb.com/2016/02/16/fault-injection-filesystem-software-testing/ ·
https://www.scylladb.com/2016/05/02/fault-injection-filesystem-cookbook/

#### 37. `dm-flakey` and `dm-error` (device-mapper fault injection)
**What it is.** Kernel device-mapper targets. `dm-error` fails everything.
**`dm-flakey`** is a linear target that cycles between `<up interval>` seconds of
normal behaviour and `<down interval>` seconds of unreliability, with feature flags:
`error_reads`, `drop_writes` (**silently ignores writes** — the nastiest and most
realistic), `error_writes`, `corrupt_bio_byte <Nth_byte> <r|w> <value> <flags>` (replace
byte N of every matching bio), and `random_read_corrupt` / `random_write_corrupt
<probability>` (probability expressed 0–1 000 000 000).
**Bugs found.** Silent write loss, torn/corrupt records, error handling on a whole
device, behaviour when the device recovers.
**Cost.** Low mechanically (`dmsetup create`), but needs **root, a loop device, and a
Linux kernel** — so: a privileged Linux CI job, not `mix test` on a laptop.
**Practical here?** **WORK (Linux CI only).** `drop_writes` is the one to reach for
first: it is the perfect model of "the write returned, fsync was off, the machine lost
power".
**Concrete first test.** Loop device → dm-flakey with `drop_writes`, up 5 s / down 2 s
→ ext4 → `LEDGER_DIR`. Run the writer for 30 s recording acknowledgements, reboot the
DB, and assert: with `LEDGER_SYNC=false`, the recovered log is a **prefix** (loss
allowed); with `LEDGER_SYNC=true`, **no acknowledged transaction is missing**. If the
second assertion fails, `sync: true` does not mean what the README says it means.
**Source.** https://docs.kernel.org/admin-guide/device-mapper/dm-flakey.html

#### 38. `dm-log-writes` (replay-to-any-flush-point)
**What it is.** A device-mapper target taking two devices: one for normal I/O, one to
**log every write**. Crucially, it logs *in order of completion once the write is no
longer in cache* — normal WRITEs are held until a `REQ_PREFLUSH`, at which point only
the writes completed at flush time are logged, *"in order to simulate the worst case
scenario with regard to power failures"*. `REQ_FUA` bypasses. You then use the
userspace `replay-log` tool to replay the device to any mark or any FUA point and check
consistency there — `dmsetup message log 0 mark <name>` inserts named marks.
**Bugs found.** "Your data is only consistent if the writes landed in the order you
assumed." This is the tool that turns "I think my write ordering is right" into a
tested claim, and it is precisely what tests **fsync semantics**.
**Cost.** Root + Linux + two block devices + the `log-writes` userspace tool. Higher
setup than dm-flakey but far more informative.
**Practical here?** **WORK (Linux CI only) — and it is the *correct* tool for the
checkpoint-vs-log ordering question.**
**Concrete first test.** Mark before the run; write 1000 transactions with a checkpoint
every 100; mark after. Replay to **every FUA/flush point** and, at each, open the
database and assert: (a) it opens without crashing, (b) `replay/1` is a prefix of the
acknowledged set, (c) the checkpoint's recorded `byte_offset` never exceeds the actual
log length. Assertion (c) is the specific bug I predict: the checkpoint is renamed
without fsync, so a crash can leave a *durable* checkpoint pointing past a *non-durable*
log tail.
**Source.** https://docs.kernel.org/admin-guide/device-mapper/log-writes.html ·
https://github.com/josefbacik/log-writes

#### 39. `libeatmydata`
**What it is.** *"An LD_PRELOAD library that disables all forms of writing data safely
to disk. fsync() becomes a NO-OP, O_SYNC is removed etc."* Purpose: fast test runs where
durability doesn't matter. The author's MySQL numbers: a test suite going from 183 s to
104 s of testcase execution.
**Bugs found.** None directly — it is a **speed** tool, and a *negative-control* tool.
**Cost.** Zero.
**Practical here?** **YES, two uses.** (1) Speed up the `sync: true` paths in the load
and property suites so you can run more sequences per minute. (2) As a **negative
control** for item 37: run the crash test under libeatmydata and assert it **does** lose
data. A durability test that passes when fsync is disabled is not testing durability.
**Concrete first test.** `eatmydata mix test --include crash` must FAIL the "no
acknowledged transaction is missing" assertion. If it passes, the assertion is vacuous.
**Source.** https://github.com/stewartsmith/libeatmydata

#### 40. `:erlang.halt/1` and SIGKILL crash harnesses
**What it is.** `:erlang.halt/0,1,2` terminates the VM **immediately without running
terminate callbacks or flushing** (unlike `System.stop/1`), which makes it the in-VM
equivalent of SIGKILL and the right primitive for a crash point *inside* a controlled
place in the code. External SIGKILL (already used in `crash_recovery_test.exs` via
`Port.open` + kill) covers "the machine went away".
Important distinction to test explicitly: `halt`/SIGKILL loses the **BEAM's** buffers,
but data already handed to the kernel via `:file.write` survives; only a **power loss or
`drop_writes`** (item 37) loses the page cache. **Two different fault levels, two
different guarantees.** A test suite that only SIGKILLs is testing the weaker one.
**Bugs found.** Recovery-path bugs, torn tails, checkpoint/log divergence, resource
leaks.
**Cost.** Zero.
**Practical here?** **YES — already partly in place; extend it.**
**Concrete first test.** Add `crash_after: n` (item 33) implemented with
`:erlang.halt(1)` inside `Store.File`, driven from an escript so the crash point is
exact and exhaustive rather than time-based. Keep the existing SIGKILL test as the
"real process" integration case (its `await_progress` fix for slow CI is worth
preserving verbatim).
**Source.** https://www.erlang.org/doc/apps/erts/erlang.html#halt/1

---

### F. Fuzzing

#### 41. How SQLite Is Tested — the reference standard
**What it is.** The most detailed public account of database testing that exists.
Numbers worth quoting because they calibrate everything else:
- **155.8 KSLOC** of library code vs **92,053.1 KSLOC** of test code — a **590:1** ratio.
- Four independent harnesses: TCL (51,445 distinct cases), **TH3** (1,055.4 KSLOC C,
  50,362 cases, ~2.4 M test instances for a full-coverage run, **248.5 M** in the
  pre-release soak), **SLT** (7.2 M queries, 1.12 GB of data, cross-checked against
  PostgreSQL/MySQL/SQL Server/Oracle — i.e. **differential testing**), and dbsqlfuzz.
- **100 % branch coverage AND 100 % MC/DC** (Modified Condition/Decision Coverage) from
  TH3. MC/DC means each condition in a compound decision must independently affect the
  outcome — `if(a>b && c!=25)` requires three cases, not two.
- **6,754 `assert()` statements** (≈3× slowdown when enabled) and **1,184
  `testcase()` macros** marking boundary values that must be exercised.
- **OOM testing**: instrumented malloc fails on allocation *n*, looping *n* upward,
  in both fail-once and fail-forever modes.
- **I/O error testing**: a custom VFS fails I/O at an advancing failure point, and after
  each failure `PRAGMA integrity_check` must pass.
- **Crash testing**: a child process crashes mid-operation while the VFS *corrupts
  unsynchronized writes*; TH3 snapshots the in-memory filesystem, advances the snapshot
  point through a loop, applies random damage, and verifies each transaction either
  committed or rolled back. Plus **compound failure tests** (an I/O error *during crash
  recovery*).
- **Mutation testing** at the assembly level: turn each branch into an unconditional
  jump or a no-op and require the suite to notice, with `/*OPTIMIZATION-IF-TRUE*/`
  comments to suppress equivalent mutants.
- Also: valgrind, memsys2, UBSan/`-ftrapv`, running the suite with optimizations
  disabled via `sqlite3_test_control()` and requiring identical output, and a ~200-item
  manual release checklist.
**Practical here?** **As a target, not a plan.** Three items are directly copyable and
cheap: **(a)** the advancing-failure-point loop for I/O errors and OOM (item 33's
exhaustive crash points are the same idea), **(b)** an integrity check after every
injected failure, **(c)** running with an optimization disabled and requiring identical
output — which for Lazy River means **running with the index/checkpoint disabled and
requiring byte-identical answers** (this is NoREC, item 21, in disguise).
**Concrete first test.** `LR_NO_CHECKPOINT=1` and `LR_NO_INDEX=1` env switches; run the
entire suite twice and diff. Any difference is an optimization bug.
**Source.** https://www.sqlite.org/testing.html

#### 42. dbsqlfuzz — mutating input *and* the on-disk file together
**What it is.** SQLite's proprietary fuzzer, built on **libFuzzer with a custom
mutator**, whose distinguishing idea is that it *"mutates both SQL input AND database
file simultaneously"*. 336 seed files, **~1 billion mutations per day** on ~16 cores.
`fuzzcheck` then replays thousands of historically "interesting" cases on every `make
test`.
**Bugs found.** Crashes and assertion failures on corrupt-but-plausible database files;
the class where a malformed on-disk structure is dereferenced.
**Cost.** Moderate. The *corpus discipline* — keep every interesting input forever and
replay it cheaply on every run — is nearly free.
**Practical here?** **WORK, in a BEAM-shaped form.** There is no libFuzzer for Elixir,
but structure-aware mutation of `<<size::32, crc::32, payload>>` records is trivial to
write by hand, and the "mutate the file *and* the request" idea maps to "corrupt the
ledger file *and* send a weird `ask` over the websocket".
**Concrete first test.** A `test/fuzz/corpus/` directory of `.ledger` files. A property
that takes a valid ledger, applies a random structure-aware mutation (flip a byte in
`size`; flip a byte in `crc`; flip a byte in `payload`; truncate mid-record; duplicate a
record; splice two ledgers), and asserts `Store.File.open/2` **never raises and never
returns a fact that was not written**. Every crash found gets its bytes committed to the
corpus and replayed on every `mix test` — that is `fuzzcheck`, for free.
**Source.** https://www.sqlite.org/testing.html

#### 43. Structure-aware fuzzing of the wire protocol and `binary_to_term`
**What it is.** Fuzzing that respects the grammar of the input so it gets past the
parser to the interesting code.
**Bugs found here specifically — and this is urgent.** `Store.File` calls
`:erlang.binary_to_term(payload)` on bytes read from disk, and the checkpoint reader
does the same. There is a **published OTP advisory** where *"a crafted External Term
Format (ETF) payload of just 7 bytes crashes the BEAM virtual machine when decoded by
`binary_to_term/1,2`"* via an unsigned underflow on `BIT_BINARY_EXT`, and the advisory
is explicit: *"This is a full VM crash — not a process-level exception. OTP supervision
trees, the `[safe]` option to `binary_to_term/2`, and all other Erlang-level error
handling cannot intercept it."* The CRC guard makes accidental triggering unlikely but
does **not** make it impossible for an attacker who can write to `LEDGER_DIR` or supply
a restored backup — and the CRC is computed over attacker-chosen bytes, so it can be
made to match.
**Cost.** Low: a StreamData generator over ETF byte strings, plus a decision about the
threat model.
**Practical here?** **YES, and it is a security finding as much as a testing one.**
**Concrete first test.** (a) Property: for random binaries, `Store.File` must never let
`binary_to_term` see unvalidated bytes — i.e. add a validation or a length/tag allowlist
before decoding, and test that a hand-built malicious record is rejected by the store,
not by the VM. (b) Fuzz `Wire.decode/1` and the websocket frame handler with random and
near-valid inputs; assert no `MatchError`/`FunctionClauseError` escapes to kill the
channel process. (c) Check whether S3-restored segments are decoded before being
authenticated — restore-then-decode is the dangerous order.
**Source.** https://github.com/erlang/otp/security/advisories/GHSA-54pw-5645-jh86

#### 44. erlfuzz, OSS-Fuzz, and "do property tests substitute for fuzzing?"
**What they are.** **erlfuzz** (WhatsApp) generates random *valid Erlang programs* to
fuzz `erlc`, the BEAM VM, dialyzer, eqWAlizer and erlfmt — **80+ bugs, 60+ in erlc
alone**. Its author's answer to "why not just use PropEr?" is the key methodological
point: PropEr *"offers tools to generate inputs to Erlang code"*, but a purpose-built
generator can encode deep domain structure (Erlang's scoping rules) that a generic
generator cannot. **OSS-Fuzz** runs continuous fuzzing for open-source projects
including SQLite and many databases, with automatic bug reports.
**Do property tests substitute for fuzzing?** Partly. Property tests give you *shrinking
and semantic oracles* (fuzzing usually only has "did it crash"); fuzzing gives you
*coverage-guided depth and volume* (a billion mutations a day) that a 100-run property
never reaches. The right split for this repo: **property tests for semantics
(items 15–21), structure-aware mutation + a permanent corpus for the parsers
(items 42–43), and no coverage-guided fuzzer** — there is no libFuzzer for the BEAM and
building one is not the best use of the time.
**Cost.** erlfuzz: not applicable (it fuzzes the toolchain, not your app — though
running it occasionally against your Elixir-compiled modules is a way to find *OTP*
bugs). OSS-Fuzz: requires a C/C++/Rust/Go/Python target; not applicable to a private
Elixir repo.
**Practical here?** **NO for the tools; YES for the corpus discipline** (item 42).
**Source.** https://github.com/WhatsApp/erlfuzz · https://google.github.io/oss-fuzz/

#### 45. Mutation testing on the BEAM (muzak, muex) — "does my suite actually assert?"
**What it is.** *"Programmatically introducing bugs to an application by mutating the
application's source code and then running that application's test suite."* Goals:
identify untested paths, unused paths, **tests that never fail**, duplicate coverage,
and slow low-value tests. The docs give the canonical example: a function with **100 %
line coverage** whose `user.role in [:admin, :owner]` survives mutation to
`[:admin, :random_atom]` — coverage said "tested", mutation said "not asserted".
**Tool status (verified, Aug 2026):** **muzak** (Devon Estes) is the open-source
version on Hex at v1.1.1; **Muzak Pro** is the paid full-featured version (~$29/mo) with
better mutation selection. Open-source muzak deliberately *"limits the number of
mutations generated in each run to 25"* and stops at the first failure per mutation.
**muex** is a newer community mutation-testing library for BEAM languages. **"mutix"
does not appear to exist** as an Elixir mutation-testing tool — the name in the brief
is likely a conflation; the real options are muzak / muzak pro / muex.
**Bugs found.** Not bugs in the code — **bugs in the tests**. Assertions that assert
nothing; branches whose behaviour nothing pins down.
**Cost.** Low to try (25 mutations is a few minutes); the open-source coverage is thin
by design.
**Practical here?** **YES, as an occasional audit, not a gate.**
**Concrete first test.** Run muzak restricted to `lib/lazy_river/store.ex` and
`lib/lazy_river/erasure.ex`. Expected survivors: the CRC comparison
(`:erlang.crc32(payload) == crc` → `true`) and the `state.since < state.every`
checkpoint threshold. If mutating the CRC check to always-true does not fail the suite,
the torn-tail tests are not testing what they claim.
**Source.** https://hexdocs.pm/muzak/what_is_mutation_testing.html · https://hex.pm/packages/muzak

#### 46. Coverage as a lie
**What it is.** Not a tool — a correction. Line and even branch coverage measure
*execution*, not *assertion*. Three sources in this document say so from different
directions: muzak's 100 %-coverage-but-broken example (item 45); SQLite's need for
**MC/DC** rather than branch coverage, plus 1,184 hand-placed `testcase()` macros
*because* coverage was insufficient (item 41); and Antithesis's framing that coverage is
*"equivalent to adding `assertSometimes(true)` to every line"*, whereas a deliberate
sometimes-assertion carries a human's judgement that this state matters (item 8).
Meanwhile AWS/ShardStore used coverage the right way: *"We apply code coverage metrics
to monitor the quality of checks over time and ensure that new functionality remains
covered"* — as a **regression detector on the harness**, not as a quality score.
**Practical here?** **YES.** Keep `mix test --cover`, but never as a target number.
**Concrete first test.** Track coverage as a *delta gate*: fail CI if coverage drops,
never assert an absolute threshold. Add ~10 `assert_sometimes`-style counters at rare
paths (torn tail, checkpoint CRC failure, keyring correction, S3 retry, formula
sandbox trap) and fail the nightly run if any counter is zero.
**Source.** https://hexdocs.pm/muzak/what_is_mutation_testing.html ·
https://antithesis.com/docs/concepts/properties_assertions/sometimes_assertions/ ·
https://www.sqlite.org/testing.html

---

### G. Formal methods

#### 47. TLA+ / PlusCal at AWS — the ROI data point
**What it is.** Since 2011 AWS engineers have used formal specification and the TLC
model checker on critical systems. The CACM paper's table is the reason anyone believes
this pays:
| System | Spec | Result |
|---|---|---|
| DynamoDB replication & group membership | **939 lines TLA+** | **3 bugs**, requiring traces of up to **35 steps** |
| S3 background data redistribution | **645 lines PlusCal** | **1 bug**, then another in the first proposed fix |
| EBS volume management | **102 lines PlusCal** | **3 bugs** |
| Fault-tolerant low-level network algorithm | **804 lines PlusCal** | **2 bugs**, plus more in proposed changes |
*"Seven Amazon teams have used TLA+, all finding value in doing so"*, and executive
management actively encourages specs for new features and significant design changes.
The 35-step trace is the headline: no human and no random test finds a 35-step
counterexample.
**Bugs found.** **Design** bugs — in the algorithm, before the code exists. Not
implementation bugs.
**Cost.** Days to learn, hours per spec once learned. PlusCal is the friendlier surface.
**Practical here?** **YES for exactly two things, and it should be scoped that tightly.**
The two candidates in Lazy River are the ones the brief guessed, and they are the right
ones:
  1. **The recovery / truncation state machine.** Variables: `log_bytes_written`,
     `log_bytes_durable`, `checkpoint_offset`, `checkpoint_durable`, `acked_txs`.
     Actions: `Append`, `Fsync`, `WriteCheckpointTmp`, `RenameCheckpoint`, `Crash`,
     `Recover`. Invariants: **(I1)** `checkpoint_offset ≤ log_bytes_durable` after any
     crash+recover; **(I2)** recovered facts are a prefix of acked facts; **(I3)** with
     `sync = TRUE`, recovered ⊇ acked. I expect **I1 to be violated by the current
     protocol** (no fsync before rename) and TLC to find it in single-digit steps.
  2. **Erasure / keyring reconciliation.** Variables: `keys`, `tombstones`,
     `key_store_generation`, `backup_generation`. Actions: `CreateSubject`,
     `EraseSubject` (destroy key + write tombstone), `Backup`, `RestoreKeyStore`,
     `Reopen` (reconcile). Invariant: **once a tombstone exists for subject S, no
     reachable state has a usable key for S** — across any interleaving of backup,
     restore and reopen. This is a legal obligation, not just a correctness one, which
     is exactly the kind of claim worth 100 lines of PlusCal.
**Concrete first test.** Write invariant (1) as ~80 lines of PlusCal, run TLC with 2–3
transactions and 1 crash. Then make the code match the spec, and keep the spec in the
repo next to `store.ex`.
**Source.** https://cacm.acm.org/research/how-amazon-web-services-uses-formal-methods/ ·
https://lamport.azurewebsites.net/tla/formal-methods-amazon.pdf

#### 48. MongoDB's TLA+ practice and conformance checking
**What it is.** MongoDB models replication, reconfiguration and transaction isolation in
TLA+ — including a machine-checked TLAPS safety proof of MongoRaftReconfig (Leader-
Completeness and StateMachineSafety), described as the first machine-checked safety
proof of a Raft-based reconfiguration protocol. The VLDB paper *"eXtreme Modelling in
Practice"* covers model-based testing for **specification–implementation conformance**,
with case studies in the replication protocol and Realm Sync's OT algorithm; they also
publish on **conformance checking** — testing that the code's observed traces are
accepted by the TLA+ spec.
**Bugs found.** Protocol design bugs, and — via conformance checking — *drift* between
a spec that was right and code that stopped matching it.
**Cost.** High for proofs; moderate for conformance checking.
**Practical here?** **The conformance idea: YES, cheaply.** You don't need TLAPS. If
item 24 (snabbkaffe) emits a trace of `{Append, Fsync, Checkpoint, Crash, Recover}`
events, you can check that trace against the PlusCal model's allowed transitions with a
few dozen lines. That closes the usual formal-methods failure mode where the spec is
correct and the code is not.
**Concrete first test.** After the recovery spec exists (item 47), have the crash test
emit its event trace and assert every observed transition is one the spec permits.
**Source.** https://www.vldb.org/pvldb/vol13/p1346-davis.pdf ·
https://www.mongodb.com/company/blog/engineering/conformance-checking-at-mongodb-testing-our-code-matches-our-tla-specs ·
https://arxiv.org/pdf/2109.11987

#### 49. Lightweight formal methods (AWS S3 ShardStore) — the model to actually copy
**What it is.** The pragmatic middle. ShardStore is **40k+ lines of Rust** with soft
updates, heavy concurrency, append-only I/O and GC, under continuous deployment. Rather
than verify it, they:
1. wrote **executable reference models in Rust, committed alongside the code**
   (*"small executable specifications (1 % of the implementation code)"* — the LSM tree's
   model *is a hash map*), reused as unit-test mocks so engineers must keep them current;
2. checked **functional correctness** by property-based testing against the model;
3. checked **crash consistency** by augmenting the model to define exactly which recent
   mutations soft updates permit to be lost, then property-testing *histories that
   include arbitrary crashes* ("drop volatile caches and reboot");
4. checked **concurrency** by **stateless model checking (shuttle)** for linearizability
   against the model;
5. tracked **coverage** to see whether the checks were decaying.
Harness total: **~12–13 % of the codebase**. Result: **16 issues prevented from reaching
production**, including subtle crash-consistency and concurrency problems, and *"18 % of
the total reference model and test harness code has been written by the engineering
team"* (later reported as 20 %, with a third of engineers writing their own models).
Checks are **"pay-as-you-go"**: run briefly on a laptop, at scale (hundreds of millions
of scenarios, on AWS Batch) before deployment.
**Bugs found.** Crash-consistency and concurrency bugs *"that evaded traditional testing
methods"*.
**Cost.** Moderate, and — critically — *maintainable by ordinary engineers*.
**Practical here?** **YES. This is the template for the whole section.** It is the
closest published analogue to Lazy River's situation: an append-only storage node, one
team, continuous change, with a need for real assurance and no appetite for Coq.
**Concrete first test.** Elevate `Store.Memory` from "the test store" to "**the
reference model**", document it as such in its moduledoc, and add the three checks:
functional (item 20), crash (`model` loses everything not fsynced; `File` must match
that allowance), and concurrency (item 17's parallel mode standing in for shuttle).
**Source.** https://jamesbornholt.com/papers/shardstore-sosp21.pdf ·
https://dl.acm.org/doi/10.1145/3477132.3483540

#### 50. Heavyweight verification: Perennial 2.0 / GoJournal (Coq + Iris)
**What it is.** *"The first verified concurrent, crash-safe journaling system"* — Go
code, proofs in Coq on top of Iris, with **crash framing** and **logically atomic crash
specifications** so application proofs can reason mostly sequentially. GoNFS on top of
it hits *"at least 90 % of the throughput of Linux's in-kernel NFS server"*.
**Cost, stated exactly.** **GoJournal: 25,797 lines of proof for 1,345 lines of Go** —
a **19:1** proof-to-code ratio. SimpleNFS: 3,749 lines of proof for 462 lines of Go
(only 44 of those lines needing explicit crash reasoning). They *did* find **one serious
concurrency bug** despite many unit tests.
**Bugs found.** All of them, within the spec — that is the point of proof.
**Practical here?** **NO.** 19:1 on a solo project, in a language with no Iris
embedding, against a spec that is still moving. The AWS blog states the general case:
traditional provable correctness needs *"up to 10x more effort than just building the
system itself"*, which is why they built the lightweight approach in item 49 instead.
**Value anyway.** Read it for what a *correct* crash specification looks like: the
"private fragment checked out, checked in at commit" framing is a good mental model for
what a Lazy River transaction promises.
**Source.** https://www.usenix.org/system/files/osdi21-chajed.pdf

#### 51. P language, Alloy, stateright — the neighbours
**What they are.** **P** — an event-driven state-machine language for asynchronous
systems, used at AWS to *"validate the correctness of new S3 features such as strong
consistency"*, with a systematic explorer; good when the design is a set of
communicating machines (which OTP designs literally are). **Alloy** — relational
first-order logic with a bounded SAT-based analyser; excellent for *structural*
invariants (does this key/tombstone/backup relation admit a bad configuration?) and much
faster to learn than TLA+. **stateright** — a Rust model checker + actor framework, the
same niche as TLA+ but with executable Rust models.
**Practical here?** **P: maybe later** if `cluster.ex` becomes real. **Alloy: a genuine
cheap option** for the keyring/tombstone/backup relation specifically — the question
"can a restore produce a state where an erased subject is readable?" is a *relational*
question, which is Alloy's home turf and would be ~40 lines. **stateright: no** (wrong
language).
**Concrete first test.** If TLA+ feels heavy, do the erasure invariant in Alloy first —
signatures `Subject`, `Key`, `Tombstone`, `Backup`, `KeyStore`; a `restore` predicate;
assert no instance has a `Key` reachable for a `Subject` with a `Tombstone`.
**Source.** https://github.com/p-org/P · https://alloytools.org/ ·
https://github.com/stateright/stateright

---

### H. Benchmark methodology

#### 52. Coordinated omission (Gil Tene)
**What it is.** Tene's term for measurement bias where *"the measuring/monitoring system
coordinates measurement with the system under test such that samples are biased."* In a
**closed-loop** load generator, the caller waits for a response before issuing the next
request — so when the server stalls, the requests that *would have* been issued during
the stall are never issued and their latency never enters the histogram. *"Most HTTP
benchmarking tools quietly hide tail latency when the server slows down... it shows up
almost exclusively in p99 and beyond."* Affected: JMeter, Grinder, LoadRunner, YCSB,
SPEC-everything.
**Bugs found.** Not code bugs — **false confidence**. Your p99 is the p99 of the
requests the stall let through.
**Cost.** Zero to understand; moderate to fix (you need an open-loop generator).
**Practical here?** **YES, and it invalidates the current `load_test.exs` numbers as a
latency claim.** Any BEAM-side loop of "send, await reply, repeat" is closed-loop by
construction.
**Concrete first test.** Keep the existing closed-loop test for **peak throughput**
(that is what it legitimately measures), and add an **open-loop** run: `wrk2 -R <rate>`
against the HTTP surface at 50/75/90/95 % of the measured peak, reporting both wrk2's
"Recorded Latency" (CO-corrected) and "Uncorrected Latency". The gap between the two
columns is the size of the lie you were previously telling.
**Source.** https://www.youtube.com/watch?v=lJ8ydIuPFeU ("How NOT to Measure Latency") ·
https://github.com/giltene/wrk2 · https://bravenewgeek.com/everything-you-know-about-latency-is-wrong/

#### 53. HdrHistogram (and `hdr_histogram_erl`)
**What it is.** A constant-space, constant-time-recording histogram with configurable
significant digits over a huge dynamic range (µs to hours), with **built-in coordinated-
omission correction**. `hdr_histogram_erl` is an OTP NIF binding usable from Elixir and
LFE, with an explicit caveat: **no internal synchronization** — a histogram reference
*"must not be written to or read from multiple processes"*; wrap it in a process, or use
per-process histograms aggregated with `hdr_histogram:add/2`.
**Bugs found.** Latency regressions that averages and even naive p99s hide; multi-modal
distributions (GC pauses, fsync spikes) that a mean flattens into nothing.
**Cost.** Very low.
**Practical here?** **YES.** `LEDGER_SYNC=true` is exactly the kind of workload with a
bimodal latency distribution that a mean destroys.
**Concrete first test.** Record every `Ledger.append` latency into a per-process HDR
histogram, aggregate on report, and publish p50/p99/p99.9/p99.99/max for `sync: true`
vs `sync: false`. Assert p99.9 stays under a documented budget — a *tail* SLO, not a
mean.
**Source.** https://github.com/HdrHistogram/hdr_histogram_erl · http://hdrhistogram.org/

#### 54. Open vs closed loop, and YCSB's critique
**What it is.** YCSB *"follows a closed system model where there is a fixed number of
users that repeatedly request the system... a new request only sent after completion of
the previous one"*, which is wrong for the workloads it claims to represent, where
*"requests arrive in an unbounded fashion even if the system stalled for a longer
period."* YCSB attempted a fix in 2015 that is widely described as *"a flawed hack"*.
The 2017 Hamburg paper *"Coordinated Omission in NoSQL Database Benchmarking"* quantified
this and introduced an open-loop alternative (NoSQLMark). Broader critique: YCSB's
workloads (single-key point ops, uniform/zipfian) resemble no real application, and its
consistency model is not exercised at all.
**Bugs found.** Wrong capacity plans; a "faster" database that is worse under real
arrival patterns.
**Cost.** Low.
**Practical here?** **YES as methodology; YCSB itself is a poor fit** (Lazy River is not
a KV store and its interesting operation — "reopen an old snapshot name and re-ask" — has
no YCSB analogue).
**Concrete first test.** Define **three** workloads that reflect what the system claims:
(W1) append-heavy single ledger, (W2) `ask` at a *cold, old* snapshot name — the caching
doctrine's central claim — and (W3) `watch` fanout with N subscribers. Drive all three
open-loop at a fixed rate. W2 is the one nobody benchmarks and the one the README's
"never invalidates" claim depends on.
**Source.** https://www.btw2017.informatik.uni-stuttgart.de/slidesandpapers/E4-11-107/paper_web.pdf ·
https://emptysqua.re/blog/ycsb-is-obsolete/ · http://psy-lob-saw.blogspot.com/2015/03/fixing-ycsb-coordinated-omission.html

#### 55. Benchee, and the benchmarketing checklist
**What it is.** **Benchee** is Elixir's microbenchmark library: warmup, ips, standard
deviation, percentiles including 99th, memory measurement, `parallel:` to simulate
load, and **save/load** so you can compare a branch against `main` or across
Erlang/Elixir versions. Note its `exclude_outliers` option — defaults to `false`, and
should **stay** false for a database, because the outliers *are* the tail you care
about; excluding them is coordinated omission by another route.
**The benchmarketing checklist** (assembled from the sources above): state the arrival
model (open/closed); publish the full distribution, not the mean; publish the load
generator's own saturation point; run long enough to include GC and fsync; test at
several rates below saturation rather than only at peak; keep the durability setting
honest (`sync: true` and `sync: false` are different products); use a negative control
(item 39); and re-run on the same hardware for comparisons.
**Practical here?** **YES.** Benchee for function-level work (`Fact` encoding,
`Snapshot.find`, formula evaluation); wrk2 + HdrHistogram for end-to-end latency.
**Concrete first test.** Benchee comparison of `Snapshot.find/2` at 10³, 10⁵ and 10⁶
facts, plus `Store.File.append/2` at increasing log length — the latter will expose the
`state.facts ++ facts` O(n²) behaviour as a measurement rather than a suspicion.
**Source.** https://github.com/bencheeorg/benchee

---

### I. Chaos engineering, framed properly

#### 56. The four principles (Netflix / principlesofchaos.org)
**What it is.** *"Chaos Engineering is the discipline of experimenting on a system in
order to build confidence in the system's capability to withstand turbulent conditions
in production."* Four principles: **(1)** build a hypothesis around **steady-state
behaviour** — a measurable output at the system boundary (Netflix's is SPS, stream
starts per second), not an internal metric; **(2)** **vary real-world events**,
prioritized by impact or frequency; **(3)** **run experiments in production**, with a
control group and an experimental group; **(4)** **automate experiments to run
continuously**, because confidence in past results decays as the system changes.
The discipline is *not* "break things randomly": it is a hypothesis, a control group, a
variable, and a comparison.
**Bugs found.** Improper fallbacks, retry storms from badly tuned timeouts, cascading
failures from single points of failure.
**Cost.** Low technically, high organizationally (production experiments need a blast
radius plan).
**Practical here?** **Principles 1, 2, 4: YES. Principle 3: not yet** — one node, one
deployment on UpCloud, no control group to compare against. Adopt production chaos when
there is more than one instance to lose.
**Concrete first test.** Define the steady state explicitly in `Vitals`: **successful
`ask`s per second and p99 `ask` latency**. Then hypothesise "killing the `Backup`
process has no effect on steady state", run it, and check. Repeat for the KMS being
unreachable, the disk being full, and the formula sandbox trapping.
**Source.** https://principlesofchaos.org/ ·
https://netflixtechblog.com/chaos-engineering-upgraded-878d341f15fa

#### 57. Disk fault injection as the database-specific chaos discipline
**What it is.** The specialization of chaos engineering that matters for storage: not
"kill a server" but "make the disk lie". Sources converge on the same taxonomy —
**latent sector errors, torn writes, misdirected writes, bit corruption, silent write
loss, ENOSPC, EIO on read/write/fsync, and latency spikes**. Jepsen's TigerBeetle
report is the strongest recent evidence that granularity matters: single-**bit** flips
found a padding bug that whole-**sector** corruption masked, and "helical" corruption
(different offsets per replica) found bugs uniform corruption did not.
**Bugs found.** Every failure mode a real disk has and no test suite simulates.
**Cost.** Depends on the layer: `Store.Faulty` (free), CharybdeFS (moderate), dm-flakey
/ dm-log-writes (Linux CI).
**Practical here?** **YES — and it should be the centre of the durability strategy**,
because Lazy River is a single-node database whose entire value proposition is that the
log is true.
**Concrete first test.** A `just chaos-disk` recipe running the matrix: {bitflip in
log, bitflip in checkpoint, truncate log, truncate checkpoint, ENOSPC on append, EIO on
fsync, silent write loss, restore-old-checkpoint-over-new-log} × {`sync: true`,
`sync: false`} × {checkpoint on, off}. 32 cells. Each asserts the prefix invariant and
that the failure is *reported*, never silent.
**Source.** https://jepsen.io/analyses/tigerbeetle-0.16.11 ·
https://www.scylladb.com/2016/02/16/fault-injection-filesystem-software-testing/

---

### Appendix: what the Jepsen TigerBeetle report teaches about testing your own tests

Worth its own note because it is the most recent (and most humbling) data point in this
whole document. TigerBeetle has arguably the best testing story of any young database —
DST, 10 VOPRs running 24/7, fuzzers, 6,000+ production assertions, 100-billion-transaction
scale tests. Jepsen still found **2 safety issues, 7 crashes**, and multiple availability
problems, and diagnosed *why* the internal suite missed them:

- **The fuzzers didn't exercise the code path.** *"Two fuzzers, `fuzz_lsm_tree` and
  `fuzz_lsm_forest`, did not perform joins"*, and the query fuzzer generated objects that
  *"happened to appear consecutively in each index—the 'zig-zag' part of the merge join
  was never executed."* A generator that never reaches the interesting state is a test
  that does not exist. (This is precisely what sometimes-assertions, item 8/46, detect.)
- **The fault granularity was wrong.** Internal tests *"corrupted entire sectors, rather
  than single bits"*, so checksum failure triggered repair before the assertion under
  test could fire.
- **The hardest area was the least tested.** Upgrades — multi-version, rolling —
  produced three of the seven crashes.

The transferable lesson for Lazy River: **instrument the rare paths and fail the build if
the generators never reach them**, corrupt at **bit** granularity as well as record
granularity, and treat **format/version migration of the ledger file** as the highest-risk
untested area the moment a second on-disk format version exists.

**Source.** https://jepsen.io/analyses/tigerbeetle-0.16.11

---


## Section 7 — Real-world incident postmortems, as testable claims

Every incident below is sourced to a URL with a date, vendor's own writeup where
one exists. Grouped by **root-cause family**, because the family is what
generalises: the trigger never repeats, the defect class always does.

Applicability throughout is to **Lazy River** — a single-node immutable
append-only fact-log in Elixir (`lib/lazy_river/`) with `Store.File` segments,
S3 backup (`Backup`, `Backup.Target.S3`), envelope encryption via Cloud KMS
(`Keyring`, `Keyring.GCP`), erasure-by-key-destruction (`Erasure`), sandboxed
pure WASM formulas (`Formula.Sandbox`), scheduled jobs (`Job.Runner`), and an
HTTP/websocket surface (`Surface.*`) where authorization is which ledgers you
may name (`Authority`).

Each entry ends with **ASSERT:** — a falsifiable claim phrased so it can be
dropped into a test suite, and **HERE:** — what it means for this system.

---

### A. Durability — acknowledged and then gone

The largest family, and the one a fact-log cannot afford. Every member of it
is the same defect wearing different clothes: **the acknowledgement was issued
by something other than the thing that made the data durable.**

> The founding member of this family, **PostgreSQL fsyncgate (2018)**, is written
> up as **H1** in the storage section, because its defect lives in the kernel
> contract rather than in Postgres. Read it first; it is the one that most
> directly threatens `LEDGER_SYNC`.

#### A2. Call me maybe: Redis 2.6.13 — 56% of acknowledged writes discarded
- **Vendor/analyst:** Jepsen (Kyle Kingsbury) · **Date:** 2013-05-18
- **URL:** https://aphyr.com/posts/283-call-me-maybe-redis

**What happened.** Against a 5-node Redis with Sentinel, a partition was
induced. Redis reported 1,998 of 2,000 writes successful; 872 were present at
the end. Sentinel promoted a replica while the old primary was still live and
still accepting writes, so both sides took writes independently; on heal the
demoted primary discarded its divergent history wholesale.

**Root cause.** Two independent defects. Replication is asynchronous and the
primary acknowledges *before* replicating, so anything in flight at partition
time dies on demotion. And failover is decided by a failure detector (Sentinel)
that is not the same mechanism that orders writes, so there is no epoch telling
the deposed primary to stop acknowledging. Reconciliation is truncation, not
merge — there is no hook to recover the divergent suffix.

**ASSERT:** *A write that returned success is present in the log after an
uncoordinated restart, always — the success return must be issued by the code
path that made the bytes durable, never by a path that scheduled durability.*

**HERE:** `Ledger.write/2` must not reply `{:ok, name}` until `Store.append/2`
has returned, and under `LEDGER_SYNC=true` not until the fsync returned. The
`Store` behaviour docstring already says "Returning means recorded" — that is a
claim, so it needs a test that SIGKILLs mid-write and replays. `mix test
--include crash` is the right hook; the assertion is that every name ever
handed to a caller still resolves after the kill.

#### A3. Call me maybe: MongoDB 2.4.1 — rollback that threw the rollback away
- **Vendor/analyst:** Jepsen · **Date:** 2013-05-18
- **URL:** https://aphyr.com/posts/284-call-me-maybe-mongodb

**What happened.** Partition the primary from the majority; the majority elects
a new primary; the old primary keeps acknowledging. On heal, every write past
the divergence point is rolled back. Loss by write concern: unacknowledged
41.8% (2,381/5,700), `SAFE` 37.4%, `REPLICAS_SAFE` (w=2) 33.8%, `MAJORITY`
0.02%.

**Root cause.** `w=2` is not a majority of 5, so a new primary can be elected
without having seen an acknowledged write. Compounding it: rollback files were
meant to preserve the reverted oplog suffix, but did so "in 1 out of 5 runs or
so. Mostly, it just throws those writes away entirely."

**ASSERT:** *Any path that discards previously-acknowledged data writes the
discarded data somewhere durable first, and that path is exercised in a test —
a recovery file that is only written sometimes is not a recovery file.*

**HERE:** The analogue is `Backup`'s "copy stops at the last complete record"
rule and the torn-tail truncation in `Store.File` replay. Truncating a torn
tail is correct; truncating it *silently* is the MongoDB defect. Test: after a
torn write, replay emits a fact (or a `Vitals` counter) recording exactly how
many bytes were discarded, and that number is non-zero exactly when the tail
was torn.

#### A4. Jepsen: MongoDB 3.4.0-rc3 — 417 of 932 acknowledged writes lost
- **Vendor/analyst:** Jepsen · **Date:** 2017-02-07
- **URL:** https://jepsen.io/analyses/mongodb-3-4-0-rc3

**What happened.** Under the new v1 replication protocol, 417 of 932
majority-acknowledged inserts were lost. Three defects: on acknowledging a
write the primary checked only *that it was still a primary*, not that the
**term** had not changed (SERVER-27053); heartbeat handling let a stale primary
advance its commit point; secondaries compared raw timestamps rather than terms
and would replicate from an older-term node (SERVER-27149).

**Root cause.** Not the protocol — the *residue*. "Some code … wasn't updated
to reason using v1's logical terms." A new correctness mechanism was introduced
while old code kept validating against the superseded one.

**ASSERT:** *After introducing a new version/epoch/term identifier, no code
path validates against the predecessor. Grep-level assertion: the old
identifier has zero remaining readers, and a test constructs an object carrying
a stale identifier and asserts every entry point rejects it.*

**HERE:** A snapshot name is `%{ledger_ref => tx}` and a caller "can write one
by hand" (per `Snapshot`'s own doc). Every place that accepts a name must
validate the *whole* name — ledger membership AND the transaction number —
rather than checking one and trusting the other. Test: hand `Snapshot.reopen/1`
a name with a tx beyond the ledger's current tx, and one with a tx belonging to
a different ledger, and assert both refuse.

#### A5. Jepsen: MongoDB 4.2.6 — retryable writes duplicated committed effects
- **Vendor/analyst:** Jepsen · **Date:** 2020-05-15
- **URL:** https://jepsen.io/analyses/mongodb-4.2.6

**What happened.** "Even at the strongest levels of read and write concern, it
failed to preserve snapshot isolation." Under partition, transaction effects
were **duplicated** — a transaction appended `6` exactly once and a later read
returned `[2 4 1 6 8 7 6]`. Worse, **retrocausal** transactions appeared: a
transaction observed its own future write. Roughly 10% of transactions showed
anomalies *with no faults injected at all* (1,461 of 13,914 in one run).

**Root cause.** SERVER-48307 — a defect in the **automatic transaction retry**
mechanism. MongoDB retried a transaction it believed had failed when the
original had in fact committed, re-applying the effects. Non-idempotent retry
of a committed transaction. `retryWrites` could not be disabled for
transactions, so applications could not opt out. Secondary root cause:
transactions silently downgraded to `local`/`w:1`, discarding
database-and-collection-level concern settings.

**ASSERT:** *Retrying a write that already committed produces no second effect.
A test issues the same write twice with the same idempotency token across a
simulated timeout and asserts the log contains exactly one transaction.*
**And:** *no configuration is silently downgraded — if a caller's requested
durability level cannot be honoured on a path, that path refuses rather than
proceeding at a weaker level.*

**HERE:** This is the single most directly applicable Jepsen finding. Two
places. (1) `Job.Runner` "holds what is still in flight, because a slow job
must not be run twice" — that is exactly the invariant SERVER-48307 broke, and
it must survive a runner restart, not just a slow tick. Test: kill the runner
mid-job and assert the job's effect appears once. (2) A websocket client that
reconnects and replays a `write` must not append twice — the write needs a
client-supplied idempotency key checked against the log, and the test is
"reconnect and resend, assert tx advanced by one, not two."

#### A6. Jepsen: Elasticsearch 1.5.0 — acknowledged before the translog flush
- **Vendor/analyst:** Jepsen · **Date:** 2015-04-27
- **URL:** https://aphyr.com/posts/323-call-me-maybe-elasticsearch-1-5-0

**What happened.** Four loss modes a year after the 1.1.0 report and a rewrite:
intersecting partitions lost 2.5%; an isolated primary lost 22%; process pauses
(GC/swap/IO) lost up to 9.3%; and plain **crashes** lost ~10% (23/226).

**Root cause (the crash mode).** "Write acknowledgement takes place *before*
the transaction is flushed to disk" — the translog fsyncs on a 5-second timer
that has no relationship to when the client was told the write succeeded. The
other three modes share a root cause: membership is decided by a failure
detector (ZenDisco) while writes are never threaded through consensus, so a
paused or superseded primary has no term telling it to stop acknowledging.

**ASSERT:** *There exists no time window in which a write has been
acknowledged and a `kill -9` would lose it. Property test: for a random
interleaving of writes and kills, the set of acknowledged writes is a subset of
the set of replayed writes.*

**HERE:** `LEDGER_SYNC` is precisely this knob and the README already tells the
truth about it ("durable and slow"). The test must be run in **both** settings
and must assert *different* things: with `LEDGER_SYNC=true`, acknowledged ⊆
replayed after SIGKILL of the whole VM; with it false, acknowledged ⊆ replayed
after SIGKILL of the *process* but not necessarily after power loss. Writing
down which guarantee each setting buys is the point — Elasticsearch's defect
was that nobody had.

#### A7. Call me maybe: RabbitMQ — 35% loss plus duplicate delivery
- **Vendor/analyst:** Jepsen · **Date:** 2014-06-06 · **Version:** 3.3.0
- **URL:** https://aphyr.com/posts/315-call-me-maybe-rabbitmq

**What happened.** Mirrored queues under partition: 3,747 enqueues, 2,358
dequeued, **24 duplicate deliveries and 1,312 messages permanently lost**.
Neither partition mode helps — `pause_minority` "does not shut down fast enough
in any released version," `autoheal` lets both sides run then picks a winner
arbitrarily. "When a RabbitMQ node rejoins the cluster, it *wipes* its local
state and adopts whatever the current primary node thinks the queue should
contain."

**Root cause.** Mirrored queues have no consensus; the promoted mirror becomes
truth by fiat. Separately, the ack/nack "lock" is unsound because "RabbitMQ
can't tell the difference between a client that's crashed, and one that's
simply unresponsive" — on a suspected failure it redelivers while the original
consumer still holds the message. Jepsen: "we used Knossos and Jepsen to prove
the obvious: RabbitMQ is not a lock service."

**ASSERT:** *A lease/lock whose holder cannot be distinguished from a slow
holder is not mutual exclusion; any exclusion the system claims is tested by
inducing a pause in the holder longer than the timeout and asserting either
that no second holder is admitted, or that the second holder carries a fencing
token the resource rejects when stale.*

**HERE:** `Job.Runner`'s in-flight set. A job that hangs past its cadence must
not be started again by the next tick, and — the harder case — must not be
started twice by a runner that restarted while it hung. Test: register a job
that blocks, restart the runner, assert the job's side effect happened once.
Because jobs "are the only thing that reaches the outside world," a duplicate
job is the only way this system can double-charge someone.

#### A8. Jepsen: Redis-Raft 1b3fbf6 — 21 issues including total loss on failover
- **Vendor/analyst:** Jepsen · **Date:** 2020-06-23
- **URL:** https://jepsen.io/analyses/redis-raft-1b3fbf6

**What happened.** Among 21 issues: **#14** new leaders came up with completely
empty state after any failover, root-caused to a **missing re-entrancy check**
in command interception that wrapped commands repeatedly through the consensus
layer (the same defect produced #13, an infinite log-append loop). **#19**
stale reads in a *healthy, fault-free* cluster because the Raft library never
issued the **no-op entry on leader election**. **#52** "nodes could delete or
duplicate operations, even operations well in the past which had been superceded
by dozens of committed writes." **#26** the follower-proxy returned one client's
reply to a *different* client.

**Root cause (of the family).** A correct consensus algorithm implemented by a
library that omitted its obligations, with no test asserting the obligations.

**ASSERT:** *History is append-only in the strong sense: for any two snapshots
taken at times t₁ < t₂, the log prefix at t₁ is a byte-identical prefix of the
log at t₂. A test takes periodic hashes of the log prefix and asserts they never
change.*

**HERE:** This is the core doctrine of the system and therefore the test that
must exist. "An answer at a named snapshot is the same answer forever" is a
claim; assert it by capturing `{name, question} -> answer` pairs continuously
during a fault-injection run (writes, restarts, backups, checkpoint rebuilds,
erasures) and re-asking every pair at the end. Only `:erased` may differ, and
only for erased subjects.

---

### B. Isolation and visibility — the read that saw the wrong world

#### B1. Call me maybe: etcd and Consul — "consistent read" that went backwards
- **Vendor/analyst:** Jepsen · **Date:** 2014-06-09 · **Version:** etcd 0.4.1
- **URL:** https://aphyr.com/posts/316-call-me-maybe-etcd-and-consul

**What happened.** Both systems' documented "consistent read" was not
linearizable: "an etcd 'consistent read' can read a value from index 5, then
index 4, then index 6" — reads went backwards in time across a CAS.

**Root cause.** A consistent read "simply return[s] the local state if the
current node considers itself a leader," with no quorum round-trip. Across a
partition two nodes both believe they lead. HashiCorp's first fix was to shorten
the leader timeout from 1s to 300ms, which has no theoretical guarantee — a
timing change presented as a correctness fix.

**ASSERT:** *Reads are monotonic per client: the sequence of transaction
numbers a single client observes never decreases. A test drives reads
concurrently with writes and asserts monotonicity of the observed tx.*

**HERE:** Single-node makes the distributed version moot, but the *shape*
survives: `watch` delivers answers "as the name advances." A subscription that
delivers tx 7, then tx 6, then tx 8 — because of a re-subscribe, a checkpoint
rebuild, or a supervisor restart of `Subscription` — is this bug exactly. Test:
a watcher receives strictly increasing tx across a forced crash-and-resubscribe
of the channel.

#### B2. Jepsen: etcd 3.4.3 — the lock that two clients could hold
- **Vendor/analyst:** Jepsen · **Date:** 2020-01-30
- **URL:** https://jepsen.io/analyses/etcd-3.4.3

**What happened.** The KV core was clean — strict serializable, watches in
order, under partitions and clock skew. The **lock service** was not: "multiple
clients may hold the same etcd lock simultaneously, even in healthy clusters"
(#11456). A client blocked waiting on a lock does not re-check lease validity
*after* acquiring it, so if its lease expired while queued it returns holding a
lock etcd considers free. Separately (#11496), `watch` from revision 0 silently
starts at "whatever revision the server has now, plus one" — not from the
beginning — so a watcher silently misses history.

**Root cause.** A validity check performed before a wait and not repeated
after it. And a default parameter whose documented meaning ("from the start")
differed from its implemented meaning ("from now").

**ASSERT:** *Any authorization or validity check performed before a blocking
operation is repeated after it returns.* **And:** *a subscription started "from
the beginning" delivers the first fact ever written, not the first fact written
after subscribing — asserted by writing N facts, subscribing from zero, and
counting N.*

**HERE:** Both bite. (1) `Surface.WatchChannel` checks `Authority.may_name?`
at join; a long-lived websocket must re-check after a revoke, because grants
are facts and "grant → revoke → grant works." Test: join, revoke, write, assert
the socket stops receiving. (2) `watch` from a caller-supplied name must
deliver everything from that name forward inclusive — test by writing, then
watching from tx 0, and asserting the count.

#### B3. Jepsen: MongoDB 2.6.7 stale reads — write concern is not read concern
- **Vendor/analyst:** Jepsen · **Date:** 2015-04-20
- **URL:** https://aphyr.com/posts/322-call-me-maybe-mongodb-stale-reads

**What happened.** During a partition there are transiently two primaries. The
minority primary applies writes locally before any secondary confirms, so
clients read values that will later be rolled back (**dirty read**) and miss
values committed on the majority side (**stale read**). `readPreference:
primary` does not help; the client cannot tell it is talking to the doomed one.

**Root cause.** Write concern is a *durability* knob, not a *visibility* one.
"Majority write concern … does not solve the problem of stale reads." MongoDB
2.6 had no `readConcern` at all — the read path had no safety parameter to set.

**ASSERT:** *No read observes a fact that a subsequent read cannot observe. A
test records every answer seen and re-asks at the end; any answer that
disappeared is a dirty read.*

**HERE:** The system's defence is structural — an answer is computed at a named
snapshot, so there is no "current" to be dirty. The test is therefore a
regression fence around that structure: assert no read path anywhere consults
`Ledger.tx/1` at answer time rather than the snapshot's pinned tx. A formula
that reads live ledger state instead of the snapshot reintroduces MongoDB 2.6
exactly.

#### B4. Jepsen: PostgreSQL 12.3 — G2-item under SERIALIZABLE, no faults
- **Vendor/analyst:** Jepsen · **Date:** 2020-06-12
- **URL:** https://jepsen.io/analyses/postgresql-12.3

**What happened.** In healthy single-node clusters with no fault injection,
`serializable` admitted **G2-item** anti-dependency cycles. "The conflict
detection mechanism could, given three concurrent transactions, incorrectly
identify an updating transaction's transaction ID … rather than using the
transaction ID which originally created the tuple." SSI's dangerous-structure
detection compared against the wrong xid and missed a real rw-antidependency.

**Root cause.** Wrong-version identity in conflict detection. "This code has
gone essentially untouched since the introduction of serializable snapshot
isolation in 2011" — live and undetected in every version 9.5 through 13.

**ASSERT:** *The strongest isolation level the system advertises is verified by
a cycle-detecting checker (Elle or equivalent) on a randomized workload with no
faults injected — because the most expensive isolation bugs need no fault to
appear.*

**HERE:** The lesson is the methodology, not the mechanism: **run the
consistency checker on the happy path.** A property test that only injects
crashes will miss the class of bug that needs no crash. Lazy River's version:
randomized concurrent writes to overlapping ledgers, snapshots opened
throughout, and an assertion that every snapshot's answer equals a
recomputed-from-scratch replay of the ledger prefix it names.

#### B5. Jepsen: Dgraph 1.1.1 — read skew written back, permanently
- **Vendor/analyst:** Jepsen · **Date:** 2020-04-30
- **URL:** https://jepsen.io/analyses/dgraph-1.1.1

**What happened.** After a tablet migration (a normal, non-fault operation),
the receiving shard served transactions whose start timestamp predated the move
— data it did not own at that timestamp (#4534). The resulting read skew got
**written back**: bank account totals went from $100 to $98 and stayed there
(#4543). A separate defect let parts of a split posting list be accessed
individually, losing windows of up to **11,544 acknowledged inserts** (#4538).

**Root cause.** A routine internal maintenance operation was not covered by the
transactional guarantees the rest of the system provided. The migration was
"infrequent but normal" — and untested against the consistency checker.

**ASSERT:** *Every internal maintenance operation — compaction, checkpointing,
backup, key rotation, segment rollover — runs concurrently with the consistency
checker in at least one test, and no answer changes across it.*

**HERE:** The highest-value structural test for this system. `Store.File`
segment rollover, checkpoint writing, `Backup` runs, and `Keyring` rotation all
touch data while readers are live. Test: hold a set of `{name, question} ->
answer` pairs, force each maintenance operation, re-ask. Nothing may move.
Dgraph's $100→$98 is what "derived data written back from a skewed read" looks
like, and formulas that write facts are the place it could happen here.

#### B6. Jepsen: FaunaDB 2.5.4 — pagination cursor without a timestamp
- **Vendor/analyst:** Jepsen · **Date:** 2019-03-05
- **URL:** https://jepsen.io/analyses/faunadb-2.5.4

**What happened.** Among 19 issues: index entries **overwrote** their timestamp
rather than retaining a version, so a read landing between old and new
timestamps "would skip that entry, and instead observe some older state." And
"pagination cursors only encode the value that the next page should begin
after, not the time" — so a paginated scan could observe 81 but not 80 though
they were inserted together.

**Root cause.** A cursor that encodes *position* but not *time* silently
re-points at a moving target between pages.

**ASSERT:** *Every cursor, continuation token, or resume point encodes the
snapshot it was taken at, and resuming with it yields the same result as
reading the whole thing in one call.*

**HERE:** Very direct. Any paged `ask` over a large answer, and any `watch`
resume-from-token, must carry the snapshot name — not merely an offset. Test:
page through an answer while writing concurrently, and assert the concatenated
pages equal a single unpaged read at the same name.

#### B7. Call me maybe: ZooKeeper — the control case
- **Vendor/analyst:** Jepsen · **Date:** 2013-09-23 · **Version:** 3.4.5
- **URL:** https://aphyr.com/posts/291-call-me-maybe-zookeeper

**What happened.** **No data loss.** ZooKeeper refused writes on the minority
side rather than accepting and later discarding them. Availability tracked the
majority share; linearizability held across partition and leader election.

**Root cause of the *success*.** "Writes must be durably written to a disk log
on a majority of nodes before they are acknowledged." Acknowledgement is gated
on quorum durability. (Caveat added 2019: `sync` + read is *not* guaranteed
linearizable, because `sync` is not itself ordered through the quorum.)

**ASSERT:** *When the system cannot guarantee a write's durability it returns
an error, and the error names the repair. A test partitions/degrades the
durable path (fill the disk, revoke the KMS key, break the backup target) and
asserts writes fail loudly rather than succeeding weakly.*

**HERE:** The house rule ("errors are data with the repair attached") and the
ZooKeeper result are the same rule. Test: `LEDGER_DIR` full, KMS unreachable,
backup bucket 403 — for each, assert the refusal is a structured error with a
`repair` field and that no fact was recorded.

---

*(continued below — remaining families being filled in)*

---

### C. Tenancy and isolation — the request that answered as someone else

This family matters more here than anywhere else, because Lazy River's entire
authorization model is one predicate: **which ledgers may this caller name.**
Every incident below is a case where that kind of check was correct and was
nevertheless bypassed, because the identity travelled separately from the data.

#### C1. OpenAI ChatGPT — chat titles and payment data shown to the wrong user
- **Vendor:** OpenAI · **Date:** 2023-03-20 (writeup 2023-03-24)
- **URL:** https://openai.com/index/march-20-chatgpt-outage/
- **Corroborating:** https://github.com/redis/redis-py/issues/2665 (CVE-2023-28859)

**What happened.** Users saw other active users' conversation titles, and in a
nine-hour window ~**1.2% of ChatGPT Plus subscribers** who were active could see
another user's name, email, payment address, card type, last four digits and
expiry. Some subscription-confirmation emails went to the wrong users.

**Root cause.** A defect in `redis-py`'s asyncio client. A connection is modelled
as an incoming and an outgoing queue; "if a request is canceled after the
request is pushed onto the incoming queue, but before the response popped from
the outgoing queue… the connection thus becomes corrupted and the next response
that's dequeued for an unrelated request can receive data left behind in the
connection." The corrupted connection was returned to the **shared pool** rather
than discarded. Usually the stale bytes fail to parse; occasionally they parse
as the expected type and another tenant's value is returned as valid. The
trigger was a server change that spiked cancellations. OpenAI's own added
defence: "redundant checks to ensure the data returned by our Redis cache
matches the requesting user."

**ASSERT:** *Every value returned from a shared resource (cache, pool, ETS
table, connection) carries the identity it was fetched for, and the caller
asserts that identity matches before using it — a test injects a
wrong-tenant value into the shared resource and asserts the request fails
rather than returning it.* **And:** *cancelling a request in flight never
leaves a reusable resource in a state a later request can consume.*

**HERE:** The most important single lesson in this document for this system.
Two exposures. (1) `Keyring`'s unwrapped-data-key cache is keyed by subject; a
cache that returns subject B's key for subject A is a silent cross-tenant
decrypt, and the test is to assert the cached entry's subject matches the fact's
subject *at use time*, not just at insert time. (2) `Surface.WatchChannel` and
the HTTP controller run per-connection state; a client that disconnects
mid-`ask` must not leave a partially-consumed response that the next request on
that process can read. Test: cancel an in-flight `ask` (close the socket
mid-answer), issue a second `ask` as a *different* caller on a recycled process,
and assert the second answer contains nothing from the first.

#### C2. GitHub — a session cookie handed to the wrong user
- **Vendor:** GitHub · **Date:** bug live 2021-02-08 → 2021-03-05; writeups 2021-03-08 and 2021-03-18
- **URLs:** https://github.blog/news-insights/company-news/github-security-update-a-bug-related-to-handling-of-authenticated-sessions/ · https://github.blog/security/vulnerability-research/how-we-found-and-fixed-a-rare-race-condition-in-our-session-handling/

**What happened.** A user browsing GitHub.com was suddenly authenticated as a
different user. Fewer than 0.001% of authenticated sessions were affected;
GitHub invalidated every session created before 2021-03-08 12:03 UTC.

**Root cause.** The cleanest published example of the shared-identifier class.
Unicorn does not allocate a new Rack `env` per request — it allocates one Hash
and calls `Hash#clear` between requests. A new background thread for exception
reporting resolved user context *lazily*. So: anonymous Request #1 raises; its
exception context is processed later on the background thread; a callback reads
the session cookie **out of the shared `env`**, which by then holds Request #2's
cookie; the controller completes authentication by writing a `Set-Cookie` into
the cookie jar in the `env`, which by then belongs to Request #3. Request #3's
user received Request #2's session. The response *body* was always correct —
only the header was wrong, which is why nothing detected it.

**ASSERT:** *No mutable per-request state is shared between requests. A test
runs concurrent requests from distinct principals through the same process and
asserts that no response carries any identifier belonging to another
principal — including in headers, not only in bodies.*

**HERE:** Elixir's per-process isolation makes the Unicorn form impossible, but
the *shape* is reachable: any long-lived GenServer that caches "the current
caller" between calls, or a `Plug` that stashes an authority decision in a
module attribute / persistent_term / ETS row keyed by something that is not the
caller fingerprint. `Authority` keys grants by `sha256` of the presented token —
the test is that every decision cached anywhere is keyed by that fingerprint and
nothing coarser (not by ledger, not by connection, not by pid).

#### C3. Cloudbleed — an off-by-one that emitted other tenants' memory
- **Vendor:** Cloudflare · **Date:** disclosed 2017-02-23 (live 2016-09-22 → 2017-02-18)
- **URL:** https://blog.cloudflare.com/incident-report-on-memory-leak-caused-by-cloudflare-parser-bug/

**What happened.** Cloudflare's Ragel-generated HTML rewriter ran past the end
of its buffer on malformed HTML (an unterminated attribute at end of page) and
emitted adjacent process heap — which on a shared edge box contains other
customers' in-flight requests — into the response body. Leaked bytes included
cookies, auth tokens, POST bodies and internal keys. Because they were served as
ordinary page content, **search engines cached them**; ~770 cached URIs across
161 domains had to be purged.

**Root cause.** The generated C checked the buffer end with equality, not a
bound: `if ( ++p == pe ) goto _test_eof;`. If `p` had already passed `pe`
(because an error path omitted the `fhold`/`p--`), the test never fires and the
pointer keeps walking. Latent for years; three feature rollouts changed buffer
handling enough to reach it.

**ASSERT:** *Every bounds check is `>=`, never `==`. Property test: feed the
parser truncated and malformed inputs at every byte offset and assert it never
reads outside the supplied slice and never emits bytes not derived from it.*

**HERE:** `Store.File`'s segment replay parses length-prefixed records from a
file that may have a torn tail, and `Wire` decodes caller-supplied frames. Both
must be fuzzed by truncation at every offset. In a fact-log the Cloudbleed
consequence is specific and severe: a length field read as larger than the
record would emit the *neighbouring* fact — which may belong to another ledger —
as part of this one's answer. That is a cross-tenant leak produced purely by a
parser, with no authorization bug anywhere.

#### C4. Steam — authenticated pages served from a shared cache
- **Vendor:** Valve · **Date:** incident 2015-12-25, statement 2015-12-30
- **URL:** https://store.steampowered.com/news/19852/

**What happened.** Under a DoS pushing traffic to 2000% of Steam Sale average,
caching rules were deployed to shed load. "A second caching configuration was
deployed that incorrectly cached web traffic for authenticated users." Logged-in
users then received Store pages generated for other users. Requests for about
**34,000 users** containing billing address, last four of the Steam Guard phone
number, purchase history, last two digits of the credit card and email address
may have been served to others.

**Root cause.** The cache key omitted the identity dimension: "cacheable" was a
property of the *route* rather than of the *response's authorization scope*, and
an emergency config change could set it with no invariant refusing.

**ASSERT:** *No cache key is accepted unless it includes the principal, or the
value is provably principal-independent. A test asserts that for every cache in
the system, two different principals issuing the identical request never share
an entry.*

**HERE:** Lazy River's caching story is unusually strong and unusually
dangerous. The README says a client "caches on `{name, question}` and never
invalidates" — which is sound precisely because a snapshot name enumerates its
ledgers, so the name *is* the authorization scope. That makes the invariant
testable and worth pinning: **assert that no cache anywhere — client-side,
`Formula.Engine`'s memo, or an HTTP cache header — is keyed by anything that
omits the ledger set.** If a shortening or hashing of the name ever loses a
ledger, Steam's incident happens here with facts instead of billing addresses.

#### C5. Monzo — PINs in engineer-readable logs
- **Vendor:** Monzo · **Date:** discovered 2019-08-02, published 2019-08-05
- **URL:** https://monzo.com/blog/2019/08/05/weve-fixed-an-issue-storing-some-customers-pins

**What happened.** Monzo stores card PINs in a tightly access-controlled
enclave. It found it had *also* been recording some customers' PINs into
ordinary internal encrypted log files readable by engineers — ~480,000
customers, ~110 engineers with access, via two app flows ("remind me of my card
number", "cancel a standing order"), for up to six months.

**Root cause.** The secret crossed a trust boundary through a code path whose
logging was not secret-aware. Access control lived on the *primary store*, not
on the *data*, so a second copy landed in a system with a completely different
and far broader authorization model.

**ASSERT:** *No secret-bearing value is representable in a log. Enforced
structurally: key material and plaintext answers implement an `Inspect` that
redacts, and a test asserts `inspect/1` and `Logger` output of every such struct
contains none of the underlying bytes.*

**HERE:** Directly actionable. `Keyring` handles data keys and KEKs; `Fact`
carries sealed answers and a wrapped key. Any of these appearing in a crash
report, a `Vitals` metric label, a `Surface.ErrorJSON` body, or a supervisor
restart log is Monzo's incident. Elixir makes the fix cheap — `@derive
{Inspect, only: []}` — and the test is a property: for a randomly generated key
and fact, `inspect/1` output contains no substring of the secret.

#### C6. Azure AutoWarp — a token service authorized by port number
- **Vendor:** Microsoft Azure (found by Orca Security) · **Date:** reported 2021-12-06, fixed 2021-12-10, disclosed 2022-03-07
- **URLs:** https://orca.security/resources/blog/autowarp-microsoft-azure-automation-service-vulnerability/ · https://msrc.microsoft.com/blog/2022/03/13943/

**What happened.** Azure Automation runs each customer's code in a sandbox on a
shared VM. Each sandbox reaches an internal token service on a port with **no
per-sandbox authentication**; scanning nearby ports returned managed-identity
JWTs belonging to *other tenants*. Orca harvested tokens from several hundred
ports across many tenants, including a telecom, two car manufacturers and a
banking conglomerate.

**Root cause.** A confused deputy: the shared service authorized by **network
position** rather than by a caller-bound secret. Microsoft's fix was exactly
that — require an `X-IDENTITY-HEADER` whose value is a per-sandbox secret
injected into the environment.

**ASSERT:** *No internal service authorizes by network position, port, source
address, or process locality. A test connects to every internal endpoint from an
unauthorized context and asserts refusal.*

**HERE:** `Formula.Sandbox` is precisely this shape — untrusted code running
next to trusted code. Its answer is stronger than Azure's (the host "builds the
guest's entire world out of the functions it hands in, and it hands in none"),
which means the test is a *build-time* assertion, not a runtime one: compile a
WASM module that imports anything at all — `wasi_snapshot_preview1`, a host
function name, an environment lookup — and assert `Sandbox.mapping/3` returns a
refusal with a repair rather than a working formula. This is the cheapest
high-value test in the whole document, because it fails closed by construction
and a regression would be silent otherwise.

#### C7. BingBang — authentication mistaken for authorization
- **Vendor:** Microsoft (found by Wiz) · **Date:** reported 2023-01-31, disclosed 2023-03-29
- **URLs:** https://www.wiz.io/blog/azure-active-directory-bing-misconfiguration · https://www.microsoft.com/en-us/msrc/blog/2023/03/guidance-on-potential-misconfiguration-of-authorization-of-multi-tenant-applications-that-use-azure-ad

**What happened.** An AAD app registered as **multi-tenant** lets any Azure
tenant mint a token for it; validating *which* tenant may log in is the
application's job. Wiz found ~25% of scanned multi-tenant apps lacked that
check, including Microsoft's own Bing CMS — they logged in with their own
tenant's user and altered a live Bing.com search carousel, then demonstrated
stored XSS that could mint Office 365 tokens and read a victim's mail, calendar,
Teams messages, SharePoint and OneDrive.

**Root cause.** The platform validated the token's *authenticity*; the
application was supposed to validate *identity*, and the default when it forgot
was "the whole world." MSRC's remediation is the instructive part: AAD stopped
issuing tokens to clients not registered in the resource tenant — the platform
took the invariant back rather than continuing to delegate it.

**ASSERT:** *A valid credential is never sufficient. Every entry point that
accepts a token asserts a specific grant, and a test presents a well-formed
token belonging to a caller with no grants and asserts every entry point
refuses.*

**HERE:** `Authority.may_name?/2` is the check and `Surface.Authorize` is where
it must be unskippable. The test that matters is an *enumeration* test: reflect
over every route in `Surface.Router` and every websocket message type in
`WatchChannel`, and assert each one refuses a valid-but-ungranted token. A new
endpoint added without the check should fail the suite by existing — which is
the same move MSRC made.

---

### D. Keys, certificates and clocks — correlated, scheduled failure

Wall-clock expiry is the one failure mode that **defeats replication by
construction**: every copy fails at the same instant.

#### D1. Azure AD key-rotation automation deleted a key still in use
- **Vendor:** Microsoft Azure · **Date:** 2021-03-15 ~19:00 UTC → 2021-03-16 09:25 UTC (~14h)
- **URL:** https://azure.status.microsoft/en-us/status/history/ (Tracking ID **LN01-P8Z**)

**What happened.** Microsoft's own text: "An error occurred in the rotation of
keys used to support Azure AD's use of OpenID… an automated system, on a
time-based schedule, removes keys that are no longer in use. Over the last few
weeks, a particular key was marked as 'retain' for longer than normal to support
a complex cross-cloud migration. **This exposed a bug where the automation
incorrectly ignored that 'retain' state, leading it to remove that particular
key.**" Once published metadata changed at 19:00 UTC, applications stopped
trusting tokens signed with the removed key.

**Root cause.** The key-lifecycle automation did not honour the `retain` flag —
a state-machine bug in a **deletion path with no human gate**, acting on a key
still in active use. Metadata was rolled back in two hours; mitigation ran for
fourteen because caching behaviour varied per application. Microsoft notes the
SDP protection covered *adding* a key; the *remove-key* path was in an unshipped
later phase.

**ASSERT:** *No automated process destroys key material that any live data
still references. A test creates a key, marks it retained, runs the reaper, and
asserts the key survives; then unmarks it, runs the reaper, and asserts it is
destroyed — both directions, because a reaper that never deletes is also a
defect.*

**HERE:** The single highest-consequence test in this system, because
`Erasure` destroys keys and destruction is designed to be **irreversible**. A
reaper or rotation bug in `Keyring.GCP` that destroys the wrong subject's KEK
does not lose availability — it permanently destroys facts, silently, and the
answer becomes `:erased` forever. Tests: (a) erasing subject A leaves every
other subject's facts readable, asserted over a population, not a pair; (b) the
KMS-backed keyring never calls `destroy` for a subject with no erasure
tombstone; (c) the reconciliation the README describes — "a key store restored
from before an erasure is corrected rather than trusted" — is asserted by
restoring an old key file over a ledger containing tombstones and checking the
erased subject is still erased. That last one is both a key test and a restore
test, and it is the one most likely to be wrong.

#### D2. Ericsson — an expired certificate compiled into shipped software
- **Vendor:** Ericsson · **Date:** 2018-12-06
- **URL:** https://www.prnewswire.com/news-releases/update-on-software-issue-impacting-certain-customers-300761376.html

**What happened.** Ericsson: "an issue in certain nodes in the core network…
using two specific software versions of the SGSN–MME… An initial root cause
analysis indicates that the main issue was an **expired certificate in the
software versions installed with these customers**." O2 UK lost 3G/4G data for
~24 hours across roughly **32 million** customers, plus Transport for London and
NHS trusts; SoftBank lost service for four hours; carriers in ~11 countries
were hit.

**Root cause.** An expiry date baked into a **shipped release** rather than
provisioned as rotatable operational data. Because the expiry was absolute
wall-clock, every deployed instance in every operator failed *simultaneously* —
redundancy across nodes, sites, and countries bought nothing, because all
replicas shared the identical time bomb.

**ASSERT:** *No artefact contains an embedded expiry. A test runs the full
boot-and-write path with the system clock set forward one year, five years, and
ten years, and asserts nothing refuses that did not refuse at the current time.*

**HERE:** The README's configuration doctrine already says "one artefact runs
anywhere and carries no secret," which is the right architecture; the test makes
it a claim. Concretely: the GCP service-account credential, any TLS material,
and any KMS key-version pin are all things that can expire *outside* the release
while the release assumes them. Clock-travel the test suite and assert
`Keyring.GCP` fails with a structured repair ("credential expired, mint a new
one") rather than a crash loop, and that `Job.Runner` cadences computed from
wall-clock do not fire N times at once when the clock jumps.

#### D3. Microsoft Teams — expired auth certificate, plus the reconnect storm
- **Vendor:** Microsoft · **Date:** 2020-02-03, 13:15–20:30 UTC (incident TM202916)
- **URL:** https://www.theverge.com/2020/2/3/21120248/microsoft-teams-down-outage-certificate-issue-status (status text reproduced at https://petri.com/allabout-teams-outage-3feb/)

**What happened.** Microsoft's status text: "We've determined that an
authentication certificate has expired causing users who have logged out **and
those that are still logged in** to have issue using the service." A new
certificate was deployed at 15:40 UTC, but at 16:20 the **reconnection surge**
forced throttling thresholds to be raised, and components had to be selectively
restarted to pick up the new cert. >20M DAU affected.

**Root cause.** A manually renewed certificate on a critical auth path with no
automated rotation and no expiry monitor. The second-order defect is the one
worth testing: recovery required a **restart to load new material**, and the
restart produced a thundering herd.

**ASSERT:** *Rotating a credential does not require a restart, and a mass
reconnect after a restart does not exceed the system's own limits — tested by
disconnecting every websocket client at once and asserting all reconnect within
a bound with no dropped facts.*

**HERE:** `watch` is a websocket surface, so every client reconnects together
after any deploy — and the README warns that "deploys reset in-flight work" is
a house rule paid for in v1. Test: N concurrent watchers, restart the endpoint,
assert every watcher resumes from its last delivered tx with no gap and no
duplicate. Reconnect-with-resume is exactly where the FaunaDB cursor bug (B6)
and the Teams herd meet.

#### D4. Let's Encrypt CAA rechecking — one domain checked N times
- **Vendor:** ISRG / Let's Encrypt · **Date:** introduced 2019-07-25, discovered 2020-02-29
- **URL:** https://community.letsencrypt.org/t/2020-02-29-caa-rechecking-bug/114591

**What happened.** In Boulder, "when a certificate request contained N domain
names that needed CAA rechecking, Boulder would pick one domain name and check
it N times." Roughly **3 million** certificates were affected; 1,706,505 were
revoked by the 2020-03-05 deadline and ~1 million more were left to expire
naturally to avoid mass breakage.

**Root cause.** A loop that iterated the right number of times over the wrong
element — validating one item N times instead of N items once. The count was
correct, so nothing about the shape of the result looked wrong.

**ASSERT:** *An authorization check over a collection checks every element. A
test grants access to ledger A, denies ledger B, requests a snapshot over
`[A, B]`, and asserts refusal — and separately over `[A, A, B]` and `[B, A]`,
because an off-by-position bug passes the first ordering and fails the second.*

**HERE:** This is the Let's Encrypt bug transplanted into `Snapshot.open/1`,
which takes a **list of ledgers**. A `may_name?` loop that checks
`hd(ledgers)` N times, or that uses `Enum.any?` where it meant `Enum.all?`,
grants a caller every ledger in a snapshot as long as it may name one of them.
Given that "authorization is which ledgers you may name" is the whole security
model, this specific test — mixed-permission ledger lists, in several orderings,
with duplicates — is non-negotiable.

#### D5. Leap second 2012 — time went backwards and every replica spun
- **Date:** 2012-06-30 23:59:60 UTC
- **URLs:** https://lwn.net/Articles/504658/ (John Stultz's diagnosis) · https://lwn.net/Articles/504744/ · https://bugzilla.mozilla.org/show_bug.cgi?id=769972

**What happened.** Reddit, Mozilla, LinkedIn, Yelp, Foursquare, Gawker,
StumbleUpon and Amadeus/Qantas went down or degraded simultaneously. Stultz:
"Leap second occurs, CLOCK_REALTIME is set back one second. As
`clock_was_set()` is not called, the hrtimer base.offset value for
CLOCK_REALTIME is not updated… all sub-second TIMER_ABSTIME CLOCK_REALTIME
timers will return immediately. If any such timer calls are done in a loop (as
commonly done with futex_wait or other timeouts), this will cause load spikes."
The missing call had been removed in 2007 and lay dormant for 3½ years because
the previous leap second was 2008. Everyone initially blamed Java, because JVM
workloads happen to use sub-second absolute-time futex waits.

**Related, and better written:** Cloudflare's DNS leap-second outage,
2017-01-01, https://blog.cloudflare.com/how-and-why-the-leap-second-affected-cloudflare-dns/
— root cause in their words: "the belief that time cannot go backwards."
`rtt := time.Now().Sub(start)` went **negative**, fed a smoothed score that went
negative, which was passed to `rand.Int63n()`, which panics on a negative
argument. The Go monotonic-clock proposal cites it and states the general
property: "when it does, all the copies of the program across the entire
distributed system fail simultaneously, defeating any redundancy."

**ASSERT:** *No duration is computed by subtracting two wall-clock readings; all
durations use a monotonic source. Property test: run the suite with the wall
clock stepped backwards mid-run and assert no negative duration, no timer
storm, and no scheduled job firing more than once for its cadence.*

**HERE:** `Job.Runner` decides "which jobs are due" on each tick, and
`Job.last_run/2` is answered from facts. If either uses `DateTime.utc_now/0`
arithmetic, a backwards clock step either fires every job at once or stalls them
all. Elixir's `System.monotonic_time/1` is the fix and the test is a clock-step
property. Note the second half applies to snapshots too: a fact's timestamp may
be wall-clock (it is a fact about the world), but the **ordering** of facts must
come from the ledger's tx counter, never from a timestamp. Assert that two facts
written in order replay in that order even when the second carries an earlier
timestamp.

---

### E. Deploy and configuration — the change that was data, not code

The recurring shape: a deploy is clean, the defect is latent, and the **trigger
arrives later as input**, which defeats deploy-correlated detection entirely.

#### E1. Cloudflare 2025-11-18 — a generated feature file outgrew its bound
- **Vendor:** Cloudflare · **Date:** 2025-11-18 (DB change 11:05 UTC, impact from 11:20 UTC)
- **URL:** https://blog.cloudflare.com/18-november-2025-outage/

**What happened.** A ClickHouse permissions change made user access explicit,
so a metadata query in the Bot Management feature-file generator —
`SELECT name, type FROM system.columns WHERE table = 'http_requests_features'`,
with **no database filter** — began returning rows for both the `default` and
`r0` databases, more than doubling the result. The generated feature file
doubled in size and exceeded a **hardcoded preallocation limit of 200**
features (normal usage: ~60). The FL2 proxy panicked:
`thread fl2_worker_thread panicked: called Result::unwrap() on an Err value`,
returning 5xx. The file regenerated every five minutes from a cluster that was
being updated node by node, so the system **flapped** between good and bad
states — which is why it was initially misdiagnosed as a hyper-scale DDoS.

**Root cause.** A derived artefact whose size was bounded by assumption rather
than by validation, consumed by a parser that treated exceeding the bound as
unreachable (`unwrap`) rather than as an error. The permissions change was
correct; the query was underspecified.

**ASSERT:** *Every generated artefact is validated against its consumer's limits
at generation time, and the consumer fails soft — refusing this artefact and
keeping the last known-good one — rather than crashing. A test generates an
artefact at 1×, at the limit, and at 2× the limit, and asserts the third is
rejected at generation and, if forced through, does not take the process down.*

**HERE:** This maps onto **formulas and checkpoints**, which are exactly
"derived artefacts consumed by a hot path." A formula whose output is larger
than expected, a checkpoint file from a different schema version, or a WASM
module whose exports do not match — each must be *rejected*, and since a
checkpoint is derived, rejecting it must fall back to "open without one, which
is correct and merely slower" (per `Backup`'s own doc). Test: corrupt/oversize a
checkpoint and assert the ledger opens anyway with identical answers. The
flapping detail matters too: a bad artefact regenerated on a cadence produces
*intermittent* failure, so the test must assert the fallback is stable, not
merely that one bad load is survived.

#### E2. CrowdStrike Channel File 291 — 21 fields expected, 20 supplied
- **Vendor:** CrowdStrike · **Date:** 2024-07-19 (RCA 2024-08-06)
- **URL:** https://www.crowdstrike.com/wp-content/uploads/2024/08/Channel-File-291-Incident-Root-Cause-Analysis-08.06.2024.pdf

**What happened.** An IPC Template Type expected **21** input parameters while
the sensor's regex matching supplied **20**. Reading the 21st field was an
out-of-bounds read in the Content Interpreter, crashing the kernel driver on
millions of Windows hosts. The Content Validator had "a logic error" and did not
catch the count mismatch. Earlier Template Instances had never exercised the
matching criteria that reached it.

**Root cause.** A content/code contract with two independent definitions of its
arity, validated only at compile time and never by running the content through
the actual interpreter. CrowdStrike's own remediations: test a wider variety of
matching criteria, exercise content in the Content Interpreter, and stage
Template Instance deployment.

**ASSERT:** *Content is validated by the interpreter that will consume it, not
by a separate validator that reimplements the contract. A test round-trips every
generated artefact through the real consumer before it is considered valid.*

**HERE:** `Formula.Sandbox` builds a `LazyRiver.Formula` from a WASM module and
an `over:` pattern. The arity contract between "what the pattern yields" and
"what the guest's `apply` export takes" is exactly CrowdStrike's 21-vs-20. The
test is to construct formulas with mismatched arity and assert the failure
happens at `Sandbox.mapping/3` — build time — with a refusal carrying a repair,
which is what the moduledoc already promises ("it fails to build at all… That is
a better place to find out"). A promise in a moduledoc with no test is how the
Content Validator's logic error survived.

#### E3. Azure Storage 2014 — a global rollout that could not be rolled back
- **Vendor:** Microsoft Azure · **Date:** 2014-11-18/19 (main impact 00:50–11:00 UTC)
- **URL:** https://azure.microsoft.com/en-us/blog/final-root-cause-analysis-and-improvement-areas-nov-18-azure-storage-service-interruption/

**What happened.** A CPU optimisation for Table front-ends was deployed
globally in one step — "the standard flighting deployment policy of
incrementally deploying changes across small slices was not followed" — and was
"incorrectly enabled for Azure Blob storage Front-Ends," where it hit a
previously undiscovered bug that put front-ends into an **infinite loop**.

**Root cause.** Two compounding defects. The staged-rollout policy was
advisory: "the configuration tooling did not have adequate enforcement of this
policy." And the infinite loop destroyed the escape hatch — the change was
reverted globally within 30 minutes, but front-ends already spinning "were
unable to accept any configuration changes," so they could not read their own
rollback and needed manual restarts.

**ASSERT:** *A configuration rollback is applied by a path that a wedged process
can still service — tested by wedging the process and asserting the rollback
still takes effect, rather than assuming the process will read it.*

**HERE:** Single-node with config "read at boot" (per the README) means the
rollback path is a restart, which is honest and simple — but it makes boot the
critical path. Test: every environment variable in the README's table, set to a
malformed value, must produce a refusal at boot with a repair, not a crash loop
and not a silent default. `SECRET_KEY_BASE` already refuses; the assertion is
that `LEDGER_DIR` pointing at a non-writable path, `KMS_KEY` naming a
nonexistent key, and `BACKUP_EVERY` set to `0` do too.

#### E4. Fastly 2021 — a customer's valid config reached a latent bug globally
- **Vendor:** Fastly · **Date:** 2021-06-08 (09:47 UTC onset; 95% recovered by 10:36)
- **URL:** https://www.fastly.com/blog/summary-of-june-8-outage

**What happened.** "On May 12, we began a software deployment that introduced a
bug that could be triggered by a specific customer configuration under specific
circumstances." It sat dormant for 27 days. On June 8 a customer "pushed a valid
configuration change that included the specific circumstances that triggered the
bug, which caused **85% of our network to return errors**."

**Root cause.** A latent defect in the config path, undetected because no
existing configuration exercised it — and a **customer-supplied input** able to
reach a globally, simultaneously-applied code path with no canary between the
push and the whole fleet.

**ASSERT:** *Caller-supplied input cannot reach a globally-applied code path
without passing a validator that is itself fuzzed. Property test: generate
random valid-per-schema inputs and assert none crashes the process, only that
some are refused.*

**HERE:** Caller-supplied inputs here are snapshot names, questions, WASM
formula bodies, and job cadences. All four are attacker-controlled in the
threat model where a tenant is not trusted. The formula body is the sharpest —
`Formula.Sandbox` should be fuzzed with malformed and adversarial WASM
(enormous memories, deep recursion, infinite loops) and asserted to refuse or to
be killed by a fuel/time bound, never to wedge the node. "Pure" does not mean
"terminating."

#### E5. Google Cloud 2025-06-12 — a blank field crash-looped every region at once
- **Vendor:** Google Cloud · **Date:** 2025-06-12 (10:51–13:49 PDT; full resolution 18:18 PDT)
- **URL:** https://status.cloud.google.com/incidents/ow5i3PPK96RduMcb1SsW

**What happened.** A quota-policy feature shipped on **May 29** but "the code
path that failed was never exercised during this rollout due to needing a policy
change that would trigger the code." On June 12 "a policy change was inserted
into the regional Spanner tables that Service Control uses for policies… This
policy data contained unintended blank fields." Because quota management is
global, "this metadata was replicated globally within seconds," and Service
Control — in the serving path of every Google Cloud API request — hit a null
pointer and crash-looped in every region simultaneously.

**Root cause.** Google's words: the change "did not have appropriate error
handling nor was it feature flag protected." An unhandled null on a field
assumed always populated, in a critical-path binary, fed by a globally
replicated datastore with **zero blast-radius containment**. Recovery in
us-central1 took an extra ~2h40m because restarting tasks "created a herd
effect… Service Control did not have the appropriate randomized exponential
backoff."

**ASSERT:** *Every field read from persisted data is handled when absent, and a
test replays a corpus containing records with every field individually omitted,
asserting a structured refusal rather than a crash.* **And:** *a poison record
cannot crash-loop the process — after N failures on the same record, it is
quarantined and the system continues.*

**HERE:** A fact-log replays **all** its history at open, so a single
unparseable fact written by an older version can make the ledger permanently
un-openable — the crash loop, but permanent, which is worse than Google's. Test:
inject a fact with each field missing, an unknown attribute type, and a
future-version encoding, and assert `Ledger` opens and the bad fact is
quarantined rather than fatal. This is the durability equivalent of a feature
flag.

#### E6. Cloudflare 2019-07-02 — a regex with no CPU budget
- **Vendor:** Cloudflare · **Date:** 2019-07-02, 13:42–14:09 UTC (27 minutes)
- **URL:** https://blog.cloudflare.com/details-of-the-cloudflare-outage-on-july-2-2019/

**What happened.** A WAF rule for XSS detection contained a regex with
catastrophic backtracking (the `.*(?:.*=.*)` tail — nested quantifiers over the
same input). Because WAF rules run inline on every request, it "caused CPUs to
become exhausted on every CPU core that handles HTTP/HTTPS traffic," spiking to
nearly 100% globally.

**Root cause.** Two defects, not one. The WAF ran on a backtracking engine with
**no CPU or step budget** — a previous refactor had removed the protective
safeguards — and the rule was deployed globally in one step. Recovery was
delayed by a dependency loop: "with our Access service down we couldn't
authenticate to our internal control panel," and some engineers had lost
credentials because a security feature disables them when the control panel is
used infrequently.

**ASSERT:** *Every caller-influenced computation has a bound — steps, fuel,
memory, or wall time — and exceeding it aborts that request only. Test: submit
an input engineered to be superlinear and assert the request is killed within
the bound while concurrent requests are unaffected.*

**HERE:** Formulas are the WAF rules of this system: caller-supplied code on the
read path. WASM makes a fuel bound easy and the test straightforward — a guest
with an infinite loop must be killed and the `ask` must return a refusal, with
other ledgers' queries unaffected during it. Add the same for `question`
complexity if questions can be recursive.

---

### F. Capacity, retries, and the herd

Ten years separate the oldest and newest of these and the missing piece is
identical every time: **randomized exponential backoff on a self-inflicted
thundering herd during recovery.**

#### F1. AWS DynamoDB 2015 — a metadata retry storm that could not drain
- **Vendor:** AWS · **Date:** 2015-09-20, 02:19–07:10 PDT
- **URL:** https://aws.amazon.com/message/5467D2/

**What happened.** Storage servers periodically confirm partition membership
with a metadata service. A brief network disruption caused a large set of them
to lose membership and re-request simultaneously. Responses "exceeded the
retrieval and transmission time allowed by storage servers," so servers timed
out, dropped membership, and retried — a storm that kept the metadata service
saturated and never drained. Error rates stabilised around **55%**; engineers
had to *pause* the metadata service to break the loop.

**Root cause.** Global Secondary Indexes had silently inflated membership-list
size beyond provisioned capacity — "because GSIs are global, they have their own
set of partitions… and therefore increase the overall size of a storage server's
membership data" — and AWS "didn't have detailed enough monitoring for this
dimension (membership size)." Compounding: the retry had **no backoff** and a
**fixed timeout that had become too short** for the now-larger payloads.

**ASSERT:** *No timeout is a constant when the payload it governs can grow. A
test grows the governed quantity by 10× and asserts either that the operation
still completes or that it fails with a message naming the size — never that it
times out silently and retries.*

**HERE:** Two growing quantities with fixed timeouts waiting to happen: the
replay at `Ledger` open (which grows with every fact ever written) and the
`Backup` run (bounded by *changed* bytes, which is the right design — the README
is explicit that "the cost of a backup is what changed, not what exists"). Test
the first at size: `mix test --include load` should assert open time scales with
history and that no supervisor or GenServer `:timeout` is a constant that a
large ledger crosses. A ledger that becomes un-openable because
`GenServer.call/2`'s 5-second default fires is this incident exactly.

#### F2. AWS Kinesis 2020 — O(n²) threads against an OS ceiling
- **Vendor:** AWS · **Date:** 2020-11-25, 05:15–22:23 PST (~17h)
- **URL:** https://aws.amazon.com/message/11201/

**What happened.** A routine capacity addition to the front-end fleet pushed
each server past "the maximum number of threads allowed by an operating system
configuration" — "each front-end server creates operating system threads for
each of the other servers in the front-end fleet," so threads grow O(n) per
server and O(n²) fleetwide. Cache construction never completed and "front-end
servers were ending up with useless shard-maps" — a **silent wrong answer**
rather than an error.

**Root cause.** A per-server resource that scales with fleet size, with a hard
ceiling and **no monitoring on the resource itself**. Adding capacity made
things worse, which inverts every operator instinct.

**ASSERT:** *Every resource that scales with a countable quantity has an
explicit ceiling and an alarm below it. Test: assert process count, file
descriptor count, and ETS table count as functions of ledger count, and fail if
any is superlinear.*

**HERE:** Very concrete. Every ledger is a `GenServer` (`Ledger.via/1`) plus
open file handles; every watcher is a process; every subscription holds state.
With tenants arriving at runtime, ledger count is caller-controlled. Test:
open 10,000 ledgers and assert file descriptors and processes grow linearly and
stay under the VM's limits — and that the failure when they do not is a refusal
naming the limit. The `Ledger` moduledoc already shows this instinct ("atoms are
never collected — a name taken from a request would leak the atom table until
the node fell over"), and *that* deserves its own test: assert
`Ledger.start_link/1` with a caller-supplied name creates no atom.

#### F3. Slack 2021-01-04 — the scaling signal that pointed the wrong way
- **Vendor:** Slack · **Date:** 2021-01-04 (writeup 2021-02-01)
- **URL:** https://slack.engineering/slacks-outage-on-january-4th-2021/

**What happened.** First working Monday of the year: clients returned with
**cold caches**. An AWS Transit Gateway did not scale fast enough for the
packets-per-second ramp and dropped packets. Then the loops: packet loss made
Apache threads spend longer *waiting*, so **CPU utilisation fell**, triggering
automated **downscaling**, immediately followed by massive upscaling — Slack
tried to add **1,200 servers between 07:01 and 07:15 PST**. The provisioner ran
over the same degraded network and hit the Linux open-files limit and an AWS
quota; most instances were created but never served, and the broken pile hit the
autoscaling-group ceiling, blocking real capacity. The dashboards were in a
different VPC from their databases, so they died too. Health-check replacement
deprovisioned instances engineers were actively SSH'd into.

**Root cause.** A scaling signal (CPU) that **inverts** under the failure it is
meant to detect, plus control-plane components sharing fate with the data plane.

**ASSERT:** *Every automated scaling or health signal is tested under the
failure it is meant to detect, and asserted to move in the correct direction. A
test degrades the dependency and asserts the health check reports unhealthy —
not merely that it reports healthy when things are fine.*

**HERE:** `Vitals` is the health surface, and the assertion is the same:
degrade each dependency — fill `LEDGER_DIR`, break the KMS, 403 the backup
bucket — and assert `Vitals` reports unhealthy *for the right reason each time*.
A health check that passes because it only measures whether the VM is up is the
Slack CPU signal. Second lesson, cheap to honour: whatever answers "is this
node healthy" must not itself require the ledger to be readable, or a corrupt
ledger reports healthy forever.

#### F4. AWS us-east-1 2021-12-07 — congestion, latent backoff defect, blind operators
- **Vendor:** AWS · **Date:** 2021-12-07, 07:30–14:22 PST
- **URL:** https://aws.amazon.com/message/12721/

**What happened.** An automated scaling activity on the main AWS network
"unexpectedly caused a large surge of connection activity that overwhelmed the
networking devices between the internal network and the main AWS network."
Congestion caused failures and retries, which caused more connections.

**Root cause.** "Our networking clients have well tested request back-off
behaviors… but a **latent issue prevented these clients from adequately backing
off** during this event." Backoff existed, was tested, and did not engage — the
tests did not cover the condition under which it mattered. Second defect:
monitoring data traversed the same congested path, so "it impaired their ability
to find the source of congestion," and the Service Health Dashboard and support
systems depended on the impaired internal network.

**ASSERT:** *Backoff is asserted by observation, not by configuration — a test
induces the failure and measures the actual inter-attempt intervals, asserting
they grow and are jittered.*

**HERE:** `Backup` retries against S3 and `Keyring.GCP` retries against KMS.
Both are jobs, so both already record failures as facts — which makes the test
easy and unusually good: fail the target N times, then assert from the *ledger
itself* that the recorded attempt timestamps grow exponentially and are
jittered. The system's own doctrine ("a backup records a failure as an ordinary
fact") turns a hard test into a query.

---

### G. Dependency loops — the fix was behind the thing that broke

#### G1. Meta 2021-10-04 — DNS withdrew itself, and the doors would not open
- **Vendor:** Meta · **Date:** 2021-10-04 (writeup 2021-10-05)
- **URL:** https://engineering.fb.com/2021/10/05/networking-traffic/outage-details/

**What happened.** "A command was issued with the intention to assess the
availability of global backbone capacity, which unintentionally took down all
the connections in our backbone network." Then the cascade: Facebook's DNS
servers are designed to **withdraw their BGP advertisements if they cannot reach
the data centers**. With the backbone gone, every DNS site declared itself
unhealthy and withdrew simultaneously, so the authoritative nameservers vanished
from the internet even though they were running fine.

**Root cause.** "Our systems are designed to audit commands like these to
prevent mistakes like this, but **a bug in that audit tool prevented it from
properly stopping the command**" — the guardrail failed open, silently. And
architecturally, a health signal wired to a globally correlated dependency, so
the safety mechanism amplified a partial failure into a total one. Recovery
required physical access: "it was not possible to access our data centers
through our normal means because their networks were down, and… the total loss
of DNS broke many of the internal tools we'd normally use," and once on site the
hardware was deliberately hard to modify.

**ASSERT:** *Every recovery path is exercised with its normal dependencies
unavailable. A test performs restore, key access, and health inspection with the
network, the KMS, and the primary store each failed in turn.*

**HERE:** The sharpest version of this in Lazy River is `Erasure` +
`Keyring.GCP` + `Backup`: a restore needs the KMS to unwrap the master, and the
KMS credential comes from configuration that lives... where? Test the loop
explicitly — restore into a *clean* environment with only the bucket and the
`KMS_KEY` name, and assert facts are readable. If the restore needs anything
that was only on the dead machine, that is Meta's badge reader. Second loop:
`Vitals`, `Job.last_run/2`, and the backup's own history are all *facts in
ledgers*, so if the ledger is the thing that broke, the system cannot report
that it broke. Assert there is a path to "when did the backup last succeed" that
does not require the ledger to open.

#### G2. Cloudflare 2023-11-02 — the failover they had never performed
- **Vendor:** Cloudflare · **Date:** 2023-11-02 11:43 UTC → 2023-11-04 04:25 UTC (~36h)
- **URL:** https://blog.cloudflare.com/post-mortem-on-cloudflare-control-plane-and-analytics-outage/

**What happened.** Cloudflare's control plane and analytics run in three
Oregon datacenters in an HA cluster meant to survive losing any one. At
Flexential PDX-04, a utility feed was already out for unplanned maintenance
when a **ground fault on a PGE transformer** occurred; the ground-fault
protection "also shut down all of PDX-04's generators," and UPS batteries rated
for ten minutes "started to fail after only 4 minutes." The HA cluster was not
actually independent of PDX-04: "two critical services that process logs and
power our analytics — **Kafka and ClickHouse** — were only available in PDX-04
but had services that depended on them that were running in the high
availability cluster." Failover to the European DR site left several newer
products stranded "where we had not fully implemented and tested a disaster
recovery procedure." Restoration was then blocked because "the circuit breakers
were discovered to be faulty." Log data is permanently gone: "anything you did
not receive will not be recovered," and "some datasets which are not replicated
in the EU will have persistent gaps."

**Root cause.** Cloudflare's own sentence is the finding: "we had never tested
fully taking the entire PDX-04 facility offline." Under an untested assumption,
stateful services accreted single-facility dependencies *inside* a supposedly HA
cluster, and new products were onboarded to production without being onboarded
to DR. The failover they had to perform was a failover they had never performed
— and stateful systems are exactly the ones that do not tolerate an unrehearsed
first attempt.

**ASSERT:** *A restore from backup into a brand-new empty environment is
performed by the test suite, on every run, and the restored system's answers are
byte-identical to the original's for a set of named snapshots.*

**HERE:** The single most valuable test this system can have, and it is
achievable here in a way it was not for Cloudflare, because the whole state is a
directory of segments plus a key file. Test: write facts, run `Backup`, capture
`{name, question} -> answer` for many pairs, destroy `LEDGER_DIR` and `KEY_DIR`
entirely, restore from the S3 target into empty directories, and assert every
pair answers identically. Then the second half, which is the part Cloudflare
missed: run that test **for every feature**, so a new store, a new formula tier
or a new keyring backend cannot ship without being in the restore path. And a
third assertion drawn from their permanent gaps: the test must confirm the
restore covers everything not derivable — checkpoints may be absent (they are
derived), keys must not be.

#### G3. AWS S3 2017 — the restart nobody had timed
- **Vendor:** AWS · **Date:** 2017-02-28, 09:37–13:54 PST (~4h17m)
- **URL:** https://aws.amazon.com/message/41926/

**What happened.** An authorized engineer, debugging billing errors, ran an
established playbook command to remove a small number of servers from the S3
billing subsystem. "One of the inputs to the command was entered incorrectly and
a larger set of servers was removed than intended," taking out capacity for the
**index subsystem** (metadata and location for every object in the region) and
the **placement subsystem** (which itself depends on the index subsystem). Both
required a full restart.

**Root cause.** Not the typo. Two defects: a removal tool with **no safety check
on the resulting capacity floor** — AWS added "safeguards to prevent capacity
from being removed when it will take any subsystem below its minimum required
capacity level" — and **unmeasured restart time at scale**: "We have not
completely restarted the index subsystem or the placement subsystem in our
larger regions for many years," so the safety checks these subsystems run on
restart took far longer than anyone had data for.

**ASSERT:** *Cold-start time is a measured, asserted quantity at production
scale, not an assumption. A load test opens a ledger with a
production-sized history and asserts the open completes within a stated bound —
and the bound is in the test, so it fails when it regresses.*

**HERE:** `Ledger.open` replays every fact ever written (with checkpoints as an
optimisation). That is the S3 index subsystem's restart, exactly, and it grows
monotonically forever. `mix test --include load` is the right place: assert open
time at 10⁶ and 10⁷ facts, both with and without a checkpoint, and assert the
*without* case still completes — because the README says opening without one "is
correct and merely slower," and "merely slower" is a claim with a number in it
that nobody has written down. Second assertion from the same incident: a
destructive operation refuses when it would take the system below a floor —
here, `Erasure.erase` and any segment-pruning path should refuse if the target
does not exist rather than proceeding silently.

#### G4. Google Cloud 2019-06-02 — repairing over the network you broke
- **Vendor:** Google Cloud · **Date:** 2019-06-02, 11:45–~16:10 US/Pacific
- **URLs:** https://status.cloud.google.com/incident/cloud-networking/19009 · https://cloud.google.com/blog/topics/inside-google-cloud/an-update-on-sundays-service-disruption

**What happened.** Three conditions coincided: network control-plane jobs were
configured to stop during a datacenter maintenance event; the instances running
them were marked for a rare maintenance type; and the maintenance automation had
"a specific bug, allowing it to deschedule multiple independent software
clusters at once, crucially even if those clusters were in different physical
locations." A descheduling list scoped to *one* physical location contained
*logical* clusters spanning several datacenters. The network failed static for a
few minutes, then BGP was withdrawn; affected regions lost "more than half of
their available network capacity."

**Root cause.** An automation bug that let a location-scoped operation cross
physical-location boundaries because it operated on logical rather than physical
identifiers. Aggravating factor: "Debugging the problem was significantly
hampered by failure of tools competing over use of the now-congested network" —
detection took seconds, correction took hours.

**ASSERT:** *An operation scoped to one unit affects only that unit. Test:
perform every scoped operation — erase, backup, close, prune — against one
ledger/subject in a population and assert that every other member is
bit-identical afterwards.*

**HERE:** The logical-vs-physical distinction is live here: a *subject* spans
ledgers (a person's facts may be in several), while a *ledger* is the
sovereignty boundary. `Erasure` is scoped by subject and `Backup`/`Ledger` by
ledger, so an operation that confuses the two crosses a tenant boundary. Test:
two ledgers sharing a subject, and two subjects sharing a ledger; erase one
subject and assert the other subject in the same ledger is untouched and every
fact of the erased subject in *both* ledgers is `:erased`. Getting either half
wrong is a different incident — one is a leak, the other is a failed erasure.

#### G5. AWS DynamoDB DNS 2025 — a stale writer overwrote a newer plan
- **Vendor:** AWS · **Date:** 2025-10-19 23:48 PDT → 2025-10-20 ~13:50 PDT
- **URL:** https://aws.amazon.com/message/101925/

**What happened.** DynamoDB's regional endpoint DNS is driven by a **Planner**
that emits plans and **Enactors** that apply them, running "redundantly and
fully independently in three different Availability Zones." Enactor A stalled
mid-application; Enactor B applied a much newer plan and then ran cleanup,
deleting stale plans. Delayed Enactor A then finished writing its **old** plan,
overwriting B's newer one; cleanup, seeing a plan many generations old, deleted
it. "All IP addresses for the regional endpoint were immediately removed," and
"the system was left in an inconsistent state that prevented subsequent plan
updates from being applied by any DNS Enactors" — the automation could not
self-heal. Downstream, EC2's DropletWorkflow Manager hit **"congestive
collapse"** on the lease backlog when DynamoDB returned.

**Root cause.** A race between plan application and cleanup, with **no fencing
or generation check on the write** — a delayed writer was permitted to overwrite
a newer value, and the garbage collector then removed the only remaining record.
This is the etcd-lock finding (B2) with a production blast radius: redundancy
without a fencing token is not redundancy.

**ASSERT:** *Every write carries the generation it believed it was updating, and
is rejected if that generation is stale. A test delays one writer past a
second's complete write-and-cleanup cycle and asserts the delayed write is
refused, not applied.*

**HERE:** Three places a delayed writer can clobber a newer state. (1)
`Backup` uploading a segment range while a later run has already uploaded a
superseding one — the S3 target must reject or version, not last-write-wins. (2)
`Keyring` writing the key file: a slow write after a rotation or an erasure must
not restore destroyed keys, which is precisely why the README's tombstone
reconciliation exists — so test it by racing a stale key-file write against an
erasure. (3) Checkpoint writing after a newer checkpoint exists. In all three
the assertion is the same: the write names the state it supersedes, and a stale
name is refused.

---

### H. The storage substrate lied

Every entry here is the same sentence: **an interface reported success for
something that had not become durable, and the layer above had no way to tell.**
For a system whose entire value proposition is "facts accumulate and never
change," this is the family that decides whether the product is true.

#### H1. PostgreSQL fsyncgate — the second fsync succeeded because the first ate the error
- **Vendor:** PostgreSQL / Linux kernel · **Date:** reported 2018-03-28, LWN 2018-04-18, fixed 2018-11-19 (shipped 2019-02-14)
- **URLs:** https://www.postgresql.org/message-id/flat/CAMsr%2BYHh%2B5Oq4xziwwoEfhoTZgr07vdGG%2Bhu%3D1adXx59aTeaoQ%40mail.gmail.com (Craig Ringer) · https://lwn.net/Articles/752063/ (Corbet, "PostgreSQL's fsync() surprise") · https://postgrespro.com/list/id/20180427222842.in2e4mibx45zdth5@alap3.anarazel.de (Andres Freund's analysis)

**What happened.** Postgres wrote buffers to the page cache. Writeback failed on
a storage error; the kernel marked the pages `AS_EIO` with no channel to tell the
application. At the next checkpoint the checkpointer called `fsync()`, got
`EIO`, correctly treated the checkpoint as failed and did **not** advance the
redo pointer — then **retried**. The retry's `fsync()` returned success, because
the first call had *consumed and cleared* the error. The checkpoint completed,
the redo pointer advanced, and the WAL holding the only surviving copy was
discarded. Ringer: "The retry succeeded, because the prior fsync() cleared the
AS_EIO bad page flag. The write never made it to disk, but we completed the
checkpoint, and merrily carried on our way. Whoops, data loss."

**Root cause, two layers.** *Kernel:* on Linux a writeback error is reported **at
most once**, and the dirty pages are not kept dirty — XFS invalidates the failed
page-cache contents (so a re-read returns the *old* persistent bytes) while ext4
keeps the modified contents but **marks them clean**, so the cache lies about
durability until eviction. Since 4.13, `errseq_t` delivers the error exactly once
to every fd **that was already open when the error occurred, and never to one
opened afterwards** — and the checkpointer typically opens the relation file *at
checkpoint time*, i.e. after the failing writeback, so it can be structurally
incapable of seeing the error. *Postgres:* assumed `fsync()` success means
"durable since the last fsync" rather than "since the last **successful** fsync."

**Fix.** Thomas Munro's commit "PANIC on fsync() failure" — the first `fsync()`
failure on a data file now panics, violently preventing a later checkpoint from
appearing to succeed; recovery replays from WAL. New GUC `data_sync_retry`,
default `off` (= panic). Note the residual window the commit message admits: if
the file is closed and reopened and the inode is evicted in between, the error
can still be missed.

**ASSERT:** *An `fsync` (or `:file.sync`) error is fatal to the transaction and
is never retried — a test injects `EIO` on sync and asserts the process crashes
or the write is refused, and specifically asserts that a subsequent successful
sync does **not** cause the system to consider the earlier write durable.*

**HERE:** The highest-severity storage claim this system makes. `LEDGER_SYNC=true`
means `Store.File` calls `:file.sync/1`; Elixir will hand back `{:error, :eio}`
and the tempting code is `retry`. Postgres's answer is the right one and it is
cheap in OTP: **let the process crash.** The test uses a failing filesystem
(a small loopback image, or an intercepting module behind the `Store` behaviour)
to return `:eio` once, and asserts (a) the write is not acknowledged, (b) the
ledger process terminates rather than continuing, and (c) after restart, replay
does not include the un-synced fact. Also assert the file descriptor is held
open across the write-and-sync — reopening between write and sync is precisely
the errseq_t hole.

#### H2. "How To Corrupt An SQLite Database File" — the best list of testable claims in the field
- **Vendor:** SQLite (living document; incidents dated in-text)
- **URL:** https://www.sqlite.org/howtocorrupt.html

This is not one incident, it is a curated catalogue of them, and it is the
single most directly reusable source in this document. Harvested, with the
mechanism and the Lazy River analogue:

| # | Mechanism | Analogue here |
|---|---|---|
| 1.1 | **Stale file descriptor.** An fd is closed, the number is reused by the db `open()`, and another thread writes to the old number *into the database*. Real case: Fossil closed fd 2, the db got fd 2, an `assert()` wrote its message into the file. | Any `Store.File` fd shared across processes, or a segment fd cached across a `close`/`open` cycle. |
| 1.2 | **Backup of a live file.** `cp` while a transaction is in flight yields a mix of pre- and post-transaction pages. | Exactly why `Backup` copies "only the prefix that scans cleanly." Test it. |
| 1.3 | **Deleting/moving/renaming a hot journal.** After a crash the journal is the rollback record; remove it and the half-applied transaction stays half-applied. | A segment or checkpoint moved/renamed by an operator or a restore script. |
| 1.4 | **Mispairing db and journal.** Restoring a db over an existing hot journal applies the wrong pages. | Restoring a segment set over a `LEDGER_DIR` that already has newer segments. |
| 2.1 | **Broken locking on network filesystems** (NFS especially): two writers interleave. | `LEDGER_DIR` on NFS/EFS. The README says "must be persistent storage" — it should also say "must not be a network filesystem," and a boot check should refuse. |
| 2.2 | **POSIX advisory locks cancelled by `close()`.** *Any* `close()` of *any* fd on that file, by any thread in the process, drops **all** the process's advisory locks. A third thread that merely opens, reads and closes the db silently strips locks held by two threads mid-transaction. | The reason to prefer a single owning process (a `Ledger` GenServer) over file locks. Assert only one process ever opens a segment for write. |
| 2.3 | **Two copies of the library in one process**, each with its own list of open files, so neither sees the other's connections. | Two `Ledger` processes for the same name — assert `via/1` registration makes this impossible, including after a supervisor restart race. |
| 2.5 | **Unlinking or renaming a live db.** POSIX permits it; a second process recreates the name, and now two inodes share one journal name. | An operator `mv`-ing `LEDGER_DIR` while running. |
| 2.6 | **Multiple hard/soft links.** Journal names derive from *the path used to open*, so two paths ⇒ two journals ⇒ recovery looks in the wrong place. | Two `LEDGER_DIR` values resolving to the same inode. Canonicalise at boot and refuse duplicates. |
| 2.7 | **Carrying a connection across `fork()`.** The child inherits locking state it does not own; closing in the child deletes files under the parent. | Not reachable in the BEAM, but the equivalent is passing a raw fd or an ETS handle to a process that outlives the owner. |
| 3.1 | **Drives that lie about flushing.** Consumer drives and USB sticks acknowledge a cache flush with data still in a volatile buffer. SQLite cannot detect the lie. | Not testable in software — which is why it belongs in the deployment doc as "what `LEDGER_SYNC=true` does *not* buy you on this hardware." |
| 3.2 | **`synchronous=OFF`.** No syncs at all; the OS may reorder journal and data writes, so a crash yields new pages with no valid rollback record. | `LEDGER_SYNC=false`. Same trade, same honesty required. |
| 4.1 | **Non-power-safe flash controllers.** A power cut mid wear-levelling remap can damage files **that were not even open** — a stray write to an unrelated file can corrupt an idle database. | The argument for verifying the whole ledger on open, not just the tail. |
| 5 | **Memory corruption in the host process** corrupts the file. Worse with `mmap`: a stray write into the mapping corrupts the file with no `write()` syscall. | If any store ever uses `:mmap`, this is the reason not to. |
| 7 | **Configuration errors** — `journal_mode=OFF`, changing `schema_version` with connections open, `writable_schema=ON`. | The boot-time refusal list for `LEDGER_DIR`/`KEY_DIR`/`KMS_KEY`. |
| 8 | **Bugs in SQLite itself** — including a WAL-mode write/checkpoint race present 3.7.0–3.51.2, false corruption after **database shrinkage**, and an off-by-one (`<` written as `<=`) in savepoint journals introduced 3.35.0 (2021-03-12) and fixed 3.37.2 (2022-01-06). | Nearly two years live in a codebase famous for 100% branch coverage. Coverage is not correctness. |

**ASSERT:** *Take the table above as a test plan. For each row, either the
mechanism is unreachable by construction (assert that structurally) or there is
a test that induces it and asserts the ledger still opens and answers
identically.* The highest-value four for this system: 1.2 (backup of a live
file), 1.4 (restore over existing state), 2.3 (two writers for one ledger), and
8 (shrinkage — because `Erasure` is the only thing here that makes a ledger's
readable content shrink).

#### H3. ext4 delayed allocation — rename persisted, the data did not
- **Vendor:** Linux / ext4 · **Date:** bug filed 2009-01-16; Ts'o's response 2009-03-12; fix in 2.6.30
- **URLs:** https://bugs.launchpad.net/ubuntu/+source/linux/+bug/317781 · https://thunk.org/tytso/blog/2009/03/12/delayed-allocation-and-the-zero-length-file-problem/ · https://lwn.net/Articles/323228/

**What happened.** After power loss on 2.6.28, config files written during the
previous boot came back **zero length** — "pretty much any file written to by
any application was 0 bytes." The universal atomic-update idiom is
`open(tmp); write(tmp); close(tmp); rename(tmp, real)`. Under ext3
`data=ordered`, every journal commit (≤5s) forced out the data blocks of inodes
in that transaction, so data landed before or with the rename — a guarantee
POSIX never made but which applications came to depend on. ext4's **delayed
allocation** does not allocate blocks until writeback, up to 30–60s later. The
rename is metadata and commits promptly; the data does not. A crash in that
window leaves a directory entry pointing at an inode with **no allocated
blocks** — and the old good copy is already unlinked.

**Root cause.** An application-level durability idiom that depended on an
implementation accident of one filesystem's journalling mode. Ts'o's position:
POSIX guarantees nothing without `fsync()`. The fix was **heuristics, not
semantics** — ext4 now forces allocation when a file is *replaced* (close after
`O_TRUNC`/`ftruncate`, and rename over an existing file), disableable with
`nodelalloc`. Note the heuristic covers **replace**, not **create**.

**Corroborating measurement — "All File Systems Are Not Created Equal"**
(Pillai et al., OSDI '14, https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai).
They found **60 crash vulnerabilities** across 11 applications including
LevelDB, SQLite, PostgreSQL, ZooKeeper, Git and Mercurial — 5 of them **silent**
(wrong data returned, no error), 25 leaving the application unable to open at
all. Exposed vulnerabilities by filesystem: ext4-ordered 17, **btrfs 31**. The
specific wrong assumptions worth stealing as a checklist: appends are
content-atomic; small overwrites are atomic; writes are ordered with respect to
a later `rename` of a *different* file; and — the one almost everyone gets wrong
— **an `fsync()` on a file does not persist its directory entry**. Six of the
seven applications with durability vulnerabilities needed an `fsync()` on the
parent **directory**. The paper also measures that the ext4 "safe rename"
heuristic fixes exactly **3** of the 60, and the `O_TRUNC` heuristic fixes
**none**.

**ASSERT:** *After creating a new file, the parent directory is fsynced before
the file is considered to exist. Test: create a segment, sync the file but not
the directory, crash, and assert the system detects the missing entry rather
than reporting a shorter history as correct.* **And:** *never depend on write/rename ordering — assert durability by crash-testing, not by reasoning about the filesystem.*

**HERE:** `Store.File` rolls over segments and `Backup` writes files; both create
new files whose *existence* must survive a crash. In Elixir the directory fsync
is not in the standard library and is therefore very likely missing — that alone
makes this worth a specific test. The `mix test --include crash` harness already
SIGKILLs a real process; extend it to assert on a filesystem that does not order
metadata generously (or with an intercepting store that drops un-synced
directory entries).

#### H4. SSDs under power fault — 13 of 15 devices misbehaved
- **Authors:** Zheng, Tucek, Qin, Lillibridge (Ohio State / HP Labs) · **Venue:** FAST '13, February 2013
- **URL:** https://www.usenix.org/system/files/conference/fast13/fast13-final80.pdf

**What happened.** A custom circuit cut power to the *device* independently of
the host, so no layer — OS, driver, HBA or SSD — could shut down cleanly.
Workload: concurrent 4 KB random writes with `O_SYNC` + `O_DIRECT`, raw device,
records carrying checksum, timestamp, intended block number and worker id.
15 SSDs (10 models, 5 vendors, 4 with power-loss protection) plus 2 HDDs;
**over 3,000 fault-injection cycles**.

**Results.** **13 of 15 SSDs misbehaved.** Bit corruption on 3 devices; **shorn
writes** on 3; **unserializable writes** on 8; metadata corruption on 1; and one
device (**SSD#1**) **stopped registering on the SAS bus entirely after 136 power
cycles**. SSD#3 lost roughly a third of its blocks to inaccessibility after just
**8** cycles. Shorn writes always broke on a **512-byte** boundary inside a 4 KB
record — evidence that FTLs use a 512-byte programming unit contrary to vendor
claims — and two of the three shorn-write drives were the most expensive,
nominally enterprise-class SLC devices. Serialization errors reached ~991 per
power fault on the worst device.

**Root cause.** FTL remapping tables live in a volatile write-back cache backed
by a supercapacitor that cost pressure keeps small; half-programmed MLC cells
exceed ECC correction; internal parallelism reorders acknowledged synchronous
writes; and corrupted FTL metadata is unrecoverable because there is no journal
above it.

**ASSERT:** *A record is validated against a checksum computed over its own
bytes, and a partially-written record is detected as such rather than parsed. A
test writes records, truncates the last one at every byte offset including
512-byte boundaries, and asserts replay stops cleanly at the last complete
record with the correct count.* **And:** *acknowledged writes may be reordered
by the device — so a fact's durability must not depend on the order two
independent files reached disk.*

**HERE:** `Backup`'s doctrine already says "a copy stops at the last complete
record" and `Store.File` replays by the same rule — this paper is the reason
that rule is correct, and the shorn-write result is the reason to test at
512-byte granularity specifically, not just at random offsets. The
**unserializable writes** finding is sharper and probably untested: if the
ledger's durability argument ever depends on "the segment was written before the
checkpoint that names it," the device is entitled to disagree. Assert that a
checkpoint referencing facts absent from the segments is detected and discarded
rather than trusted — the checkpoint is derived, so discarding it is free.

#### H5. Algolia — TRIM erasing the wrong blocks
- **Vendor:** Algolia · **Date:** published 2015-06-15, corrected 2015-07-17/18
- **URL:** https://www.algolia.com/blog/engineering/when-solid-state-drives-are-not-that-solid (2015 mirror: https://community.algolia.com/algoliasearch-jekyll-hyde/2015/06/15/when-solid-state-drives-are-not-that-solid/)

**What happened.** Search API servers began dropping into read-only filesystem
state, at first occasionally, then hourly. Files had **512-byte runs replaced
with zeros** — modification time unchanged, size unchanged; files under 512
bytes were fully zeroed. The constant 512-byte granularity was the tell: a block
being *erased*, not rotted. Disabling TRIM stopped it.

**Root cause.** Algolia's first writeup blamed the Samsung drives; the corrected
conclusion — after Samsung reproduced it from an Algolia-supplied reproducer —
is that the defect was **in the Linux kernel**, not the SSD. The md raid0/linear
bio-splitting code let split bios **share the source bio's `bi_io_vec`**. For a
discard, the SCSI/ATA layer stashes a pointer to the TRIM-range payload page in
`bio->bi_io_vec->bv_page`; because the vec was shared, that pointer got
overwritten, so the drive was handed a **wrong start address and length to
erase** and dutifully erased live blocks. When the bad range hit a superblock,
the filesystem went read-only.

**The detail that matters most.** After disabling TRIM, mmap'd small files that
were already zeroed **on disk** still read correctly **from page cache**, so
verification passed until reboot. They had to mass-reboot the fleet to discover
the damage. Also: Ubuntu 14.04 runs `fstrim` weekly from cron whether or not you
enabled `discard`.

**ASSERT:** *Integrity verification reads from the device, not from the cache. A
test verifies a ledger, drops caches (or restarts the VM and the OS page cache),
and verifies again, asserting identical results.* **And:** *silent zeroing is
detected — every record carries a checksum, so a run of zeros inside a record is
a checksum failure and not a valid record.*

**HERE:** Two concrete tests. (1) A `verify` operation over a ledger must
re-read from disk with `O_DIRECT`-equivalent semantics or after a cache drop —
otherwise it verifies the copy in RAM, which is exactly what fooled Algolia.
(2) Zero-filled regions must fail: if a fact's encoding permits an all-zeros
record to parse as valid (an empty answer, a zero-length field), then TRIM
damage looks like data. Assert that an all-zeros region of any length is
rejected by replay, and that a fact's checksum covers its length prefix.

#### H6. OpenZFS 2.2.0 — `SEEK_HOLE` reported a hole over dirty data
- **Vendor:** OpenZFS · **Date:** issue opened 2023-11-14, fixed in 2.2.2/2.1.14 released 2023-12-01
- **URL:** https://github.com/openzfs/zfs/issues/15526

**What happened.** Freshly built Go toolchain binaries came out mostly zeros.
`zpool status` and `scrub` reported **no errors**, because the zeros had been
written correctly — the checksums were valid over the wrong bytes.

**Root cause.** `dnode_is_dirty()` checked only `dn_dirty_link` (whether the
dnode was on a dirty list), not `dn_dirty_records` (uncommitted data records).
Appending dirties both as one logical unit but they are not synced atomically,
so mid-commit an object can look **clean while holding uncommitted data**.
`dmu_offset_next()` — the backend of `lseek(SEEK_HOLE/SEEK_DATA)` — therefore
reported a **hole where there was real data**, and any copier that trusts
hole-punching (coreutils ≥9.0 `cp`) wrote zeros. Correction to the popular
account: **block cloning was not the cause**; it only widened the window, and
the bug was present in 2.1.x and older.

**ASSERT:** *A copy is verified by reading back and comparing content, not by
trusting the copy mechanism's metadata. A test copies a ledger with every
available mechanism (streaming read, sparse-aware copy, object-store multipart)
and asserts byte-identity of the result.*

**HERE:** `Backup.Target.S3` uploads segment ranges. If it ever optimises with a
sparse-file or hole-aware read, this bug says the optimisation can silently
produce zeros that the checksums *of the copy* will happily confirm. The
assertion is that the backup's integrity check compares a digest computed from
the **source ledger's replayed facts** against one computed from the **restored**
ledger's replayed facts — never a digest of the file computed by the same code
path that wrote it. Verifying a copy against itself is what `scrub` was doing.

#### H7. MySQL/InnoDB — the binlog and the redo log disagreeing about what committed
- **Vendor:** MySQL / Oracle · **Dates:** Bug #75519 filed 2015-01-14 (still open); Bug #76795 fixed 5.6.26/5.7.8 and 5.6.28/5.7.10; Bug #70659 filed 2013-10-18, fixed 8.0.17
- **URLs:** https://bugs.mysql.com/bug.php?id=75519 · https://bugs.mysql.com/bug.php?id=76795 · https://jfg-mysql.blogspot.com/2018/10/consequences-sync-binlog-neq-1-part-1.html (Jean-François Gagné, 2018-10-30)

**What happened.** With binary logging on, a commit is a **two-phase commit
between two logs**: InnoDB writes a prepare record, the server writes the
transaction and its `Xid` to the binlog and flushes, then InnoDB commits. On
recovery the server scans the last binlog, commits the XIDs it finds, and rolls
back the rest — so the binlog is the arbiter. Three failure classes:

1. **Committed transactions rolled back (#75519).** When binlog is enabled,
   `innodb_flush_log_at_trx_commit=1` **does not actually flush the redo log at
   commit** — the flush moved into the prepare phase as part of group commit, on
   the theory that the binlog is the source of truth. So after a crash the
   transaction sits *prepared*; if `sync_binlog≠1` and the binlog never reached
   disk, recovery finds no XID and **rolls back a transaction the client was
   told had committed.**
2. **Binlog write/sync errors ignored (#76795).** The group-commit path did not
   check the return of `flush_cache_to_file()` / `sync_binlog_file()`, so a
   transaction committed in InnoDB while **never entering the binlog** — a
   silent master/replica divergence.
3. **Replica divergence (#70659).** With relaxed durability and GTID, a crashed
   replica either loses transactions (binlog ahead of InnoDB) or stops on
   duplicate keys (InnoDB ahead of binlog).

Gagné's conclusion, from walking the divergence: **"a master is not replication
crash safe for OS failures when `sync_binlog != 1`."** MariaDB 12.3 removes the
class entirely by reimplementing the binlog **inside** the InnoDB write-ahead
log — one log, one recovery, no cross-log 2PC.

**Root cause of the family.** **Two logs, each of which independently believes
it knows what committed**, joined by a two-phase protocol whose failure paths
were unchecked. The durability knob for one was silently disabled by enabling
the other.

**ASSERT:** *There is exactly one log that decides what committed. If a second
durable artefact exists, a test asserts it is strictly derived — deleting it
entirely and rebuilding must produce identical answers.*

**HERE:** MariaDB's fix *is* Lazy River's architecture, which is worth knowing
about: the ledger is the only log, and everything else — checkpoints, the backup
manifest, `Job.last_run`, the keyring's view of what is erased — is derived from
facts. The test that pins it: **delete every non-ledger artefact** (checkpoints,
caches, the backup's own bookkeeping) and assert every `{name, question}` answers
identically. Any artefact that fails that test has become a second log, and the
three MySQL bugs above are what happens next. The one genuine exception is the
key store, which is *not* derivable — and that asymmetry is exactly why the
README's tombstone reconciliation exists and why it deserves its own test.

---

### I. Backup, restore, and deletion — the copy that was not a copy

The pattern, ranked by frequency across these nine: **the backup shared a
failure domain with the primary** (same credential, same management network,
same building, same subscription, same script); **the backup's failure signal
was silent or discarded**; **the destructive operation had no soft-delete and no
confirmation of what type of thing was being destroyed**; **restore was designed
for one unit and the incident arrived at scale.**

#### I1. GitLab.com — five backup techniques, none working
- **Vendor:** GitLab · **Date:** 2017-01-31 (postmortem 2017-02-10)
- **URL:** https://about.gitlab.com/blog/2017/02/10/postmortem-of-database-outage-of-january-31/ (the live incident doc is now HTTP 410; its text is preserved at https://www.theregister.com/2017/02/01/gitlab_data_loss/)

**What happened.** Spam-driven load put replication far enough behind that the
WAL segments the secondary needed had already been removed from the primary, so
the secondary had to be rebuilt with `pg_basebackup`. At ~23:27 UTC, while
clearing the secondary's data directory, an engineer ran the wipe against the
**primary**. "The engineer terminated the process a second or two after noticing
their mistake, but at this point around 300 GB of data had already been
removed" — 4.5 GB remained.

**The five techniques, and exactly why each failed** — the live doc's own words:
*"So in other words, out of 5 backup/replication techniques deployed none are
working reliably or set up in the first place."*

1. **Nightly `pg_dump` to S3.** The job ran on a regular application server with
   no PostgreSQL data directory, so Omnibus's version detection (which selects
   9.6 only if `data/PG_VERSION` says so) **defaulted to `pg_dump` 9.2 against a
   9.6 database.** "A difference in major versions results in `pg_dump`
   producing an error, terminating the backup procedure" — failing silently.
   **"The S3 bucket was empty, and there was no recent backup to be found
   anywhere."** Generic backups were "producing files only a few bytes in size."
2. **Failure alerting.** Cron mailed its errors. "Unfortunately **DMARC was not
   enabled for the cronjob emails, resulting in them being rejected by the
   receiver**. This means we were never aware of the backups failing, until it
   was too late."
3. **Azure disk snapshots.** Enabled for the NFS servers but **not for any
   database server** — "as we assumed that our other backup procedures were
   sufficient enough." Cross-storage-account restores "can take hours if not
   days… in one such case it took over a week."
4. **LVM snapshots.** Built to refresh staging, not for DR — "the produced
   snapshots are not really meant to be used for disaster recovery." Two
   existed: a ~24h-old staging one and the engineer's manual ~6h-old one. The
   staging sync also **strips all webhooks**, so the surviving copy was
   incomplete.
5. **Streaming replication.** Intended "primarily for failover purposes and not
   for disaster recovery"; the procedure was "super fragile, prone to error,
   relies on a handful of random shell scripts, and is badly documented." At the
   moment of need it was already broken and both sides had been wiped.

**Lost.** Six hours of data — "at least 5000 projects, 5000 comments, and
roughly 700 users." Recovery took ~18 hours from the 6-hour-old snapshot,
bottlenecked on Azure disks throttled to ~60 Mbps.

**Root cause.** The `rm -rf` was the trigger. The defect was **unverified,
unowned backups whose failure signal was routed into a channel that discarded
it.** GitLab's own five-whys: *"Why was the backup procedure not tested on a
regular basis? — Because there was no ownership, as a result nobody was
responsible for testing this procedure."* Five mechanisms were configured; none
was exercised.

**ASSERT:** *A backup that has not been restored is not a backup. The test suite
restores from the real backup target into an empty environment and asserts
answer-identity — every run, not on a schedule.* **And:** *the size of the most
recent backup is asserted to be plausible relative to the ledger (a few-byte
backup fails).* **And:** *a backup failure is a fact in the ledger, not a
message on a channel that can silently reject it.*

**HERE:** The architecture is already the fix and it is unusually good — `Backup`
"records what it copied as ordinary facts, records a failure as an ordinary
fact, and is asked 'when did this last succeed' with `Job.last_run/2`." That
routes around GitLab's DMARC failure completely, because the alert is a query
rather than a delivery. What remains is to *assert* it: (a) fail the S3 target
and assert a failure fact is written and `Job.last_run` reflects it; (b) assert
`Vitals` reports unhealthy when the last successful backup is older than
`BACKUP_EVERY` by some margin; (c) assert a restored copy's byte size and fact
count are compared against the source, so the "few bytes" case cannot pass; and
(d) the version-mismatch lesson — assert a backup written by one schema version
is either readable by the next or refused loudly, never silently empty.

#### I2. Atlassian — 883 sites deleted, a two-week restore
- **Vendor:** Atlassian · **Date:** deletion 2022-04-05 07:38–08:01 UTC; PIR 2022-04-29
- **URLs:** https://www.atlassian.com/engineering/post-incident-review-april-2022-outage · https://www.atlassian.com/engineering/april-2022-outage-update

**What happened.** A script was run to delete a legacy standalone app from
customer sites. "The result was an immediate deletion of **883 sites
(representing 775 customers) between 07:38 UTC and 08:01 UTC**." First customers
restored 8 April; all restored 18 April — "The outage spanned **up to 14 days**."

**Root cause, three named defects.** (1) The script offered both "'mark for
deletion' capability used in normal day-to-day operations (where recoverability
is desirable)" and "the 'permanently delete' capability that is required…for
compliance reasons," and "was executed with the wrong execution mode and the
wrong list of IDs." (2) **The API accepted two different kinds of identifier
interchangeably**: "The API used to perform the deletion **accepted both site and
app identifiers and assumed the input was correct** — this meant that if a site
ID is passed, a site would be deleted; if an app ID was passed, an app would be
deleted. There was no warning signal to confirm the type of deletion being
requested." (3) Peer review "focused on which endpoint was being called and how.
It did not cross-check the provided cloud site IDs."

**Why the restore took weeks.** Atlassian could restore one site quickly and had
no bulk path back into the live multi-tenant estate. Restoration 1 (112 sites)
created **new cloudIds**, requiring "approximately 70 individual steps" and ~48
hours per batch. Restoration 2 (771 sites) reached ~12 hours per batch by
"re-using all of the old site identifiers," eliminating "over half of the steps."
Customer contact data had itself been deleted, so affected customers could not
file tickets. RPO was met — "no customer lost more than five minutes of data."

**ASSERT:** *A destructive operation refuses an identifier of the wrong type. A
test passes a ledger reference where a subject is expected, and vice versa, and
asserts a type error rather than a deletion.* **And:** *restore is bulk by
construction — a test restores N units in one operation and asserts the time is
sublinear in N, or at minimum that no per-unit manual step exists.*

**HERE:** The identifier-conflation defect is live here and cheap to close.
`Erasure` is scoped by **subject**; `Ledger`/`Backup` by **ledger name**; both
are "any term, not an atom" (per `Ledger`'s own doc), so a subject and a ledger
name are structurally indistinguishable — exactly Atlassian's site-ID/app-ID
problem. Wrap both in tagged structs or assert the type at every destructive
entry point, and test the cross-passing case in both directions. Second half:
`Erasure` destroys a key and is **irreversible by design**, which means it has
no soft-delete tier at all — so the Atlassian lesson lands as "the confirmation
must happen *before*, because there is no after." Assert `erase` requires an
explicit subject that already has a `subject` declaration (`erasable?/2` is the
right gate) and refuses otherwise.

#### I3. Google Cloud / UniSuper — a blank parameter that meant "delete in one year"
- **Vendor:** Google Cloud · **Customer:** UniSuper · **Date:** May 2024 (joint statement 2024-05-08; Google's writeup 2024-05-24)
- **URLs:** https://www.unisuper.com.au/about-us/media-centre/2024/a-joint-statement-from-unisuper-and-google-cloud · https://cloud.google.com/blog/products/infrastructure/details-of-google-cloud-gcve-incident

**What happened.** Google's words: "During the initial deployment of a Google
Cloud VMware Engine (GCVE) Private Cloud for the customer using an internal
tool, there was an **inadvertent misconfiguration…due to leaving a parameter
blank**. This had the unintended and then unknown consequence of defaulting the
customer's GCVE Private Cloud to a fixed term, with automatic deletion at the
end of that period… **the system assigned a then unknown default fixed 1 year
term value**." A year later the Private Cloud, its network and security
configuration, and its applications were deleted.

**Why redundancy did not help.** The joint statement: "UniSuper had duplication
in two geographies as a protection against outages and loss. However, **when the
deletion of UniSuper's Private Cloud subscription occurred, it caused deletion
across both of these geographies**." What saved them was out of band: "UniSuper
had backups in place with an additional service provider." UniSuper manages over
$135 billion for 647,000 members; disruption ran roughly two weeks.

**Root cause.** A provisioning input with an **unsafe, undocumented default that
encoded a destructive lifecycle**, plus a deletion blast radius spanning the
entire subscription — so geographic replication *inside the same subscription*
was not an independent failure domain.

**ASSERT:** *No configuration default is destructive. A test boots with every
optional setting omitted and asserts nothing schedules, expires, or deletes.*
**And:** *the backup target is in a different failure domain than the primary —
asserted by checking that the credentials, account, and provider used for backup
are not the ones used for the ledger, and refusing at boot if they are.*

**HERE:** Both halves are directly implementable. (1) `BACKUP_EVERY` defaults to
900 and `LEDGER_DIR` unset means in-memory — that second one is a *destructive
default* in exactly UniSuper's sense, and the README already says so ("right for
a test and wrong for everything else"). Make it a refusal in production rather
than a sentence in a README: assert the release refuses to boot in prod without
`LEDGER_DIR`, the way it already refuses without `SECRET_KEY_BASE`. (2) Assert
`BACKUP_ACCESS_KEY_ID` is not the same principal as anything the node uses for
its own storage or KMS, so a compromised or mistaken node credential cannot
reach the backups. UniSuper survived because one copy was outside the blast
radius; that is a boot-time check, not a hope.

#### I4. Salesforce Pardot — a script that granted Modify All Data, and poisoned the restore source
- **Vendor:** Salesforce · **Date:** 2019-05-17, 01:45 UTC → 2019-05-18 01:29 UTC (15h08m)
- **URL:** https://help.salesforce.com/s/issue?id=a028c00000qQ53kAAC (JS-rendered; the official 2019-05-24 update text is reproduced at https://salesforce.stackexchange.com/questions/262830/salesforce-bug-enabled-modify-all) · https://www.theregister.com/2019/05/17/salesforce_salesfarce_cloud_giant_in_multi_hour_meltdown_after_database_blunder_grants_users_access_to_all_data/

**What happened.** Salesforce's own update: "the deployment of an application
database script that was launched at 01:45 UTC… The script was only intended to
be applied to a subset of organizations that use Pardot. That change, however,
was **inadvertently applied to all users across Salesforce orgs that have, or
previously had a Pardot license**, giving those users elevated permissions."
In practice **Modify All Data** was set on every profile. To contain it,
Salesforce **blocked access to 100+ instances** across NA and EU production *and
sandbox*, taking down unrelated tenants sharing those instances.

**The restore problem — the part worth stealing.** The recommended recovery was
to redeploy Profiles and Permission Sets from a sandbox, but **the script had
hit sandboxes too**, so Salesforce had to publish a test for whether your own
backup was poisoned: "If your non-admin profiles are configured such that all of
the 'Standard Object Permissions' (Read, Create, Edit, Delete) are unchecked,
then the sandbox org was impacted and is not a valid source for recovery."

**Root cause.** A privileged data-plane script with **no tenant-scoping guard** —
the intended selector degraded from "a subset of Pardot orgs" to "every org that
ever held a Pardot license." The secondary defect is the severe one: the blast
radius **included the customers' own restore source**, so the documented recovery
mechanism was destroyed by the same event.

**ASSERT:** *A privileged operation's scope is asserted before it runs and
after: the test runs the operation with a selector expected to match K units and
asserts exactly K were touched, failing if the count differs — including when it
differs upward.* **And:** *the restore source is verified to predate the
incident before it is trusted — a restore asserts the backup's own contents
satisfy an invariant, not merely that the file exists.*

**HERE:** Grants here are facts in `$authority`, which is better than a mutable
permission table because "grant → revoke → grant works without any of them being
removed" — an over-broad grant is corrected by a later fact and the history
survives. Two tests. (1) `Authority.grant_checked/2` applied over a set must
touch exactly the intended set: assert the count and assert `$authority` itself
is refused (the moduledoc says it is refused structurally — prove it). (2) The
Salesforce restore lesson maps onto the keyring: a restored key store is
**not trusted**, it is "corrected" against erasure tombstones. Assert that
restoring a key store containing a key for an erased subject results in that key
being destroyed on open — that is a poisoned-backup check, and it is already the
design.

#### I5. Code Spaces — the attacker deleted the backups with the same console
- **Vendor:** Code Spaces (on AWS) · **Date:** 2014-06-17/18
- **URL:** codespaces.com is gone; the company's own statement is preserved verbatim at https://arstechnica.com/information-technology/2014/06/aws-console-breach-leads-to-demise-of-service-with-proven-backup-plan/

**What happened, in the company's words.** "An unauthorised person… had gained
access to our Amazon EC2 control panel… At this point we took action to take
control back of our panel by changing passwords, however **the intruder had
prepared for this and had already created a number of backup logins to the
panel** and upon seeing us make the attempted recovery of the account he
proceeded to randomly delete artifacts from the panel. We finally managed to get
our panel access back but not before he had **removed all EBS snapshots, S3
buckets, all AMI's, some EBS instances and several machine instances**. In
summary, **most of our data, backups, machine configurations and offsite backups
were either partially or completely deleted**." Within about twelve hours:
"Code Spaces will not be able to operate beyond this point." Its cached
marketing page had claimed "a full recovery plan that has been proven to work
and is, in fact, practiced."

**Root cause.** The "offsite" backups were **offsite in the storage sense, not
in the authorization sense** — snapshots, S3 copies and AMIs all lived inside
the same AWS account and were destroyable from the same console session. One
compromised control-plane credential, with no MFA, no separate backup account,
no delete protection and no immutability, was sufficient to destroy production
and every copy of it. Rotating credentials *during* the intrusion is what
triggered the destruction, because alternate logins already existed.

**Corroborating pattern.** CISA's #StopRansomware advisories name this
explicitly — RansomHub "affiliates removed backups for ransomware operations,"
with the mitigation stated as "Ensure all backup data is encrypted, **immutable
(i.e., cannot be altered or deleted)**"
(https://www.cisa.gov/news-events/cybersecurity-advisories/aa24-242a). The Akira
advisory is sharper still: initial access *through the backup product*, via
Veeam CVE-2023-27532, which exposes stored backup-infrastructure credentials —
the backup server being the credential store for everything it can restore
(https://www.cisa.gov/news-events/cybersecurity-advisories/aa24-109a).

**ASSERT:** *The credential the running system uses to write backups cannot
delete or overwrite them. A test authenticates with the node's backup credential
and asserts `DeleteObject` and overwrite of an existing key are both refused by
the target.*

**HERE:** This is a five-line test against `Backup.Target.S3` and it is worth
more than most of the rest of this document. The node needs `PutObject` only —
never `DeleteObject`, never `PutObject` over an existing key if the bucket has
object-lock or versioning. Assert it directly against the configured
`BACKUP_BUCKET` (in an integration test, alongside `--include gcp`). Second
assertion, from Code Spaces' most painful detail: the recovery path must not
require the compromised credential, so assert a restore works using a *different*
credential than the one in `BACKUP_ACCESS_KEY_ID`.

#### I6. OVHcloud SBG2 — three copies, one building
- **Vendor:** OVHcloud · **Date:** 2021-03-10, 00:47 CET
- **URLs:** https://corporate.ovhcloud.com/en/newsroom/news/informations-site-strasbourg/ · Octave Klaba's status thread, https://threadreaderapp.com/scrolly/1369478732247932929

**What happened.** "At 00:47 on Wednesday, March 10, 2021, a fire broke out…
By 4:09 am, the fire had destroyed SBG2." **14,046 servers** were destroyed;
Netcraft counted 3.6 million websites offline. Firefighting required cutting
power to all four Strasbourg datacentres.

**The data-loss half.** Klaba's thread enumerates backup state by product, and
the difference between surviving and not is exactly *site*, not rack or room:
"FTP Backup in SBG (Free/Paid) for VPS and Baremetal: **the datas are in RBX**.
You have full access." versus "Paid Backup VPS & PCI: 80% of the data are on pCS
in SBG… **20% of the data was on pCA which was in SBG2**," and "Free/Paid Backup
pCC in SBG1 was hosted in a separated room of SBG1. **Both rooms are
destroyed.**" Final tally for the paid backup product: "we have 18251 backups on
19486" — "there is small part, we don't have copies since the 3 copies were on
0.5% servers."

**Root cause.** The backup product's **default placement policy put copies
inside the same fire compartment, building, or campus as the primary**, so the
backup shared its single largest correlated failure mode with the thing it
backed up. Three-copy replication protected nothing when all three copies sat in
the destroyed rooms.

**ASSERT:** *The backup's failure domain is asserted, not assumed — a test
resolves the backup endpoint and refuses at boot if it is the same host, same
volume, or same region as `LEDGER_DIR`.*

**HERE:** `BACKUP_DIR` exists as an alternative to S3 — "a directory to copy
into instead — a second disk, or a test." The README is honest that it may be a
test, but nothing stops it pointing at a subdirectory of `LEDGER_DIR`, which is
OVH's SBG1-separate-room in miniature. Assert at boot: `BACKUP_DIR` must not be
inside `LEDGER_DIR`, must not be on the same device (compare `stat` device ids),
and if neither `BACKUP_BUCKET` nor a device-distinct `BACKUP_DIR` is set in
production, refuse. That refusal is three lines and it is the difference between
18,251 of 19,486 and all of them.

#### I7. Codefinger — ransomware using the platform's own encryption, key never stored
- **Reported by:** Halcyon · **Date:** 2025-01-13
- **URL:** https://www.halcyon.ai/blog/abusing-aws-native-services-ransomware-encrypting-s3-buckets-with-sse-c

**What happened.** A threat actor with **valid, compromised AWS credentials**
(only `s3:GetObject` and `s3:PutObject` needed) re-encrypts S3 objects using
**SSE-C** with an AES-256 key the attacker generates and keeps. Halcyon: "**AWS
processes the key during the encryption operation but does not store it.
Instead, only an HMAC is logged in AWS CloudTrail. This HMAC is not sufficient
to reconstruct the key or decrypt the data.**" The actor then sets a seven-day
deletion policy via the S3 Object Lifecycle API to pressure payment. No AWS
vulnerability is involved. The recommended control is an IAM `Condition`
**blocking SSE-C entirely** — forbidding the key from leaving the platform.

**The general principle, from the vendor docs.** AWS KMS: "Deleting an AWS KMS
key is destructive and potentially dangerous… **is irreversible**. After a KMS
key is deleted, you can no longer decrypt the data that was encrypted under that
KMS key, which means **that data becomes unrecoverable**"
(https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html), with
only a 7–30 day waiting period as a guardrail — and note the sharp edge AWS
calls out for asymmetric keys: "**without warning or error**, users can continue
to generate ciphertexts with the public key that cannot be decrypted after the
private key is deleted." Google Cloud KMS is equivalent: "**Permanent data
loss:** If you destroy a key that was used to encrypt data, that data becomes
unavailable," `DESTROYED` is terminal, and material is purged from backups within
45 days (https://cloud.google.com/kms/docs/destroy-restore).

**Root cause pattern.** **The key is a single point of failure with a shorter,
weaker retention policy than the data it protects.** Deleting a key is a
metadata-scale operation with a 7–30 day undo; the data it crypto-shreds may
have a seven-year retention requirement and no undo at all. Backups of the
ciphertext do not help.

**ASSERT:** *No principal can both write ciphertext and destroy the key that
opens it. A test asserts the node's KMS role has `encrypt`/`decrypt` but not
`destroy`, and that `destroy` is reachable only from the erasure path with an
explicit subject.* **And:** *a key destroyed for subject A leaves every other
subject readable — asserted over a population, and asserted again after a
restart, because the cache is not the guarantee.*

**HERE:** This is the incident that maps most exactly onto the erasure design,
and the design is the right one — three tiers, a single KMS key wrapping a
master, per-subject KEKs, per-fact data keys — precisely so that the irreversible
operation is small and scoped. The risks that remain are the ones the tests must
cover: (1) `KMS_KEY` itself being destroyed or its version disabled destroys
*everything*, so assert the node refuses to start rather than serving `:erased`
for the entire world (a silent total erasure is indistinguishable from a working
system that has no data). (2) The `KEY_DIR` local file must be treated as data
with the same retention as the ledger — the README's "must be persistent
storage" needs a test that a backup contains it, because `Backup` copies keys
"whole, every run" and that claim is exactly what Code Spaces and OVH would have
wanted checked. (3) Assert the local key store is unopenable without the KMS —
the README says "what lands in the bucket is unopenable by whoever owns the
bucket," which is the Codefinger threat model in reverse and deserves a direct
test: hand the backup bytes to a keyring with no `KMS_KEY` and assert nothing
decrypts.

---

### J. Growth, schedules, and the thing that got slowly worse

Failures that were correct on day one and became defects through accumulation —
the family a log-structured, append-only, never-deleting database is most
exposed to by construction.

#### J1. Sentry — transaction ID wraparound halted the database
- **Vendor:** Sentry · **Date:** outage 2015-07-20; postmortem 2015-07-23
- **URL:** https://blog.sentry.io/transaction-id-wraparound-in-postgres/

**What happened.** Sentry was down for most of a US working day. Postgres
assigns a 32-bit transaction ID to every transaction; when fewer than one
million remain before the counter wraps, **the database stops accepting
commands** — because reusing an XID would make past transactions appear to be in
the future, "leading to deleted rows reappearing, updated rows reverting to
previous states." Recovery required failing over to larger hardware, flushing
the event backlog, letting autovacuum complete, restarting in single-user mode,
and truncating a large mapping table.

**Root cause.** Not the counter — the **maintenance that was configured to run
too rarely for the write rate**. Sentry ran with `autovacuum_freeze_max_age` set
very high and only three autovacuum workers: "running with far too much delay in
vacuuming which meant lower load on the system, but more idle time in
maintenance." Their corrected settings tell the story:
`autovacuum_freeze_max_age = 500000000`, `autovacuum_max_workers = 6`,
`autovacuum_naptime = '15s'`, `autovacuum_vacuum_cost_delay = 0`,
`maintenance_work_mem = '10GB'`, `vacuum_freeze_min_age = 10000000`.

**ASSERT:** *Every monotonically-increasing counter has a stated maximum, and a
test asserts the system's behaviour at that maximum is a refusal with a repair —
not a wrap, not a crash. A property test drives the counter to its limit
directly rather than waiting.*

**HERE:** The snapshot's `tx` is exactly this counter, and it is in the caller's
hands (a snapshot name is "a plain map and a caller can write one by hand"). Two
tests: (1) assert `tx` is an Erlang integer (arbitrary precision, so no wrap) and
that nothing anywhere truncates it to 32 or 64 bits when it crosses the wire in
`Wire` or as JSON — JSON's 2^53 is a real ceiling for a JavaScript client and is
reachable by a busy ledger. (2) Assert a caller-supplied `tx` far in the future
is refused rather than silently clamped. Sentry's deeper lesson is the
maintenance one: whatever periodic work keeps the ledger fast (checkpointing,
compaction) must have a test that says *what happens when it falls behind*, and
the answer must be "slower," never "stops."

#### J2. Postgres subtransactions — the SLRU cliff at 64
- **Source:** Postgres.ai (Nikolay Samokhvalov) · **Date:** 2021-08-31
- **URL:** https://postgres.ai/blog/20210831-postgresql-subtransactions-considered-harmful

**What happened.** Four independent pathologies from a feature that looks free.
(1) Each `SAVEPOINT` consumes a **global XID**, so "if they all use 10
subtransactions, then XID is incremented by 10000 per second" — accelerating J1.
(2) `PGPROC_MAX_CACHED_SUBXIDS` defaults to **64** active subtransactions per
session; exceeding it causes "significant performance degradation" as lookups
fall through to `pg_subtrans`. (3) `SELECT … FOR UPDATE` plus subtransactions
triggers MultiXact overhead that becomes quadratic when several transactions
lock the same rows, with "latency [spiking] precipitously, and throughput
plummeting virtually to 0." (4) The `pg_subtrans` SLRU cache has only **32
buffers**; long-running primary transactions combined with subtransaction-heavy
updates degraded standby throughput "~20x during 5 minutes, from ~210k down to
~20k."

**Root cause.** A fixed-size cache in front of an unbounded structure, where
crossing the size produces a **cliff rather than a slope**, and where the
crossing point is determined by caller behaviour rather than by configuration.

**ASSERT:** *For every fixed-size cache, a test measures throughput just below
and just above its capacity and asserts the degradation is bounded — a cliff
larger than some factor is a failure, because it means the system's performance
is a step function of caller behaviour.*

**HERE:** `Keyring`'s unwrapped-data-key cache is precisely this shape. With a
fixed size and per-subject keys, a workload touching more subjects than the cache
holds turns every read into a KMS round trip — a 100×+ cliff, driven by a caller
choosing which entities to ask about. Test at cache size N and N+1 subjects and
assert the ratio. The same test applies to `Formula.Engine`'s memo and to any
open-file-handle cache in `Store.File`. This is also the honest place to record
the erasure trade-off the README names: the cache is "the window between erasing
and being unreadable," so its size is a security parameter as well as a
performance one, and both directions deserve an assertion.

#### J3. Roblox — 73 hours, and a 7.8 MB freelist rewritten per 16 kB write
- **Vendor:** Roblox · **Date:** 2021-10-28 13:37 PST → 2021-10-31 16:45 PST (73 hours); writeup January 2022
- **URL:** https://about.roblox.com/newsroom/2022/01/roblox-return-to-service-10-28-10-31-2021/

**What happened.** The day before the outage, Roblox enabled Consul's new
**streaming** feature and grew the cluster 50%. Consul KV write latency (p50)
went from under 300 ms to **2 seconds**, the cluster went unhealthy, and service
discovery — therefore everything — went down.

**Two stacked defects.** (1) Streaming is more efficient in aggregate but "used
**fewer concurrency control elements (Go channels)** in its implementation than
long polling," so under very high load its design "exacerbates the amount of
contention on a single Go channel" — the efficiency win concentrated coordination
onto one blocking point. (2) The real one: Consul persists its Raft log in
**BoltDB**, which keeps a **persistent on-disk freelist** of reusable pages. Under
a write-heavy, high-churn workload the freelist grew without bound *and was
rewritten in full on every append*: "for every log append… a **new 7.8MB
freelist was also being written out to disk even though the actual raw data
being appended was 16kB or less**." Measured state: a **4.2 GB log store
containing only 489 MB of actual data**, 3.8 GB free, and a freelist holding
"nearly a million free page ids." Roughly 500× write amplification, growing with
fragmentation.

**Root cause.** **An unbounded persistent structure whose rewrite cost is
proportional to accumulated fragmentation rather than to the data being
written** — a slow degradation invisible in normal operation, which an unrelated
change was merely enough to push over the edge.

**ASSERT:** *Write cost per fact is constant in the size of existing history. A
load test writes facts at 10⁴, 10⁶ and 10⁸ facts of accumulated history and
asserts bytes-written-per-fact and latency do not grow.*

**HERE:** The most important performance-shaped correctness test this system can
have, and one it is structurally well placed to pass: an append-only log with
range-named segments has no freelist, and `Backup`'s "the cost of a backup is
what changed, not what exists" is the same property stated for the copy path.
Both are claims. `mix test --include load` should assert (a) append cost is flat
in history size, (b) backup bytes transferred are proportional to facts written
since the last run and *not* to ledger size, and (c) checkpoint write cost does
not grow superlinearly. Roblox's deeper lesson is about the *interaction*: their
change was fine and the freelist was fine, and the incident was the product. So
run the load assertions with the maintenance jobs enabled, not on a quiet system.

#### J4. Kafka KIP-101 — truncating to the high watermark loses committed data
- **Vendor:** Apache Kafka · **URL:** https://cwiki.apache.org/confluence/display/KAFKA/KIP-101+-+Alter+Replication+Protocol+to+use+Leader+Epoch+rather+than+High+Watermark+for+Truncation (follow-ups: KIP-279 for remaining clean/unclean edge cases, KIP-320 for client-visible truncation detection)

**What happened.** Two scenarios. **(1)** A follower fetches message m2 from the
leader but has not yet received the round trip that advances its high watermark
past m2. On restart it "truncates its log to the high watermark it has
recorded"; if it becomes leader before catching up, m2 is permanently lost —
even though the leader had accepted it. **(2)** After both brokers crash and
restart with asynchronous flushing, they may hold **different message lineages
at the same offsets**; with compressed message sets, offset misalignment can
halt replication entirely.

**Root cause.** The high watermark is a **lagging, per-replica** value that says
"what I last knew was committed," and using it as a truncation point conflates
"not yet known committed" with "not committed." Without an identifier for
leadership periods, replicas cannot tell which messages belong to which leader's
tenure and therefore cannot detect divergence at all. The fix: followers ask the
leader for the truncation point using the **leader epoch**, and the leader
returns "the start offset of the first Leader Epoch larger than the Leader Epoch
passed in the request or the Log End Offset if the leader's current epoch is
equal."

**ASSERT:** *Truncation is decided by an authoritative comparison of lineage,
never by a locally-cached progress marker. A test gives two copies of the log
divergent suffixes at the same offset and asserts the system detects the
divergence rather than silently preferring one.*

**HERE:** Single-node removes leader election but not the shape. Two live
analogues. (1) `Store.File` replay truncates a torn tail — that decision is made
from a *local* marker (the last cleanly-scanning record), which is correct only
because there is exactly one writer. Assert that: exactly one process may open a
segment for append, and a second attempt is refused rather than truncating.
(2) `Backup` resumes "from that boundary" using a locally-remembered offset. If
the remote and the local ever disagree about what that boundary is — after a
partial upload, or a restore, or a clock change — resuming from the local marker
silently skips or duplicates a range. Assert that a backup resume validates the
remote's actual last byte against the local marker, and refuses on mismatch
rather than trusting the cheaper of the two. That is the leader-epoch fix in
miniature: ask the authority, do not use the cached progress value.

#### J5. Uber's Postgres 9.2 replication corruption — replicas that quietly disagreed
- **Vendor:** Uber Engineering · **Date:** 2016-07-26
- **URL:** https://www.uber.com/blog/postgres-to-mysql-migration/

**What happened.** Uber's list of Postgres complaints is contested on most
points, but one is an unambiguous, instructive defect. During a routine primary
promotion on Postgres 9.2: "Replicas followed timeline switches incorrectly,
causing some of them to misapply some WAL records. Because of this bug, some
records that should have been marked as inactive by the versioning mechanism
weren't actually marked inactive." Queries returned **duplicate rows**, and the
corruption pattern differed across replicas — so the replicas disagreed with each
other and with the primary, silently.

**Root cause.** A physical-replication bug at a **lineage switch** (the same
class as J4): the replica applied records from the wrong timeline and produced a
locally-consistent but globally-wrong state, with no checksum or comparison that
would ever notice. The wider structural complaint is fair and worth recording:
physical replication ships *every index update* over the wire and cannot cross
major versions, so upgrading required a full stop-and-rebuild.

**ASSERT:** *Two copies of the data that should be identical are actually
compared, on a schedule, by content — not by position, offset, or byte count.*

**HERE:** The backup and the ledger are exactly two copies that should agree.
Assert content-equality by replaying both and comparing the fact sequence, not
by comparing sizes or the last offset. This is the cheap, always-on version of
the restore test in G2, and it is the only thing that would catch a `Backup`
that has been faithfully copying corrupted bytes for a month.

---

### K. Deploy paths that reached everywhere at once

#### K1. Datadog — a systemd security patch severed container networking in five regions
- **Vendor:** Datadog · **Date:** 2023-03-08, 06:00 UTC onset; fully resolved 2023-03-10 06:25 UTC
- **URLs:** https://www.datadoghq.com/blog/2023-03-08-multiregion-infrastructure-connectivity-issue/ · https://www.datadoghq.com/blog/engineering/2023-03-08-deep-dive-into-platform-level-impact/

**What happened.** "Starting on March 8, 2023, at 06:03 UTC, we experienced an
outage that affected the **US1, EU1, US3, US4, and US5** Datadog regions across
all services" — regions on three different cloud providers with no network
connection between them. Mechanism: "a **security update to systemd was
automatically applied** to a number of VMs, which caused a latent adverse
interaction… to manifest **upon systemd-networkd restarting**. Namely,
`systemd-networkd` **forcibly deleted the routes managed by the Container
Network Interface (CNI) plugin (Cilium)**." systemd v248 had introduced flushing
of IP rules it does not recognise; installing the CVE patch restarts networkd;
on flush, the node lost the rule making traffic to its own IP local and went
entirely offline. **"More than 60 percent of our instances"** — tens of
thousands of nodes.

**Root cause.** "The base OS image we use to run Kubernetes had a **legacy
security update channel enabled**, which caused the update to apply
automatically," bypassing blue/green node replacement. "To compound the issue,
the time at which the automatic update happens is set by default in the OS to a
**window between 06:00 and 07:00 UTC**, thus it affected multiple regions at the
exact same time, even though the regions have no direct network connection or
coupling between them." A hidden global control surface with a default schedule
defeated regional isolation that was otherwise real.

**Two recovery amplifiers worth their own tests.** AWS Auto Scaling saw the
disconnected instances as unhealthy and **terminated thousands of them**: "We use
local disks on all providers, but instances on AWS were terminated, which means
we **lost all data stored on their local disks**." And Cilium's IP-deficit
reconciliation had "a bug that resulted in the entire rate limiter logic being
bypassed," so **more than 99% of `ec2:CreateNetworkInterface` calls were
rate-limited between 06:00 and 15:00 UTC**, stalling recovery.

**ASSERT:** *No component of the running system updates itself. A test asserts
the deployed image has no enabled automatic-update channel and no timer unit
that can restart a networking or storage service.* **And:** *a node that appears
unhealthy is never automatically destroyed while it holds the only copy of
data — a test asserts that the health-check-driven replacement path cannot run
against a node whose local disk has un-backed-up facts.*

**HERE:** Both land hard on a single-node system with local state. `LEDGER_DIR`
is a local disk, so Datadog's "instances on AWS were terminated… we lost all
data stored on their local disks" is the exact failure mode: an orchestrator that
replaces an unhealthy node destroys the ledger. Assert (a) the Dockerfile
produces an image with no auto-update path, (b) `Vitals` distinguishes "degraded
but holding data" from "safe to replace," and (c) the deployment refuses to
recycle a node whose last successful backup is older than its last write — which
is a query the system can already answer via `Job.last_run/2`. The house rule
"deploys reset in-flight work" plus this incident is the argument for making that
refusal automatic rather than remembered.

#### K2. GitHub — a 43-second partition, and 24 hours of writes on both sides
- **Vendor:** GitHub · **Date:** 2018-10-21 22:52 UTC → 2018-10-22 23:03 UTC (24h 11m)
- **URL:** https://github.blog/2018-10-30-oct21-post-incident-analysis/

**What happened.** Routine maintenance to replace failing optical equipment
caused "the loss of connectivity between our US East Coast network hub and our
primary US East Coast data center." Connectivity returned in **43 seconds** — but
in that window Orchestrator, GitHub's Raft-based MySQL failover manager, promoted
West Coast primaries. When connectivity restored at 22:54 UTC, applications began
writing to the West Coast, while the East Coast cluster held "a brief period of
writes that had not been replicated to the US West Coast facility."

**Root cause.** Automated failover triggered by a partition **shorter than the
time it takes to fail over safely**, with no fencing to stop the old primary
accepting writes. The result was unmergeable: "Because the database clusters in
both data centers now contained writes that were not present in the other data
center, we were unable to fail the primary back over to the US East Coast data
center safely." GitHub chose 24 hours of degradation over data loss —
"Guarding the confidentiality and integrity of user data is GitHub's highest
priority" — and recovered from backups taken **every four hours**, restoring
multiple terabytes from remote cloud storage, then reprocessing ~5 million queued
webhook events and 80,000 Pages builds.

**ASSERT:** *An automated failover requires the failure to persist longer than
the failover takes, and the demoted side is fenced before the new side accepts a
write. Test: induce a partition shorter than the failover threshold and assert
no failover occurs; induce a longer one and assert the old primary refuses writes
before the new one accepts any.*

**HERE:** Single-node means no failover — which is a *feature* worth pinning
with a test, because `lib/lazy_river/cluster.ex` exists and is where this
incident would arrive. Assert that no two nodes can ever own the same ledger for
write: if `Cluster` provides any handoff, assert the old owner refuses writes
before the new owner accepts one, and that a node rejoining after a partition
does not resume ownership it no longer holds. GitHub's four-hour backup interval
is the other lesson: their RPO was bounded by backup cadence, and here
`BACKUP_EVERY` defaults to 900 seconds — so the assertion is that data written in
the last `BACKUP_EVERY` window is recoverable *some other way*, or that the
window is documented as the RPO and tested as such by killing the node
mid-window and measuring exactly how much is lost.

---

### Index and count

**62 incidents**, all sourced to a URL with a date, across 11 root-cause
families. That is above the 30–45 target because the brief's own starting list
already exceeded it; nothing was included that could not be sourced, and four
candidates were dropped for want of a primary source (Joyent's 2015 Manta
wraparound postmortem — URL dead and not archived usefully; Reddit's 2023 Pi-Day
outage — reddit.com and redditinc.com both refuse fetching; Knight Capital 2012 —
the SEC order 403s; and the 2012 Reddit leap-second account, which exists only as
a WIRED interview and is cited only in support of D5).

| Family | Entries | The one sentence |
|---|---|---|
| **A. Durability** | 7 | The acknowledgement was issued by something other than the thing that made the data durable. |
| **B. Isolation & visibility** | 7 | A read observed a world that no longer existed, or never had. |
| **C. Tenancy** | 7 | The identity travelled separately from the data, and the two got out of step. |
| **D. Keys, certs, clocks** | 5 | Wall-clock expiry and automated key deletion defeat replication by construction. |
| **E. Deploy & config** | 6 | The deploy was clean; the trigger arrived later as input. |
| **F. Capacity & retries** | 4 | Retry without jittered backoff turns a blip into an outage, every decade. |
| **G. Dependency loops** | 5 | The repair path ran over the broken thing, or had never been run at all. |
| **H. Storage substrate** | 7 | The interface reported success for something that had not become durable. |
| **I. Backup & restore** | 7 | The copy shared a failure domain, or its failure signal was discarded. |
| **J. Growth & schedules** | 5 | Correct on day one; a defect by accumulation. |
| **K. Global deploy paths** | 2 | A hidden global control surface defeated isolation that was otherwise real. |

Two caveats on sourcing, carried openly. The **Azure AD** incidents (D1, and
SM79-F88 referenced in F/E discussion) were published to Microsoft's rolling
status-history page, which keeps no permanent per-incident URL; the quoted text
is verbatim Microsoft prose verified through mirrors. **Salesforce** (I4) and
**Code Spaces** (I5) likewise have no live vendor page — Salesforce's Known
Issue article is JavaScript-rendered and returns an empty shell to fetchers, and
codespaces.com no longer exists; both are quoted from verbatim reproductions of
the companies' own statements.

---

### The twelve that bear most directly on this system

Ordered by how much a passing test would be worth here, not by how famous the
incident is.

1. **H1 · PostgreSQL fsyncgate (2018)** — `LEDGER_SYNC=true` is a promise about
   `:file.sync`. Retrying a failed sync makes the system *believe* it is durable.
   Crash, do not retry; hold the fd open across write-and-sync.
2. **G2 · Cloudflare 2023-11-02** — "we had never tested fully taking the entire
   PDX-04 facility offline." Restore-into-empty must run in the suite, with
   answer-identity over named snapshots, for every feature.
3. **I1 · GitLab 2017-01-31** — five backup mechanisms, none exercised, failure
   mail rejected by DMARC. `Backup` already records failures as facts; assert
   that, assert plausible backup size, assert `Vitals` goes unhealthy on staleness.
4. **C1 · OpenAI 2023-03-20** — a cancelled request left a pooled connection
   holding someone else's response. Assert every value from a shared resource
   carries and re-checks the identity it was fetched for — `Keyring`'s data-key
   cache above all.
5. **D4 · Let's Encrypt CAA rechecking (2020)** — N domains, one checked N times.
   `Snapshot.open/1` takes a *list* of ledgers. Test mixed-permission lists in
   several orderings, with duplicates.
6. **I7 · Codefinger / KMS irreversibility (2025)** — the key has a shorter,
   weaker retention policy than the data. No principal may both write ciphertext
   and destroy the key; erasing A must leave B readable, asserted after restart.
7. **B5 · Jepsen Dgraph 1.1.1 (2020)** — a *routine* maintenance operation broke
   the transactional guarantee, and skewed reads got written back permanently.
   Run the consistency checker concurrently with checkpointing, rollover, backup
   and key rotation.
8. **I5 · Code Spaces (2014)** — offsite in storage, not in authorization. The
   node's backup credential must not be able to delete or overwrite; the restore
   must work with a *different* credential.
9. **A5 · Jepsen MongoDB 4.2.6 (2020)** — non-idempotent retry of an
   already-committed transaction, duplicating effects. `Job.Runner`'s in-flight
   set must survive a runner restart, and a reconnecting websocket must not
   replay a write into a second append.
10. **E1 · Cloudflare 2025-11-18** — a derived artefact outgrew a hardcoded bound
    and the consumer `unwrap`ped. Checkpoints and formula outputs must be
    validated at generation and fail *soft*: reject the artefact, keep answering.
11. **I2 · Atlassian 2022-04-05** — an API that accepted site IDs and app IDs
    interchangeably. A subject and a ledger name are both "any term" here; make
    them distinguishable and test cross-passing in both directions.
12. **J3 · Roblox 2021-10-28** — 7.8 MB of freelist rewritten per 16 kB append.
    Assert append cost and backup bytes are flat in accumulated history, with
    maintenance jobs running, at 10⁶ and 10⁸ facts.

**Honourable mention, because it is the cheapest test in the document:**
**C6 · Azure AutoWarp (2022)** — compile a WASM module that imports *anything*
and assert `Formula.Sandbox.mapping/3` refuses it with a repair. The fence is
structural, which means a regression would be silent, which is exactly why it
needs an assertion.

---
