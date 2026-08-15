# Continual learning on the substrate — the Polkm/learn sketch

*2026-08-15. An idea captured with its reasoning, not yet boarded. Origin:
[Polkm/learn](https://github.com/Polkm/learn) — a pure-Lua neural net library
(MIT, ~6 files, zero dependencies, no FFI: audited) whose per-sample SGD loop
has the same TYPE as a fact log's delivery of the world: one example at a time.
Online SGD is continual learning in its simplest honest form, and blazie's
primitives already supply everything around it.*

## The mapping (each learn concept lands on an existing primitive)

| learning concept | blazie primitive |
|---|---|
| training example | a fact (features via formulas — extraction is formula-shaped) |
| the dataset | the training job's READ-SET — versioned by observation, not by memo |
| model checkpoint | a blob + a reference fact (version, parent ref, hyperparams, metrics) |
| provenance | `by` on the checkpoint fact: this run, over this read-set — lineage queryable to init |
| retraining trigger | read-set staleness — the reactive job re-fires; warm-start from parent checkpoint, SGD over the NEW facts |
| promotion gate | a Judge law: candidate must beat/hold the champion on eval facts, including OLD slices (catastrophic forgetting as policy); verdicts are facts |
| inference | a forward pass — pure; small models could run in formulas |

No scheduler, no pipeline orchestrator, no MLOps sidecar — the no-sidecars
rule would refuse one, and read-set reactivity makes it unnecessary.

## The honest ceiling

Luerl's immutable tables make the inner `dot` loop slow. The SHAPE
(facts → job → checkpoint blob → Judge verdict) is substrate-level and
permanent; the inner loop can migrate to a host-side Model-provider seam or
a Rustler NIF without changing a concept (the wasm lane is being removed —
see the Lua runtime track in storage-plan.md). learn-on-Luerl is the
reference implementation and proof of shape, not the production trainer.

## Phases (smallest first; Phase 0 gates all)

0. **Spike**: vendor learn's six files (repackage: proper module returns, no
   globals — it uses a global `learn` table and slash-path requires), train
   XOR inside a sandboxed guest. Verdict: correctness under Luerl + a
   wall-clock number. Days, not weeks.
1. **Checkpoints**: serialization (plain tables → JSON → `blob()`), the
   reference-fact shape, provenance read-back.
2. **The reactive trainer**: read-set as dataset, warm-start on staleness.
   This is the phase that makes it *continual*.
3. **Judge gating**: executed eval metrics (never typed — Dossier discipline
   applies to model metrics), promotion law with old-slice retention,
   champion/challenger as facts.
4. **The escape hatch** (only if timings demand): inner loop behind the
   Model-provider seam or in the wasm lane; the Lua stays as executable spec.

## Sidecar findings from the same survey (kept so they aren't re-litigated)

- **busted**: the BDD *style* transfers, the package does not (C-module deps).
  A ~100-line pure-Lua describe/it/assert core could become tenant-authored
  tests for authored jobs — run against staged fixture facts (the fence works
  for tests as for Dossiers), results as facts, a Judge law gating deployment
  on green. Design reference, not dependency.
- **Rejected outright**: Turbo.lua (LuaJIT-FFI; async networking is the
  BEAM's job), lsqlite3 (a guest with a DB handle voids the fence — SQLite
  belongs to the host's Store), luafilesystem (guests have no filesystem on
  purpose), luasql (external data enters through granted capabilities and
  becomes facts, never a guest DB socket).
- Vocabulary: `onto-check` before naming (checkpoint/champion/trainer smell
  like existing words or mere attributes of fact/job/blob/verdict).
