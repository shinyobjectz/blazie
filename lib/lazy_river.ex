defmodule LazyRiver do
  @moduledoc """
  Seven words: fact, attribute, ledger, snapshot, formula, symbol, job.

  Facts accumulate in ledgers. A snapshot is one or more ledgers read at a
  transaction, and it is a value — the answer at a named snapshot is the same
  answer forever. Formulas declare facts that follow from facts and say what,
  never when. Jobs are the only thing that reaches the outside world, and the
  only thing a schedule can attach to.

  The vocabulary lives in `.monty/ontology.db` and is enforced by `just check`.
  Engineering that is deliberately not vocabulary lives in `docs/stack.md`.

  All seven exist, one module each: `LazyRiver.Fact`, `LazyRiver.Attribute`,
  `LazyRiver.Ledger`, `LazyRiver.Snapshot`, `LazyRiver.Formula`,
  `LazyRiver.Symbol`, `LazyRiver.Job`.

  Around them, and deliberately not vocabulary: a `Store` behind the ledger
  seam with checkpointing, sort orders and resident bounds inside the ledger, a
  `Surface` of four operations with an `Authority` deciding which ledgers a
  caller may name, a `Job.Runner`, `Subscription`, `Formula.Engine`,
  `Formula.Sandbox` for code we do not trust, `Erasure` with its `Keyring`,
  `Cluster` for one-ledger-one-owner, and `Vitals`.

  ## What is not true yet, in one place

  The keyring is in memory, so a restart erases everything by accident — the
  one piece here that must not ship as it stands. Distribution is claimed
  against but not implemented. And a fact written before its subject was
  declared can never be erased, which is a property of the design rather than a
  gap: subject is decided at write time or not at all.
  """
end
