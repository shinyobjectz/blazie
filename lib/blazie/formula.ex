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

  alias Blazie.{Fact, World, Snapshot}

  @enforce_keys [:id, :compute]
  defstruct [:id, :compute]

  @type t :: %__MODULE__{id: term(), compute: (Snapshot.t() -> [assertion()])}
  @type assertion :: {term(), String.t(), term()}
  @type read_set :: [keyword()]

  @doc "Declare a formula. Nothing runs."
  @spec new(term(), (Snapshot.t() -> [assertion()])) :: t()
  def new(id, compute) when is_function(compute, 1), do: %__MODULE__{id: id, compute: compute}

  @doc """
  A formula whose body is Lua held in the world.

      {"adults", "is", "formula"}
      {"adults", "source", "for p in each { age = true } do p.adult = p.age >= 18 end"}

  The same shape a requirement already uses, generalised — which is the point.
  A formula authored this way needs no deploy, is corrected by a later fact, and
  answers at a snapshot name like any other, so an old name keeps answering what
  it always answered even after the source changes.

  It runs in the formula world: no clock, no network, a deadline. That is not a
  rule applied to Lua from outside, it is the absence of anything to reach — so
  a formula loaded from a fact is exactly as unable to reach out as one written
  here, and the test for it asserts `http` is nil inside one.

  Whatever the chunk writes becomes the formula's assertions, so `p.adult = …`
  in Lua is what `{p, "adult", …}` is in Elixir. Nothing is appended by running
  one; a formula's answer is a value, and storing it is a separate decision.
  """
  @spec of_source(term(), String.t()) :: t()
  def of_source(id, source) when is_binary(source) do
    %__MODULE__{
      id: id,
      compute: fn snapshot ->
        # `watching/3` rather than `run/3`: a guest runs in a process of its own,
        # so what it read lands in that process's dictionary and the
        # `track_reads/1` around this one would see nothing. A formula with an
        # empty read set is never stale — it would answer once and never notice
        # the world had moved, which is a worse failure than being slow.
        case Blazie.Lua.Binding.watching(source, snapshot, as: :formula) do
          {:ok, _value, staged, read} ->
            Snapshot.record_reads(read)
            staged

          {:error, refusal} ->
            raise "formula #{inspect(id)} did not run: #{Map.get(refusal, :repair, inspect(refusal))}"
        end
      end
    }
  end

  @doc """
  Every formula declared in a snapshot, built from its stored source.

  The registry is the world. A formula arrives by being written, and there is no
  list anywhere that could disagree with what is actually declared.
  """
  @spec declared(Snapshot.t()) :: [t()]
  def declared(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find(attribute: "is", value: "formula")
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Snapshot.value(snapshot, id, "source") do
        source when is_binary(source) -> [of_source(id, source)]
        _ -> []
      end
    end)
    |> Enum.sort_by(&inspect(&1.id))
  end

  @doc """
  Answer the formula against a snapshot.

  Returns the assertions it would make, each naming this formula, and the read
  set that says when to ask again. Nothing is written — storing a formula's
  answer is a performance choice, so materializing is a separate decision.
  """
  @spec run(t(), Snapshot.t()) :: {[World.assertion()], read_set()}
  def run(%__MODULE__{} = formula, %Snapshot{} = snapshot) do
    {assertions, reads} = Snapshot.track_reads(fn -> formula.compute.(snapshot) end)
    {Enum.map(assertions, &stamp(&1, formula.id)), reads}
  end

  @doc """
  Write the formula's answer into a world, and return the read set with it.

  Materializing is optional by construction — this exists for when keeping the
  answer is cheaper than recomputing it, not because the answer needs a home.
  """
  @spec materialize(t(), Snapshot.t(), World.ref()) ::
          {:ok, pos_integer(), read_set()}
  def materialize(%__MODULE__{} = formula, %Snapshot{} = snapshot, world) do
    {assertions, reads} = run(formula, snapshot)
    {:ok, tx} = World.append(world, assertions)
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
