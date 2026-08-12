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

  Built so far: `LazyRiver.Fact`, `LazyRiver.Ledger`, `LazyRiver.Snapshot`,
  `LazyRiver.Formula`. Still to come: `job`, and `symbol` once there is
  something worth embedding.
  """
end
