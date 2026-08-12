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

  Where the facts actually live is a `LazyRiver.Store`, chosen when the ledger
  is opened. The ledger is the seam that hides it, so an LSM on object storage
  later changes nothing above this line — and nothing above this line has ever
  needed to ask.
  """

  use GenServer

  alias LazyRiver.{Fact, Store}

  @type name :: term()
  @type ref :: GenServer.server()
  @type assertion ::
          {id :: term(), attribute :: String.t(), answer :: term()}
          | {id :: term(), attribute :: String.t(), answer :: term(), by :: term()}

  # ── opening ────────────────────────────────────────────────────────────────
  #
  # A ledger's name is any term, not an atom. Tenants arrive at runtime, and
  # atoms are never collected — a name taken from a request would leak the atom
  # table until the node fell over.

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Open a ledger under this name, or hand back the one already open.

  Pass `store:` to say where its facts live. The default keeps them in memory,
  which is right for a ledger nobody needs to survive a restart and wrong for
  every other one:

      Ledger.open({:tenant, 7}, store: {Store.File, dir: "priv/ledgers"})
  """
  @spec open(name(), keyword()) :: {:ok, ref()}
  def open(name, opts \\ []) do
    child = {__MODULE__, [name: name] ++ opts}

    case DynamicSupervisor.start_child(LazyRiver.LedgerSupervisor, child) do
      {:ok, _pid} -> {:ok, via(name)}
      {:error, {:already_started, _pid}} -> {:ok, via(name)}
      other -> other
    end
  end

  @doc """
  Close a ledger, and do not return until the name is free.

  Terminating a child is synchronous but the registry drops the name on a
  monitor message, which is not — so closing and immediately reopening would
  otherwise race with itself. Waiting here costs a moment once; not waiting
  costs an intermittent failure in every caller.

  In memory this forgets the facts, which is why closing and erasing are not
  the same operation. Erasure destroys a key, and there are no keys yet.
  """
  @spec close(name()) :: :ok | {:error, :not_found | :timeout}
  def close(name) do
    case Registry.lookup(LazyRiver.Registry, name) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(LazyRiver.LedgerSupervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> await_free(name)
        after
          5_000 ->
            Process.demonitor(ref, [:flush])
            {:error, :timeout}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp await_free(name, remaining \\ 500) do
    case {Registry.lookup(LazyRiver.Registry, name), remaining} do
      {[], _} -> :ok
      {_, 0} -> {:error, :timeout}
      _ -> Process.sleep(1) && await_free(name, remaining - 1)
    end
  end

  @doc "Every ledger currently open."
  @spec open_ledgers() :: [name()]
  def open_ledgers do
    Registry.select(LazyRiver.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "The address of a ledger by name, whether or not it is open yet."
  @spec via(name()) :: ref()
  def via(name), do: {:via, Registry, {LazyRiver.Registry, name}}

  # ── writing ────────────────────────────────────────────────────────────────

  @doc """
  Append facts, and return the transaction they landed in.

  The transaction is the ledger's name for that moment, so a writer can read
  its own write without polling — the number it gets back is the point the
  facts are visible at.

  Pass `check:` to refuse a write that would leave the vocabulary inconsistent.
  The ledger applies the check without knowing what one is — it holds the one
  serialized path every write goes through, and that is the only reason the
  check belongs here.

      Ledger.append(ledger, assertions, check: &Attribute.check(&1, known))

  A refusal is returned, never raised, and carries whatever the check said
  would repair it.
  """
  @spec append(ref(), [assertion()], keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def append(ledger, assertions, opts \\ []) when is_list(assertions) do
    case Keyword.get(opts, :check) do
      nil -> GenServer.call(ledger, {:append, assertions})
      check when is_function(check, 1) -> checked_append(ledger, assertions, check)
    end
  end

  defp checked_append(ledger, assertions, check) do
    case check.(assertions) do
      :ok -> GenServer.call(ledger, {:append, assertions})
      {:error, refusals} -> {:error, refusals}
    end
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
  def init(opts) do
    # Trap exits so the store is closed on an ordinary shutdown rather than
    # only when the process is killed.
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    {module, store_opts} = Keyword.get(opts, :store, {Store.Memory, []})
    {:ok, store} = module.open(name, store_opts)

    replayed = module.replay(store)
    resumed = replayed |> Enum.map(& &1.tx) |> Enum.max(fn -> 0 end)

    {:ok,
     %{
       name: name,
       tx: resumed,
       facts: Enum.reverse(replayed),
       store: store,
       module: module
     }}
  end

  @impl true
  def handle_call({:append, assertions}, _from, state) do
    tx = state.tx + 1
    facts = Enum.map(assertions, &to_fact(&1, tx))

    # Recorded before replied to: a returned transaction is one the store took.
    {:ok, store} = state.module.append(state.store, facts)

    # Newest first while resident; readers reverse. Appending is the hot path.
    {:reply, {:ok, tx},
     %{state | tx: tx, store: store, facts: Enum.reverse(facts) ++ state.facts}}
  end

  def handle_call(:tx, _from, state), do: {:reply, state.tx, state}

  def handle_call({:facts_at, tx}, _from, state) do
    facts =
      state.facts
      |> Enum.drop_while(&(&1.tx > tx))
      |> Enum.reverse()

    {:reply, facts, state}
  end

  @impl true
  def terminate(_reason, state), do: state.module.close(state.store)

  defp to_fact({id, attribute, answer}, tx),
    do: %Fact{id: id, attribute: attribute, answer: answer, tx: tx}

  defp to_fact({id, attribute, answer, by}, tx),
    do: %Fact{id: id, attribute: attribute, answer: answer, tx: tx, by: by}
end
