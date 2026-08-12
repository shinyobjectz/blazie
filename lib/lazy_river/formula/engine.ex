defmodule LazyRiver.Formula.Engine do
  @moduledoc """
  Where formulas are registered, and where the decision to keep an answer is
  made rather than declared.

  A formula says what, never when — so something has to decide when. That is
  this, and doctrine 5 says it is the engine's job rather than the author's.

  ## A cache keyed by a name cannot go stale

  An answer at a named snapshot is the same answer forever, so caching on
  `{formula, name}` is trivially correct. There is no invalidation here and
  there is no cache-coherence protocol, because there is nothing to cohere — a
  later write produces a *different* name, which is a miss rather than a
  conflict. What the cache needs is eviction, which is a size problem, not a
  correctness one.

  That is the whole reason this is small. In a mutable database the same
  component would be the hardest thing in the system.

  ## What it decides today, and what it is collecting for

  Today: keep every answer, bounded, oldest evicted first. That is enough
  because recomputation is always available — a miss costs time, never
  correctness.

  It also counts what each formula was asked and what it had to compute, which
  is the input to the decision it does not yet make: whether an answer is
  expensive and repeated enough to be worth writing into a ledger as facts.
  Materialising is a performance choice, so it should be made from measurement
  rather than from a flag somebody set.
  """

  use GenServer

  alias LazyRiver.{Formula, Ledger, Snapshot}

  @type option ::
          {:ledger, Ledger.name() | Ledger.ref()}
          | {:formulas, [Formula.t()]}
          | {:cache, pos_integer()}
          | {:name, GenServer.name()}

  @default_cache 256

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Answer a formula at a snapshot, computing it only if it is not already known.

  A formula nobody registered is refused with what would fix it, rather than
  answered with nothing — an empty answer and an unknown question look the same
  to a caller, and only one of them is a bug.
  """
  @spec answer(GenServer.server(), term(), Snapshot.t()) ::
          {:ok, [tuple()]} | {:error, %{problem: atom(), repair: String.t()}}
  def answer(engine, id, %Snapshot{} = snapshot),
    do: GenServer.call(engine, {:answer, id, snapshot})

  @doc "Register a formula while the engine runs."
  @spec register(GenServer.server(), Formula.t()) :: :ok
  def register(engine, %Formula{} = formula), do: GenServer.call(engine, {:register, formula})

  @doc "What each formula was asked, and what it had to compute."
  @spec stats(GenServer.server()) :: %{
          term() => %{asked: non_neg_integer(), computed: non_neg_integer()}
        }
  def stats(engine), do: GenServer.call(engine, :stats)

  @doc "How many answers are being kept."
  @spec cached(GenServer.server()) :: non_neg_integer()
  def cached(engine), do: GenServer.call(engine, :cached)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %{
       ledger: Keyword.fetch!(opts, :ledger),
       formulas: opts |> Keyword.get(:formulas, []) |> Map.new(&{&1.id, &1}),
       limit: Keyword.get(opts, :cache, @default_cache),
       # key => answer, plus the order they were last wanted in.
       kept: %{},
       order: [],
       stats: %{}
     }}
  end

  @impl true
  def handle_call({:answer, id, snapshot}, _from, state) do
    case Map.fetch(state.formulas, id) do
      :error -> {:reply, {:error, unregistered(id)}, state}
      {:ok, formula} -> reply_with_answer(formula, snapshot, state)
    end
  end

  def handle_call({:register, formula}, _from, state),
    do: {:reply, :ok, put_in(state.formulas[formula.id], formula)}

  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}
  def handle_call(:cached, _from, state), do: {:reply, map_size(state.kept), state}

  defp reply_with_answer(formula, snapshot, state) do
    key = {formula.id, Snapshot.name(snapshot)}
    state = count(state, formula.id, :asked)

    case Map.fetch(state.kept, key) do
      {:ok, answer} ->
        {:reply, {:ok, answer}, touch(state, key)}

      :error ->
        {answer, _reads} = Formula.run(formula, snapshot)

        state =
          state
          |> count(formula.id, :computed)
          |> keep(key, answer)

        {:reply, {:ok, answer}, state}
    end
  end

  # ── keeping ────────────────────────────────────────────────────────────────

  defp keep(state, key, answer) do
    %{
      state
      | kept: Map.put(state.kept, key, answer),
        order: [key | List.delete(state.order, key)]
    }
    |> evict()
  end

  defp touch(state, key), do: %{state | order: [key | List.delete(state.order, key)]}

  defp evict(state) when map_size(state.kept) == 0, do: state

  defp evict(state) do
    if map_size(state.kept) <= state.limit do
      state
    else
      {kept_order, [oldest]} = Enum.split(state.order, state.limit)
      %{state | kept: Map.delete(state.kept, oldest), order: kept_order}
    end
  end

  defp count(state, id, what) do
    update_in(state.stats, fn stats ->
      Map.update(stats, id, %{asked: 0, computed: 0} |> Map.put(what, 1), fn counts ->
        Map.update!(counts, what, &(&1 + 1))
      end)
    end)
  end

  defp unregistered(id) do
    %{
      problem: :unregistered_formula,
      repair:
        "No formula named #{inspect(id)} here. A cadence can be a fact but a body is code, so " <>
          "register it first: Engine.register(engine, Formula.new(#{inspect(id)}, fn snapshot -> ... end))."
    }
  end
end
