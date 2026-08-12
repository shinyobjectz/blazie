defmodule LazyRiver.Ledger do
  @moduledoc """
  The append-only sequence facts go into, and the boundary that owns them
  (`led`).

  A ledger is readable, forkable and deletable on its own; a tenant is one or
  more ledgers. Sovereignty is which ledger a fact was written to, decided once
  at write time — there is no predicate to remember and no shared table to
  accidentally scan.

  Nothing here is rewritten: a later fact corrects an earlier one, and the only
  destruction is erasure, which destroys a key rather than a segment.

  Storage is in memory for now. The ledger is the seam that hides it, so
  putting segments on object storage later changes nothing above this line.
  """

  use GenServer

  alias LazyRiver.Fact

  @type ref :: GenServer.server()
  @type assertion ::
          {id :: term(), attribute :: atom(), answer :: term()}
          | {id :: term(), attribute :: atom(), answer :: term(), by :: term()}

  # ── opening ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, name, [name: name] ++ opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  # ── writing ────────────────────────────────────────────────────────────────

  @doc """
  Append facts, and return the transaction they landed in.

  The transaction is the ledger's name for that moment, so a writer can read
  its own write without polling — the number it gets back is the point the
  facts are visible at.
  """
  @spec append(ref(), [assertion()]) :: {:ok, pos_integer()}
  def append(ledger, assertions) when is_list(assertions) do
    GenServer.call(ledger, {:append, assertions})
  end

  # ── reading ────────────────────────────────────────────────────────────────

  @doc "The transaction this ledger is currently at."
  @spec tx(ref()) :: non_neg_integer()
  def tx(ledger), do: GenServer.call(ledger, :tx)

  @doc """
  Every fact recorded at or before `tx`, oldest first.

  This is the whole reason a snapshot can be a value: the answer here depends
  only on `tx`, so it is the same answer forever.
  """
  @spec facts_at(ref(), non_neg_integer()) :: [Fact.t()]
  def facts_at(ledger, tx), do: GenServer.call(ledger, {:facts_at, tx})

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(name), do: {:ok, %{name: name, tx: 0, facts: []}}

  @impl true
  def handle_call({:append, assertions}, _from, state) do
    tx = state.tx + 1
    facts = Enum.map(assertions, &to_fact(&1, tx))
    # Newest first while resident; readers reverse. Appending is the hot path.
    {:reply, {:ok, tx}, %{state | tx: tx, facts: Enum.reverse(facts) ++ state.facts}}
  end

  def handle_call(:tx, _from, state), do: {:reply, state.tx, state}

  def handle_call({:facts_at, tx}, _from, state) do
    facts =
      state.facts
      |> Enum.drop_while(&(&1.tx > tx))
      |> Enum.reverse()

    {:reply, facts, state}
  end

  defp to_fact({id, attribute, answer}, tx),
    do: %Fact{id: id, attribute: attribute, answer: answer, tx: tx}

  defp to_fact({id, attribute, answer, by}, tx),
    do: %Fact{id: id, attribute: attribute, answer: answer, tx: tx, by: by}
end
