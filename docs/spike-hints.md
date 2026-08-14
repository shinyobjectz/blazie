# Spike verdict: Hints on blazie

*2026-08-14 · the Phase 1 gate (bla-c3c2) · code in `test/spike_hints_test.exs`,
driven end to end through the Elixir SDK over a real listener.*

Nexus Hints was chosen as the proven site because it is small and exercises
four things at once: tenancy, a job, idempotency, and the wire. The contract
under test, in Nexus's own words: webhooks may only make a sweep run
*sooner* — polling is the backbone, so unplugging every webhook loses latency
and nothing else. Around it: redelivery collides harmlessly, and cursors
advance only after writes land.

## What was easier than expected

**The headline: sooner-on-hint is not implemented anywhere.** The sweep is a
job with a cadence. The job *reads* the hints (`each { delivery = true }`).
Blazie's dependency graph is observed, not declared — a job is due when
something it read has changed — so a hint landing makes the sweep due *now*,
3,590 seconds before its cadence, and the sweep's own writes do not wake it.
Nexus built this with Oban triggers and a hints table; here the entire
contract fell out of declaring the work honestly. The spike's third test
asserts it tick by tick.

**Cursor-after-write arrived strengthened.** A job's staged writes land as
one transaction, so the swept marks, the cursor, and the bookkeeping are
atomic — the test asserts every `swept` fact shares the cursor's `tx`. Nexus
maintains this ordering by discipline; here it cannot be otherwise.

**Idempotency is a read in the same chunk as the write.** No dedup table, no
unique index: the ingest chunk probes for the delivery id and stages nothing
when it finds one — redelivery answers `wrote: 0`. In an append-only world,
"insert if absent" is exactly this, and the probe and the write land
atomically or not at all.

**Tenancy needed no code.** Two orgs are two worlds; the second org's world
has never heard of the first's hints. Zero came back because there is no
cross-world query to scope, not because a filter ran.

**Self-declaring vocabulary carried the whole spike.** No attribute was
defined by hand for hints — the first write declared `delivery`, `platform`,
`swept`, `swept_total`, and the definitions rode in the same transaction as
the data.

## What fought back

**Reading a field nobody has written is a refusal.** First-run code cannot
ask `h.swept == nil` — `swept` is not vocabulary yet. The idiom that works
is probing with `each { swept = true }`, which is simply empty. Correct on
blazie's own terms (an unknown field is a likely typo and the refusal says
so), but every first-run job will hit it. Worth either a documented idiom or
a presence-tolerant read.

**A multi-line Lua source cannot be written as a fact value through the
SDK.** Declaring the sweep job means writing its source as a value, and a
Lua source quoted inside a Lua chunk is quoting gymnastics that does not
survive. The spike fell back to a local `World.append`. The SDK wants an
assertion-level verb (write these facts, checked) beside `run` — the wire
already supports everything needed; only the client verb is missing.

**No arguments to a chunk.** Ingest interpolates the delivery id into the
source string. Fine for a spike, wrong shape for production — interpolation
into code is how injection happens. A `run(source, args: %{...})` that binds
an `args` table inside the chunk closes it.

**A chunk reads its snapshot, not its own staged writes.** `x.f = 1 return
x.f` answers what was true *before*. Every SDK consumer will trip on this
exactly once; the client docs now say it, and both client test suites encode
it.

## Verdict

**Proceed.** The subsystem's essential behaviour cost ~30 lines of Lua and
zero new blazie code, and the two properties Nexus enforces by discipline
(sooner-on-hint, cursor-with-results) are structural here. The three SDK
gaps found — an assertion verb, chunk arguments, and the first-run read
idiom — are ticket-sized, not design flaws, and none blocks Phase 2.

**Honestly out of scope in this spike:** it ran against a real node and a
real wire, but not against a provisioned UpCloud cluster — opening one
spends money, which is the owner's call, and the provisioning path has its
own end-to-end ticket (bla-gmfh). Nothing in the spike depends on where the
node runs.
