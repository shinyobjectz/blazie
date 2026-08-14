defmodule Blazie.Run do
  @moduledoc """
  One execution of the loop, and the trajectory it leaves behind (run).

  `Model.converse/5` already writes every turn under an id when given `into:`
  and `by:`. This is that id treated as a thing: something that can be resumed,
  forked and asked questions of, rather than a diary nobody reads back.

  ## Resuming is reading, not restoring

  There is no session store, no serialised context and nothing to rehydrate. A
  run's turns are facts in a world, ordered by the transaction that wrote them,
  so continuing one is a query — `messages/2` reads them back into exactly the
  shape `converse/5` takes as a prompt. A cluster that restarts mid-run loses
  the process and not the run, because the process was never where the run was.

  That is the whole of "a run survives a deploy", and it is why it needs no
  machinery: this repo already knows how to not lose facts.

  With one condition worth saying out loud, because measuring it is what turned
  it up: the world has to be one that survives. `World.default_store/0` answers
  `Store.Memory` unless `:ledger_dir` is set, and a run in a memory world dies
  with the node exactly as everything else in it does. Run twice in two VMs
  without it and nothing comes back — which is not a defect in a run, and is
  indistinguishable from one if nobody says so first.

  ## Forking is free, and both branches stay true

  A fork opens the parent's snapshot at a transaction and continues under a new
  id. Nothing is copied and nothing is overwritten, so the parent still answers
  what it always answered — the two branches are not two versions of one run,
  they are two runs that share a beginning.

  Prime Intellect's harness does this by moving a leaf pointer in an append-only
  JSONL file, which is the same idea reached by building a file format. Here the
  database already is one.

  ## Compaction adds, it does not replace

  A long run's early turns get summarised so the context stays affordable. The
  summary is a NEW fact; the turns it summarises are untouched and still
  readable. Compaction that deleted what it summarised would be the one
  irreversible operation in a database whose whole claim is that corrections are
  later facts — and the summary is generated, so it is exactly the kind of thing
  somebody will later want to check against the original.
  """

  alias Blazie.{Attribute, Snapshot, World}

  @is "is"

  @doc "The attributes a run is written with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("began", answers: "integer") ++
      Attribute.define("ended", answers: "integer") ++
      Attribute.define("forked_from", answers: "name") ++
      Attribute.define("forked_at", answers: "any") ++
      Attribute.define("summary", answers: "any", cardinality: "many") ++
      Attribute.define("summarised_to", answers: "integer")
  end

  @doc """
  Start a run.

  Nothing else has to happen for turns to land under it — `converse/5` writes
  them wherever it is told. This records that the run BEGAN, which is what makes
  "a run that never got anywhere" distinguishable from "a run that never was".
  """
  @spec begin(World.ref(), term(), integer()) :: {:ok, pos_integer()} | {:error, term()}
  def begin(world, id, now \\ System.system_time(:second)) do
    World.append(world, [{id, @is, "run", id}, {id, "began", now, id}])
  end

  @doc "Mark a run finished. A run with no `ended` is one that stopped rather than ended."
  @spec finish(World.ref(), term(), integer()) :: {:ok, pos_integer()} | {:error, term()}
  def finish(world, id, now \\ System.system_time(:second)) do
    World.append(world, [{id, "ended", now, id}])
  end

  @doc """
  The turns of a run, oldest first.

  Read from the facts rather than from anything held in memory, which is what
  makes this survive the process that wrote them.
  """
  @spec turns(Snapshot.t(), term()) :: [%{asked: String.t(), answered: String.t()}]
  def turns(%Snapshot{} = snapshot, id) do
    asked = ordered(snapshot, id, "asked")
    answered = ordered(snapshot, id, "answered")

    # Zipped by position: a turn is one ask and the answer that followed it, and
    # they are written in the same transaction, so the nth of each belong
    # together. A turn whose answer is missing is one that failed mid-flight and
    # is dropped rather than paired with somebody else's answer.
    Enum.zip_with(asked, answered, fn one, two -> %{asked: one, answered: two} end)
  end

  defp ordered(snapshot, id, attribute) do
    snapshot
    |> Snapshot.find(id: id, attribute: attribute)
    |> Enum.map(& &1.value)
  end

  @doc """
  A run's turns as messages, ready to hand back to `converse/5`.

  `converse/5` takes either a prompt or a list of messages, so resuming is
  passing this where the prompt would go. Compacted turns come back as their
  summary instead, which is the whole point of having compacted them.
  """
  @spec messages(Snapshot.t(), term()) :: [map()]
  def messages(%Snapshot{} = snapshot, id) do
    kept = Snapshot.value(snapshot, id, "summarised_to") || 0

    summaries =
      case ordered(snapshot, id, "summary") do
        [] -> []
        said -> [%{"role" => "user", "content" => "Earlier: " <> Enum.join(said, " ")}]
      end

    turned =
      snapshot
      |> turns(id)
      |> Enum.drop(kept)
      |> Enum.flat_map(fn turn ->
        [
          %{"role" => "user", "content" => to_string(turn.asked)},
          %{"role" => "assistant", "content" => to_string(turn.answered)}
        ]
      end)

    summaries ++ turned
  end

  @doc """
  Continue a run under a new id, from where it had got to.

  The child records what it came from and at which name, so "where did this
  branch diverge" is a query rather than something somebody has to remember.
  Nothing is copied: the child reads the parent's turns through the snapshot it
  was forked at, and the parent goes on answering what it always answered.
  """
  @spec fork(World.ref(), term(), term(), Snapshot.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def fork(world, child, parent, %Snapshot{} = snapshot) do
    World.append(world, [
      {child, @is, "run", child},
      {child, "began", System.system_time(:second), child},
      {child, "forked_from", to_string(parent), child},
      {child, "forked_at", Snapshot.name(snapshot), child}
    ])
  end

  @doc """
  Summarise the first `count` turns of a run, keeping them.

  The summary is written and the turns are not touched. `messages/2` then skips
  what was summarised and leads with the summary instead, so the context shrinks
  and the record does not.
  """
  @spec compact(World.ref(), term(), non_neg_integer(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def compact(world, id, count, summary) do
    World.append(world, [
      {id, "summary", summary, id},
      {id, "summarised_to", count, id}
    ])
  end

  @doc "Every run in this snapshot, by id."
  @spec all(Snapshot.t()) :: [term()]
  def all(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find(attribute: @is, value: "run")
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end
end
