defmodule Blazie.Spend do
  @moduledoc """
  What a run cost, and whether it was allowed to.

  Tokens are facts, like every other reading here — `fuel_spent` set the shape.
  So "what did this agent cost last month" is a query over old facts rather than
  a metrics system that had to be kept in step, and the answer at an old
  snapshot name is still the answer.

  ## There is no budget here, deliberately

  This records and does not refuse. A run is stopped by a REQUIREMENT it cannot
  satisfy, never by a ceiling on what it cost — an answer that is right is worth
  having whatever it took, and one that is wrong is not made acceptable by being
  cheap. A token budget decides on the one axis that says nothing about whether
  the work was any good.

  So this is telemetry. "What did this agent cost last month" is a query over
  facts; what it may do is decided by `Attribute.unmet/2`.

  ## Not reported is not zero

  A provider that says nothing about usage reports zero here, and that is a real
  limitation stated plainly rather than papered over. A budget built on a guess
  refuses the wrong runs, which is worse than one that occasionally lets a run
  through uncounted.
  """

  alias Blazie.{Attribute, Snapshot}

  @doc "The attributes spending is recorded with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("tokens_in", answers: "integer", cardinality: "many") ++
      Attribute.define("tokens_out", answers: "integer", cardinality: "many") ++
      Attribute.define("model", answers: "name", cardinality: "many")
  end

  @doc "The facts recording one run's spend."
  @spec of(term(), %{in: non_neg_integer(), out: non_neg_integer()}, term()) :: [tuple()]
  def of(id, %{in: went_in, out: came_out}, by) do
    [{id, "tokens_in", went_in, by}, {id, "tokens_out", came_out, by}]
  end

  @doc """
  The same, naming the model that spent it.

  `model` was in `seed/0` from the start and nothing ever wrote it, so "what did
  gpt-4o-mini cost us" was a question the vocabulary could ask and the data
  could not answer. A declared attribute nobody writes is the same defect as a
  declared shape nobody checks.
  """
  @spec of(term(), %{in: non_neg_integer(), out: non_neg_integer()}, term(), String.t()) ::
          [tuple()]
  def of(id, spent, by, model) when is_binary(model) do
    of(id, spent, by) ++ [{id, "model", model, by}]
  end

  @doc """
  Everything one id has spent, ever.

  Summed from the facts rather than kept as a counter. A counter is a second
  account of something the history already holds, and the two disagree the first
  time one of them is written and the other is not.
  """
  @spec so_far(Snapshot.t(), term()) :: %{in: non_neg_integer(), out: non_neg_integer()}
  def so_far(%Snapshot{} = snapshot, id) do
    %{in: total(snapshot, id, "tokens_in"), out: total(snapshot, id, "tokens_out")}
  end

  # Every reading, not the latest — `cardinality: "many"` means each run's spend
  # is its own fact, and summing them is what makes the history the account.
  defp total(snapshot, id, attribute) do
    snapshot
    |> Snapshot.find(id: id, attribute: attribute)
    |> Enum.map(& &1.value)
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end
end
