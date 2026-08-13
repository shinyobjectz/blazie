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

  alias LazyRiver.{Cluster, Erasure, Fact, Store}

  @subject "subject"

  @type name :: term()
  @type ref :: GenServer.server()
  @type assertion ::
          {id :: term(), attribute :: String.t(), value :: term()}
          | {id :: term(), attribute :: String.t(), value :: term(), by :: term()}

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
  @spec open(name(), keyword()) :: {:ok, ref()} | {:error, Cluster.refusal()}
  def open(name, opts \\ []) do
    case local(name) do
      pid when is_pid(pid) -> {:ok, via(name)}
      nil -> claim_and_start(name, opts)
    end
  end

  # The claim is only ever made *for the ledger process*, never for whoever is
  # opening. An earlier version claimed as the opener and swapped afterwards,
  # which left a window where a concurrent open could take the name for its own
  # transient pid — and a later caller then found the ledger owned by something
  # that was not a ledger. It failed about one run in twelve.
  defp claim_and_start(name, opts) do
    if Cluster.owner(name) do
      {:error, Cluster.refusal(name)}
    else
      child = {__MODULE__, [name: name] ++ opts}

      case DynamicSupervisor.start_child(LazyRiver.LedgerSupervisor, child) do
        {:ok, pid} ->
          claim_for(name, pid)

        # Another process on this node won the race to start the same ledger.
        # Its claim is the right one.
        {:error, {:already_started, _pid}} ->
          {:ok, via(name)}

        other ->
          other
      end
    end
  end

  defp claim_for(name, pid) do
    case Cluster.claim_as(name, pid) do
      :yes ->
        {:ok, via(name)}

      :no ->
        # Claimed elsewhere between the check and the start. Undo what we
        # started rather than leave an unclaimed ledger running.
        DynamicSupervisor.terminate_child(LazyRiver.LedgerSupervisor, pid)
        {:error, Cluster.refusal(name)}
    end
  end

  defp local(name) do
    case Registry.lookup(LazyRiver.Registry, name) do
      [{pid, _}] -> pid
      [] -> nil
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
    |> tap(fn _ -> Cluster.release(name) end)
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

  @doc """
  Where a ledger keeps its facts when nobody said.

  Memory when nothing is configured, which is right for a test and wrong for
  everything else — so a deployment that sets `:ledger_dir` gets the file store
  without anyone having to remember to ask. A deployment found this the hard
  way: the config existed, nothing read it, and every ledger in production was
  in memory.
  """
  @spec default_store() :: {module(), keyword()}
  def default_store do
    case Application.get_env(:lazy_river, :ledger_dir) do
      nil ->
        {Store.Memory, []}

      dir ->
        {Store.File,
         dir: dir,
         sync: Application.get_env(:lazy_river, :ledger_sync, false),
         checkpoint_every: Application.get_env(:lazy_river, :ledger_checkpoint_every, 1_000)}
    end
  end

  @doc "The address of a ledger by name, whether or not it is open yet."
  @spec via(name()) :: ref()
  def via(name), do: {:via, Registry, {LazyRiver.Registry, name}}

  @doc """
  What a ledger is called, given its address.

  An address is where a ledger is; a name is what it is called. Everything a
  caller holds or stores is the name, because an address is a live thing that
  means nothing after a restart and nothing at all on paper.
  """
  @spec name_of(ref()) :: name()
  def name_of({:via, Registry, {LazyRiver.Registry, name}}), do: name
  def name_of(pid) when is_pid(pid), do: raise(ArgumentError, pid_has_no_name())
  def name_of(name), do: name

  defp pid_has_no_name do
    "A ledger's name cannot be recovered from a bare pid. Open it by name — " <>
      "Ledger.open/2 hands back an address that carries one."
  end

  # ── writing ────────────────────────────────────────────────────────────────

  @doc """
  Append facts, and return the transaction they landed in.

  The transaction is the ledger's name for that moment, so a writer can read
  its own write without polling — the number it gets back is the point the
  facts are visible at.

  Pass `check:` to refuse a write that would leave the vocabulary inconsistent.
  The ledger holds the one serialized path every write goes through, which is
  the only reason a check belongs here — but that is only true of a check it
  actually runs:

      # Serialized. Run inside the ledger, on the facts the write lands on.
      Ledger.append(ledger, assertions, check: &Attribute.check/2)

      # Advisory. Run in the caller, before the call, against whatever it had.
      Ledger.append(ledger, assertions, check: &Attribute.check(&1, known))

  The arity is the difference and it is load-bearing. An arity-1 check runs in
  the caller and cannot serialize anything: two writers both pass it, then both
  append, and a uniqueness check admits both. An arity-2 check is handed the
  ledger's own facts inside the one process that appends, so what it checked is
  what it wrote. The arity-1 form is kept because a caller that wants to know
  before it asks is a fair thing to want — it is not a constraint.

  A refusal is returned, never raised, and carries whatever the check said
  would repair it. A check that raises is a refusal too: it runs where the
  facts live, and nothing running there may take them down.
  """
  @spec append(ref(), [assertion()], keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def append(ledger, assertions, opts \\ []) when is_list(assertions) do
    case Keyword.get(opts, :check) do
      nil -> GenServer.call(ledger, {:append, assertions})
      check when is_function(check, 2) -> GenServer.call(ledger, {:append, assertions, check})
      check when is_function(check, 1) -> advisory_append(ledger, assertions, check)
    end
  end

  # Checked in the caller, then appended — so anything landing in between is
  # not accounted for. Named for what it is.
  defp advisory_append(ledger, assertions, check) do
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
  How many facts this ledger is holding in memory.

  Bounded by `resident:`, with two honest caveats. It is a floor rounded up to
  a transaction boundary, because a transaction is evicted whole or not at all
  — so a fifty-fact write keeps fifty however small the setting. And it only
  saves anything when the facts are durable somewhere else: with the memory
  store, the store *is* the memory.
  """
  @spec resident(ref()) :: non_neg_integer()
  def resident(ledger), do: GenServer.call(ledger, :resident)

  @doc """
  Every fact recorded at or before `tx`, oldest first.

  This is the whole reason a snapshot can be a value: the answer here depends
  only on `tx`, so it is the same answer forever.
  """
  @spec facts_at(ref(), non_neg_integer()) :: [Fact.t()]
  def facts_at(ledger, tx), do: GenServer.call(ledger, {:facts_at, tx})

  @doc """
  The facts matching a pattern at or before `tx`, oldest first.

  Answered here rather than by scanning what `facts_at/2` returns, for two
  reasons. The obvious one is that a keyed lookup beats a scan. The quieter one
  is that filtering in this process means only the answer crosses the process
  boundary — asking a large ledger a small question used to copy all of it.
  """
  @spec find_at(ref(), non_neg_integer(), keyword()) :: [Fact.t()]
  def find_at(ledger, tx, pattern) do
    # Checked here, in the caller's process, because the ledger is where
    # everybody's facts live and a read must never be able to take it down.
    Fact.fields!(pattern)
    GenServer.call(ledger, {:find_at, tx, pattern})
  end

  @doc "Facts exactly as stored, sealed values and all."
  @spec raw_at(ref(), non_neg_integer()) :: [Fact.t()]
  def raw_at(ledger, tx), do: GenServer.call(ledger, {:raw_at, tx})

  @doc "What the store had to do to open. Observability, not vocabulary."
  @spec store_stats(ref()) :: map()
  def store_stats(ledger), do: GenServer.call(ledger, :store_stats)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Trap exits so the store is closed on an ordinary shutdown rather than
    # only when the process is killed.
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    {module, store_opts} = Keyword.get(opts, :store, default_store())
    {:ok, store} = module.open(name, store_opts)

    replayed = module.replay(store)
    resumed = replayed |> Enum.map(& &1.tx) |> Enum.max(fn -> 0 end)

    {:ok,
     index(
       %{
         name: name,
         tx: resumed,
         facts: Enum.reverse(replayed),
         # Counted rather than measured. `length/1` is O(n), and both the
         # trim check and `resident/1` ran it — the trim check on EVERY
         # append, which is the shape of cost the store was just cured of.
         count: length(replayed),
         by_id: %{},
         by_attribute: %{},
         by_value: %{},
         oldest: oldest_of(replayed),
         resident: Keyword.get(opts, :resident, :unbounded),
         store: store,
         module: module
       },
       replayed
     )
     |> trim()}
  end

  @impl true
  # The serialized check: run here, on the facts this write is about to land
  # on, in the one process that appends. A check that raises becomes a refusal
  # rather than a crash — this runs where everybody's facts live, and a write
  # that cannot be judged must not be able to destroy the thing it was judging.
  def handle_call({:append, assertions, check}, from, state) do
    case run_check(check, assertions, Enum.reverse(state.facts)) do
      :ok -> handle_call({:append, assertions}, from, state)
      {:error, refusals} -> {:reply, {:error, refusals}, state}
    end
  end

  def handle_call({:append, assertions}, _from, state) do
    tx = state.tx + 1
    facts = Enum.map(assertions, &(&1 |> to_fact(tx) |> seal(state)))

    # Recorded before replied to: a returned transaction is one the store took.
    {:ok, store} = state.module.append(state.store, facts)

    announce(state.name, tx, facts)

    # Newest first while resident; readers reverse. Appending is the hot path.
    state = %{
      state
      | tx: tx,
        store: store,
        facts: Enum.reverse(facts) ++ state.facts,
        count: state.count + length(facts)
    }

    {:reply, {:ok, tx}, state |> index(facts) |> trim()}
  end

  def handle_call(:tx, _from, state), do: {:reply, state.tx, state}
  def handle_call(:resident, _from, state), do: {:reply, state.count, state}

  def handle_call({:raw_at, tx}, _from, state) do
    {:reply, state.facts |> Enum.drop_while(&(&1.tx > tx)) |> Enum.reverse(), state}
  end

  def handle_call(:store_stats, _from, state) do
    stats =
      if function_exported?(state.module, :stats, 1),
        do: state.module.stats(state.store),
        else: %{}

    {:reply, stats, state}
  end

  def handle_call({:find_at, tx, pattern}, _from, state) do
    {:reply, Enum.map(matching(state, tx, pattern), &Erasure.reveal_fact/1), state}
  end

  def handle_call({:facts_at, tx}, _from, state) do
    facts =
      state.facts
      |> Enum.drop_while(&(&1.tx > tx))
      |> Enum.reverse()
      |> Enum.map(&Erasure.reveal_fact/1)

    {:reply, facts, state}
  end

  @impl true
  def terminate(_reason, state), do: state.module.close(state.store)

  # ── the sort orders ────────────────────────────────────────────────────────
  #
  # The same facts, reachable three ways: by the entity they are about, by the
  # attribute they assert, and by the value they hold — which is how an edge
  # is read backwards, since an edge is a fact whose value is another id.
  # Every list is newest first, like `facts`, so a read drops what is too new
  # and stops.
  #
  # These hold the same fact terms the list holds, not copies.

  defp index(state, facts) do
    Enum.reduce(facts, state, fn fact, acc ->
      acc
      |> update_in([:by_id, fact.id], &[fact | &1 || []])
      |> update_in([:by_attribute, fact.attribute], &[fact | &1 || []])
      |> update_in([:by_value, value_key(fact.value)], &[fact | &1 || []])
    end)
  end

  # Only values that can be looked up cheaply get an entry. A vector is not
  # one of them, and nobody asks for a fact by its embedding.
  defp value_key(value) when is_integer(value) or is_binary(value) or is_atom(value),
    do: value

  defp value_key(_value), do: :unindexed

  defp matching(state, tx, pattern) do
    resident =
      state
      |> narrowest(pattern)
      |> Enum.drop_while(&(&1.tx > tx))
      |> Enum.filter(&Fact.matches?(&1, pattern))
      |> Enum.reverse()

    evicted(state, tx, pattern) ++ resident
  end

  # Anything older than what is resident has to come from the store. This is a
  # full re-read: honest rather than good, and exactly what compaction and a
  # segmented store are for.
  defp evicted(%{oldest: nil}, _tx, _pattern), do: []
  defp evicted(%{oldest: oldest}, _tx, _pattern) when oldest <= 1, do: []

  defp evicted(state, tx, pattern) do
    state.module.replay(state.store)
    |> Enum.filter(&(&1.tx < state.oldest and &1.tx <= tx and Fact.matches?(&1, pattern)))
  end

  # Pick the smallest starting set the pattern allows. An id is the most
  # selective thing anyone asks by, then an answer, then an attribute.
  defp narrowest(state, pattern) do
    cond do
      id = pattern[:id] ->
        Map.get(state.by_id, id, [])

      (value = pattern[:value]) && value_key(value) != :unindexed ->
        Map.get(state.by_value, value_key(value), [])

      attribute = pattern[:attribute] ->
        Map.get(state.by_attribute, attribute, [])

      true ->
        state.facts
    end
  end

  # ── staying within bounds ──────────────────────────────────────────────────
  #
  # Trimming rebuilds the sort orders, so it runs on a high-water mark rather
  # than on every append once the limit is reached — otherwise the cost would
  # land on every write forever.

  defp trim(%{resident: :unbounded} = state), do: state

  defp trim(state) do
    if state.count > trunc(state.resident * 1.5) do
      kept = keep_whole_transactions(state.facts, state.resident)

      %{
        state
        | facts: kept,
          count: length(kept),
          by_id: %{},
          by_attribute: %{},
          by_value: %{},
          oldest: oldest_of(kept)
      }
      |> index(Enum.reverse(kept))
    else
      state
    end
  end

  # A transaction is evicted whole or not at all. Splitting one leaves its
  # remainder neither resident nor older than what is resident, so it answers
  # from nowhere — which is how forty facts went missing the first time.
  defp keep_whole_transactions(facts, limit) do
    {head, rest} = Enum.split(facts, limit)

    case List.last(head) do
      nil -> head
      last -> head ++ Enum.take_while(rest, &(&1.tx == last.tx))
    end
  end

  # A fact is sealed under whoever its entity belongs to, if that was declared
  # before it was written. The subject fact itself is never sealed — it is the
  # thing that says which key to use.
  defp seal(%Fact{attribute: @subject} = fact, _state), do: fact

  defp seal(fact, state) do
    case owner_of(state, fact.id) do
      nil -> fact
      subject -> %{fact | value: Erasure.protect(fact.value, subject)}
    end
  end

  defp owner_of(state, id) do
    state
    |> Map.get(:by_id, %{})
    |> Map.get(id, [])
    |> Enum.find(&(&1.attribute == @subject))
    |> case do
      nil -> nil
      fact -> fact.value
    end
  end

  defp oldest_of([]), do: nil
  defp oldest_of(facts), do: facts |> Enum.map(& &1.tx) |> Enum.min()

  # Tell whoever is watching. Only sends — a watcher that called back into this
  # ledger while it was still replying would deadlock, so it never does.
  defp run_check(check, assertions, facts) do
    check.(assertions, facts)
  rescue
    error ->
      {:error,
       [
         %{
           problem: :check_raised,
           repair:
             "The check on this write raised rather than deciding: " <>
               "#{Exception.message(error)}. Nothing was written."
         }
       ]}
  catch
    kind, reason ->
      {:error,
       [
         %{
           problem: :check_raised,
           repair:
             "The check on this write #{kind} #{inspect(reason)} rather than deciding. " <>
               "Nothing was written."
         }
       ]}
  end

  defp announce(name, tx, facts) do
    Registry.dispatch(LazyRiver.Watchers, name, fn watchers ->
      for {pid, _ref} <- watchers, do: send(pid, {:appended, name, tx, facts})
    end)
  end

  defp to_fact({id, attribute, answer}, tx),
    do: %Fact{id: id, attribute: attribute, value: answer, tx: tx}

  defp to_fact({id, attribute, answer, by}, tx),
    do: %Fact{id: id, attribute: attribute, value: answer, tx: tx, by: by}
end
