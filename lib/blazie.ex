defmodule Blazie do
  @moduledoc """
  Seven words: fact, attribute, world, snapshot, formula, symbol, job.

  Facts accumulate in ledgers. A snapshot is one or more ledgers read at a
  transaction, and it is a value — the answer at a named snapshot is the same
  answer forever. Formulas declare facts that follow from facts and say what,
  never when. Jobs are the only thing that reaches the outside world, and the
  only thing a schedule can attach to.

  The vocabulary lives in `.monty/ontology.db` and is enforced by `just check`.
  Engineering that is deliberately not vocabulary lives in the commit that
  introduced it — there are no documents here, because a document describing
  the system is a second source that drifts.

  All seven exist, one module each: `Blazie.Fact`, `Blazie.Attribute`,
  `Blazie.World`, `Blazie.Snapshot`, `Blazie.Formula`,
  `Blazie.Symbol`, `Blazie.Job`.

  Around them, and deliberately not vocabulary: a `Store` behind the world
  seam with checkpointing, sort orders and resident bounds inside the world, a
  `Surface` of four operations with an `Authority` deciding which ledgers a
  caller may name, a `Job.Runner`, `Subscription`, `Formula.Engine`,
  `Formula.Sandbox` for code we do not trust, `Erasure` with its `Keyring`,
  `Cluster` for one-world-one-owner, and `Vitals`.

  ## What is not true yet, in one place

  Distribution is claimed against but not implemented — one node, and
  `Cluster.distributed?/0` says so. A fact written before its subject was
  declared can never be erased, which is a property of the design rather than a
  gap: subject is decided at write time or not at all.

  Erasure itself is finished: a tombstone in the world, reconciled against
  whenever the keyring opens, so a key store restored from before an erasure is
  corrected rather than trusted. What it needs from an operator is that
  `KEY_DIR` points at persistent storage — the release warns when it is unset,
  because keys on an ephemeral disk erase everybody on redeploy.
  """
end
