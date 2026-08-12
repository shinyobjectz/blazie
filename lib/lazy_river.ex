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

  Storage is in memory and the ledger is the seam that hides it. There is no
  sandbox yet, so doctrine 14's boundary is a shape rather than a fence.
  """
end
