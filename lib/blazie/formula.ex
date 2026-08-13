defmodule Blazie.Formula do
  @moduledoc """
  A fact declaring facts that follow from facts that already exist (`fml`).

  A formula says what, never when. It neither validates nor triggers — it
  produces facts, and every fact it produced names it, so invalidation is a
  question and provenance is a column.

  It carries no schedule, no order and no dependency list. The dependency list
  is not written because it is *observed*: running a formula records what it
  read, and a later fact falling inside that read set is what makes the answer
  stale. So the graph is the closure of facts naming what made them, and what
  ran cannot diverge from what was declared.

  A formula never says how it is evaluated. This one re-executes, which is
  enough for an application; an incremental evaluator would slot in underneath
  without any formula changing.

      doubled = Formula.new(:doubled, fn snapshot ->
        for fact <- Snapshot.find(snapshot, attribute: :height) do
          {fact.id, :double_height, fact.value * 2}
        end
      end)

      {assertions, reads} = Formula.run(doubled, snapshot)
  """

  alias Blazie.{Fact, Ledger, Snapshot}

  @enforce_keys [:id, :compute]
  defstruct [:id, :compute]

  @type t :: %__MODULE__{id: term(), compute: (Snapshot.t() -> [assertion()])}
  @type assertion :: {term(), String.t(), term()}
  @type read_set :: [keyword()]

  @doc "Declare a formula. Nothing runs."
  @spec new(term(), (Snapshot.t() -> [assertion()])) :: t()
  def new(id, compute) when is_function(compute, 1), do: %__MODULE__{id: id, compute: compute}

  @doc """
  Answer the formula against a snapshot.

  Returns the assertions it would make, each naming this formula, and the read
  set that says when to ask again. Nothing is written — storing a formula's
  answer is a performance choice, so materializing is a separate decision.
  """
  @spec run(t(), Snapshot.t()) :: {[Ledger.assertion()], read_set()}
  def run(%__MODULE__{} = formula, %Snapshot{} = snapshot) do
    {assertions, reads} = Snapshot.track_reads(fn -> formula.compute.(snapshot) end)
    {Enum.map(assertions, &stamp(&1, formula.id)), reads}
  end

  @doc """
  Write the formula's answer into a ledger, and return the read set with it.

  Materializing is optional by construction — this exists for when keeping the
  answer is cheaper than recomputing it, not because the answer needs a home.
  """
  @spec materialize(t(), Snapshot.t(), Ledger.ref()) ::
          {:ok, pos_integer(), read_set()}
  def materialize(%__MODULE__{} = formula, %Snapshot{} = snapshot, ledger) do
    {assertions, reads} = run(formula, snapshot)
    {:ok, tx} = Ledger.append(ledger, assertions)
    {:ok, tx, reads}
  end

  @doc """
  Would any of these facts change the answer?

  True when a fact falls inside what the formula read. Facts outside the read
  set cannot affect it, which is what keeps re-execution from meaning
  re-execute-everything.
  """
  @spec stale?(read_set(), [Fact.t()]) :: boolean()
  def stale?(reads, facts) do
    Enum.any?(facts, fn fact -> Enum.any?(reads, &Fact.matches?(fact, &1)) end)
  end

  @doc """
  The facts that landed between two snapshots of the same ledgers.

  Together with `stale?/2` this is a subscription: hold a read set, ask what
  arrived, answer again only if it mattered.
  """
  @spec since(Snapshot.t(), Snapshot.t()) :: [Fact.t()]
  def since(%Snapshot{} = before, %Snapshot{} = now) do
    seen = MapSet.new(Snapshot.facts(before))

    now
    |> Snapshot.facts()
    |> Enum.reject(&MapSet.member?(seen, &1))
  end

  defp stamp({id, attribute, answer}, by), do: {id, attribute, answer, by}
  defp stamp({id, attribute, answer, _by}, by), do: {id, attribute, answer, by}
end
