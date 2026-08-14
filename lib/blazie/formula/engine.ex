defmodule Blazie.Formula.Engine do
  @moduledoc """
  Where formulas are registered, and where the decision to keep an answer is
  made rather than declared.

  A formula says what, never when — so something has to decide when. That is
  this, and doctrine 5 says it is the engine's job rather than the author's.

  ## A cache keyed by a name cannot go stale — except the one way it can

  An answer at a named snapshot is the same answer forever, so caching on
  `{formula, its body, name}` is correct for every ordinary write: a later
  write produces a *different* name, which is a miss rather than a conflict.
  The body is in the key because the actual question is the formula's CODE,
  not its name — a formula replaced in place kept answering with the old
  code's answers forever, at every name already asked (C11).

  The exception is erasure, and for a while this module and the README each
  held one of two true sentences that could not both be true: "never
  invalidates" here, "an old name answers `:erased`" there — and the cache
  implemented the wrong one, serving destroyed plaintext under a destroyed
  key (C10). So the engine watches `Erasure.epoch/0` and drops everything it
  holds when the epoch moves. Coarse on purpose: erasure is rare, recomputing
  is always available, and anything finer needs provenance nobody records —
  the same direction the read-set widens in, toward re-answering rather than
  toward a stale answer.

  What the cache needs beyond that is eviction, which is a size problem, not
  a correctness one. That is the whole reason this is small. In a mutable
  database the same component would be the hardest thing in the system.

  ## What it decides today, and what it is collecting for

  Today: keep every answer, bounded, oldest evicted first. That is enough
  because recomputation is always available — a miss costs time, never
  correctness.

  It belongs to no world. A cache key is a formula and a snapshot name, and a
  snapshot name already says which ledgers it composed — so one engine serves
  every world, and asking it to name one was state it never read.

  It also counts what each formula was asked and what it had to compute, which
  is the input to the decision it does not yet make: whether an answer is
  expensive and repeated enough to be worth writing into a world as facts.
  Materialising is a performance choice, so it should be made from measurement
  rather than from a flag somebody set.
  """

  use GenServer

  alias Blazie.{Erasure, Formula, Snapshot}

  @type option ::
          {:formulas, [Formula.t()]}
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
       formulas: opts |> Keyword.get(:formulas, []) |> Map.new(&{&1.id, &1}),
       limit: Keyword.get(opts, :cache, @default_cache),
       # key => answer, plus the order they were last wanted in.
       kept: %{},
       order: [],
       stats: %{},
       epoch: Erasure.epoch()
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
    # The body's stamp is in the key: the question is the code, not the name.
    key = {formula.id, formula.stamp, Snapshot.name(snapshot)}
    state = state |> current() |> count(formula.id, :asked)

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

  # Everything kept was derived under keys that opened at the time. When an
  # erasure happens, some of those keys no longer open, and no record says
  # which answers they fed — so all of it goes, and the next ask recomputes
  # against the world as it now answers.
  defp current(state) do
    case Erasure.epoch() do
      epoch when epoch == state.epoch -> state
      epoch -> %{state | kept: %{}, order: [], epoch: epoch}
    end
  end

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
