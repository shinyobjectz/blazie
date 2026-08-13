defmodule Blazie.Spend do
  @moduledoc """
  What a run cost, and whether it was allowed to.

  Tokens are facts, like every other reading here — `fuel_spent` set the shape.
  So "what did this agent cost last month" is a query over old facts rather than
  a metrics system that had to be kept in step, and the answer at an old
  snapshot name is still the answer.

  ## A budget is an attribute

      {"severity", "budget", 100000}

  Checked before a run rather than after, because after is a bill. A refused run
  writes why it was refused, so an agent that went quiet is distinguishable from
  one that stopped itself — those look identical from outside and mean opposite
  things.

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
      Attribute.define("budget", answers: "integer") ++
      Attribute.define("refused", answers: "any", cardinality: "many")
  end

  @doc "The facts recording one run's spend."
  @spec of(term(), %{in: non_neg_integer(), out: non_neg_integer()}, term()) :: [tuple()]
  def of(id, %{in: went_in, out: came_out}, by) do
    [{id, "tokens_in", went_in, by}, {id, "tokens_out", came_out, by}]
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

  @doc """
  May this run happen?

  `:ok`, or a refusal saying what was spent against what was allowed. Asked
  before the call — after is a bill.
  """
  @spec allowed?(Snapshot.t(), term()) :: :ok | {:error, map()}
  def allowed?(%Snapshot{} = snapshot, id) do
    case Snapshot.value(snapshot, id, "budget") do
      budget when is_integer(budget) ->
        spent = so_far(snapshot, id)
        used = spent.in + spent.out

        if used >= budget do
          {:error,
           %{
             problem: :over_budget,
             repair:
               "#{inspect(id)} has spent #{used} tokens against a budget of #{budget}. " <>
                 "Raise `budget` or let it stand — this is the limit working."
           }}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  @doc "The fact recording that a run was refused, and why."
  @spec refused(term(), map(), term()) :: [tuple()]
  def refused(id, refusal, by), do: [{id, "refused", refusal.repair, by}]

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
