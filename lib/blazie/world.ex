defmodule Blazie.World do
  @moduledoc """
  The append-only sequence facts go into, and the boundary that owns them
  (`led`).

  A world is readable, forkable and deletable on its own; a tenant is one or
  more ledgers. Sovereignty is which world a fact was written to, decided once
  at write time — there is no predicate to remember and no shared table to
  accidentally scan.

  Nothing here is rewritten: a later fact corrects an earlier one, and the only
  destruction is erasure, which destroys a key rather than a segment.

  Where the facts actually live is a `Blazie.Store`, chosen when the world
  is opened. The world is the seam that hides it, so an LSM on object storage
  later changes nothing above this line — and nothing above this line has ever
  needed to ask.
  """

  use GenServer

  alias Blazie.{Cluster, Erasure, Fact, Store}

  @subject "subject"

  @type name :: term()
  @type ref :: GenServer.server()
  @type assertion ::
          {id :: term(), attribute :: String.t(), value :: term()}
          | {id :: term(), attribute :: String.t(), value :: term(), by :: term()}

  # ── opening ────────────────────────────────────────────────────────────────
  #
  # A world's name is any term, not an atom. Tenants arrive at runtime, and
  # atoms are never collected — a name taken from a request would leak the atom
  # table until the node fell over.

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      # Transient, not permanent: a crash is restarted exactly as before, but
      # a world that STOPS — closed, or idle-evicted under `evict_after:` —
      # stays stopped. Permanent would resurrect an evicted world instantly,
      # which makes eviction a no-op with extra steps.
      restart: :transient
    }
  end

  @doc """
  Open a world under this name, or hand back the one already open.

  Pass `store:` to say where its facts live. The default keeps them in memory,
  which is right for a world nobody needs to survive a restart and wrong for
  every other one:

      World.open({:tenant, 7}, store: {Store.File, dir: "priv/ledgers"})
  """
  @spec open(name(), keyword()) :: {:ok, ref()} | {:error, Cluster.refusal()}
  def open(name, opts \\ []) do
    case local(name) do
      pid when is_pid(pid) -> {:ok, via(name)}
      nil -> claim_and_start(name, opts)
    end
  end

  # The claim is only ever made *for the world process*, never for whoever is
  # opening. An earlier version claimed as the opener and swapped afterwards,
  # which left a window where a concurrent open could take the name for its own
  # transient pid — and a later caller then found the world owned by something
  # that was not a world. It failed about one run in twelve.
  defp claim_and_start(name, opts) do
    if Cluster.owner(name) do
      {:error, Cluster.refusal(name)}
    else
      child = {__MODULE__, [name: name] ++ opts}

      case DynamicSupervisor.start_child(Blazie.WorldSupervisor, child) do
        {:ok, pid} ->
          claim_for(name, pid)

        # Another process on this node won the race to start the same world.
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
        # started rather than leave an unclaimed world running.
        DynamicSupervisor.terminate_child(Blazie.WorldSupervisor, pid)
        {:error, Cluster.refusal(name)}
    end
  end

  defp local(name) do
    case Registry.lookup(Blazie.Registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Close a world, and do not return until the name is free.

  Terminating a child is synchronous but the registry drops the name on a
  monitor message, which is not — so closing and immediately reopening would
  otherwise race with itself. Waiting here costs a moment once; not waiting
  costs an intermittent failure in every caller.

  In memory this forgets the facts, which is why closing and erasing are not
  the same operation. Erasure destroys a key, and there are no keys yet.
  """
  @spec close(name()) :: :ok | {:error, :not_found | :timeout}
  def close(name) do
    case Registry.lookup(Blazie.Registry, name) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(Blazie.WorldSupervisor, pid)

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
    case {Registry.lookup(Blazie.Registry, name), remaining} do
      {[], _} -> :ok
      {_, 0} -> {:error, :timeout}
      _ -> Process.sleep(1) && await_free(name, remaining - 1)
    end
  end

  @doc "Every world currently open."
  @spec open_worlds() :: [name()]
  def open_worlds do
    Registry.select(Blazie.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Whether anything is already keeping facts under this name.

  Opening a world creates it, which is the right default everywhere inside the
  node and the wrong one at the door: a caller claiming a name needs to know
  whether it is taking somebody's world or making its own, and `open/1` cannot
  tell it apart because both look like success.

  Open covers a world in memory; the file covers one that exists but has not
  been opened since the node booted. A memory store has no file, so an unopened
  world is unrecoverable there and correctly reads as absent.
  """
  @spec exists?(name()) :: boolean()
  def exists?(name) do
    name in open_worlds() or
      case Application.get_env(:blazie, :ledger_dir) do
        nil ->
          false

        dir ->
          # Either layout answers: a `.sqlite` written since the default
          # flipped, or a `.ledger` written before it and not yet opened
          # (opening is what migrates). A name is taken by its facts, not by
          # which engine happens to hold them.
          File.exists?(Path.join(dir, Store.SQLite.filename(name))) or
            File.exists?(Path.join(dir, Store.File.filename(name)))
      end
  end

  @doc """
  Where a world keeps its facts when nobody said.

  Memory when nothing is configured, which is right for a test and wrong for
  everything else — so a deployment that sets `:ledger_dir` gets a durable
  store without anyone having to remember to ask. A deployment found this the
  hard way: the config existed, nothing read it, and every world in
  production was in memory.

  The durable default is `Store.SQLite` (the P5 flip): one file per world,
  the store the replicator ships. There is no `checkpoint_every:` — a
  checkpoint was the file store's cure for replaying everything at open, and
  SQLite opens by reading nothing. A `.ledger` already on disk is migrated
  the first time its world opens; `Store.File` remains, explicitly asked
  for, as the read-only legacy path.
  """
  @spec default_store() :: {module(), keyword()}
  def default_store do
    case Application.get_env(:blazie, :ledger_dir) do
      nil ->
        {Store.Memory, []}

      dir ->
        {Store.SQLite, dir: dir, sync: Application.get_env(:blazie, :ledger_sync, false)}
    end
  end

  @doc "The address of a world by name, whether or not it is open yet."
  @spec via(name()) :: ref()
  def via(name), do: {:via, Registry, {Blazie.Registry, name}}

  @doc """
  What a world is called, given its address.

  An address is where a world is; a name is what it is called. Everything a
  caller holds or stores is the name, because an address is a live thing that
  means nothing after a restart and nothing at all on paper.
  """
  @spec name_of(ref()) :: name()
  def name_of({:via, Registry, {Blazie.Registry, name}}), do: name
  def name_of(pid) when is_pid(pid), do: raise(ArgumentError, pid_has_no_name())
  def name_of(name), do: name

  defp pid_has_no_name do
    "A world's name cannot be recovered from a bare pid. Open it by name — " <>
      "World.open/2 hands back an address that carries one."
  end

  # ── writing ────────────────────────────────────────────────────────────────

  @doc """
  Append facts, and return the transaction they landed in.

  The transaction is the world's name for that moment, so a writer can read
  its own write without polling — the number it gets back is the point the
  facts are visible at.

  Pass `check:` to refuse a write that would leave the vocabulary inconsistent.
  The world holds the one serialized path every write goes through, which is
  the only reason a check belongs here — but that is only true of a check it
  actually runs:

      # Serialized. Run inside the world, on the facts the write lands on.
      World.append(world, assertions, check: &Attribute.check/2)

      # Advisory. Run in the caller, before the call, against whatever it had.
      World.append(world, assertions, check: &Attribute.check(&1, known))

  The arity is the difference and it is load-bearing. An arity-1 check runs in
  the caller and cannot serialize anything: two writers both pass it, then both
  append, and a uniqueness check admits both. An arity-2 check is handed the
  world's own facts inside the one process that appends, so what it checked is
  what it wrote. The arity-1 form is kept because a caller that wants to know
  before it asks is a fair thing to want — it is not a constraint.

  A refusal is returned, never raised, and carries whatever the check said
  would repair it. A check that raises is a refusal too: it runs where the
  facts live, and nothing running there may take them down.
  """
  @spec append(ref(), [assertion()], keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def append(world, assertions, opts \\ []) when is_list(assertions) do
    # `timeout:` is the CALL timeout, for callers whose batches are honestly
    # large — a bulk import's five-thousand-fact append is not hung, it is
    # working, and the default five seconds was sized for a conversation.
    timeout = Keyword.get(opts, :timeout, 5_000)

    case Keyword.get(opts, :check) do
      nil ->
        GenServer.call(world, {:append, assertions}, timeout)

      check when is_function(check, 2) ->
        GenServer.call(world, {:append, assertions, check}, timeout)

      check when is_function(check, 1) ->
        advisory_append(world, assertions, check, timeout)
    end
  end

  # Checked in the caller, then appended — so anything landing in between is
  # not accounted for. Named for what it is.
  defp advisory_append(world, assertions, check, timeout) do
    case check.(assertions) do
      :ok -> GenServer.call(world, {:append, assertions}, timeout)
      {:error, refusals} -> {:error, refusals}
    end
  end

  # ── reading ────────────────────────────────────────────────────────────────

  @doc "The transaction this world is currently at."
  @spec tx(ref()) :: non_neg_integer()
  def tx(world), do: GenServer.call(world, :tx)

  @doc """
  How many facts this world is holding in memory.

  Bounded by `resident:`, with two honest caveats. It is a floor rounded up to
  a transaction boundary, because a transaction is evicted whole or not at all
  — so a fifty-fact write keeps fifty however small the setting. And it only
  saves anything when the facts are durable somewhere else: with the memory
  store, the store *is* the memory.
  """
  @spec resident(ref()) :: non_neg_integer()
  def resident(world), do: GenServer.call(world, :resident)

  @doc """
  Every fact recorded at or before `tx`, oldest first.

  This is the whole reason a snapshot can be a value: the answer here depends
  only on `tx`, so it is the same answer forever.
  """
  @spec facts_at(ref(), non_neg_integer()) :: [Fact.t()]
  def facts_at(world, tx), do: GenServer.call(world, {:facts_at, tx})

  @doc """
  The facts matching a pattern at or before `tx`, oldest first.

  Answered here rather than by scanning what `facts_at/2` returns, for two
  reasons. The obvious one is that a keyed lookup beats a scan. The quieter one
  is that filtering in this process means only the answer crosses the process
  boundary — asking a large world a small question used to copy all of it.
  """
  @spec find_at(ref(), non_neg_integer(), keyword()) :: [Fact.t()]
  def find_at(world, tx, pattern) do
    # Checked here, in the caller's process, because the world is where
    # everybody's facts live and a read must never be able to take it down.
    Fact.fields!(pattern)
    GenServer.call(world, {:find_at, tx, pattern})
  end

  @doc """
  The ids of everything matching a pattern, each one once.

  The same reasoning as `find_at/3` carried one step further. That one keeps the
  filtering here so only the answer crosses the process boundary; this one
  notices that *which entities* is a smaller answer than *which facts*, and that
  a caller walking a world only ever wanted the first. Over 25,000 entities it
  is the difference between copying every fact into the asker and copying one id
  each — which is what decided whether a world that size could be looked at.

  Ids are read off the stored facts without revealing them, because erasure
  seals a fact's value and never its id.
  """
  @spec ids_at(ref(), non_neg_integer(), keyword()) :: [term()]
  def ids_at(world, tx, pattern) do
    Fact.fields!(pattern)
    GenServer.call(world, {:ids_at, tx, pattern})
  end

  @doc "Facts exactly as stored, sealed values and all."
  @spec raw_at(ref(), non_neg_integer()) :: [Fact.t()]
  def raw_at(world, tx), do: GenServer.call(world, {:raw_at, tx})

  @doc "What the store had to do to open. Observability, not vocabulary."
  @spec store_stats(ref()) :: map()
  def store_stats(world), do: GenServer.call(world, :store_stats)

  @doc """
  Which store module keeps this world's facts. Observability, not vocabulary —
  the drill needs it to pull a copy the way the store was shipped, and nothing
  else should ever branch on it.
  """
  @spec store_module(ref()) :: module()
  def store_module(world), do: GenServer.call(world, :store_module)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Trap exits so the store is closed on an ordinary shutdown rather than
    # only when the process is killed.
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    {module, store_opts} = Keyword.get(opts, :store, default_store())
    :ok = migrate_if_ledger(name, module, store_opts)
    {:ok, store} = module.open(name, store_opts)

    # A store that can seek changes what the world holds: the resident tail
    # and the indexes over it, never everything — the store answers for the
    # rest, by pattern, off its own index. A store that cannot is replayed
    # whole, exactly as before.
    paged? = function_exported?(module, :seek, 3)
    residency = Keyword.get(opts, :resident, :unbounded)

    {replayed, resumed, subjects, oldest} =
      if paged? do
        tail = module.tail(store, tail_of(residency))
        last = module.last_tx(store)

        oldest =
          case tail do
            [] -> if last == 0, do: nil, else: last + 1
            [first | _rest] -> first.tx
          end

        # Who each entity belongs to, for ALL time — asked of the store's
        # index rather than rebuilt from a replay the world no longer does.
        # The C4 rule unchanged: this map is never trimmed.
        {tail, last, subjects_of(module.seek(store, [attribute: @subject], last)), oldest}
      else
        replayed = module.replay(store)
        resumed = replayed |> Enum.map(& &1.tx) |> Enum.max(fn -> 0 end)
        {replayed, resumed, subjects_of(replayed), oldest_of(replayed)}
      end

    state =
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
          # Who each entity belongs to, for ALL time. Deliberately not the
          # fact index: subject ownership decides whether a write is sealed,
          # and the index holds only what is resident — so looking ownership
          # up there meant that once an entity's subject fact was evicted,
          # everything written about it after went down in PLAINTEXT, and
          # destroying the key did not erase it (C4, reproduced).
          subjects: subjects,
          oldest: oldest,
          paged?: paged?,
          resident: residency,
          store: store,
          module: module,
          # How long a world with nobody talking to it stays open. Idle
          # eviction closes the process and keeps the file — the same close
          # `World.close/1` performs, arrived at by silence instead of by
          # name. `:infinity` when nobody asked, which is every world that
          # existed before the option did.
          evict_after: Keyword.get(opts, :evict_after, :infinity)
        },
        replayed
      )
      |> trim()

    {:ok, state, state.evict_after}
  end

  # The one-way door, crossed exactly at the seam the World owns: a world
  # opening under SQLite whose `.sqlite` is absent while a `.ledger` exists
  # is a world written before the default flipped — migrate first, then open
  # what the migration wrote. Serialised by construction: only one init ever
  # runs per name (the via-Registry start), so two racing opens cannot both
  # migrate. The ledger is left untouched, the read-only legacy record.
  # Explicit and logged, because a silent migration is a layout change nobody
  # can account for later.
  defp migrate_if_ledger(name, Store.SQLite, store_opts) do
    dir = Keyword.get(store_opts, :dir, "priv/ledgers")

    if not File.exists?(Path.join(dir, Store.SQLite.filename(name))) and
         File.exists?(Path.join(dir, Store.File.filename(name))) do
      {:ok, %{facts: facts, transactions: transactions}} =
        Store.Migrate.ledger_to_sqlite(name, dir: dir)

      require Logger

      Logger.info(
        "world #{inspect(name)}: migrated .ledger to .sqlite " <>
          "(#{facts} facts, #{transactions} transactions); the ledger stays as the legacy record"
      )
    end

    :ok
  end

  defp migrate_if_ledger(_name, _module, _store_opts), do: :ok

  # How many transactions a paged world keeps warm. `resident:` when given —
  # the same knob it always was — and a bound rather than everything when
  # not, because holding everything is the exact behaviour a seeking store
  # exists to end.
  defp tail_of(:unbounded), do: 1_000
  defp tail_of(count) when is_integer(count), do: count

  @impl true
  # The serialized check: run here, on the facts this write is about to land
  # on, in the one process that appends. A check that raises becomes a refusal
  # rather than a crash — this runs where everybody's facts live, and a write
  # that cannot be judged must not be able to destroy the thing it was judging.
  def handle_call({:append, assertions, check}, from, state) do
    case run_check(check, assertions, Enum.reverse(state.facts)) do
      :ok -> handle_call({:append, assertions}, from, state)
      {:error, refusals} -> answer({:error, refusals}, state)
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
        count: state.count + length(facts),
        subjects: remember_subjects(state.subjects, facts)
    }

    answer({:ok, tx}, state |> index(facts) |> trim())
  end

  def handle_call(:tx, _from, state), do: answer(state.tx, state)
  def handle_call(:resident, _from, state), do: answer(state.count, state)
  def handle_call(:store_module, _from, state), do: answer(state.module, state)

  def handle_call({:raw_at, tx}, _from, state) do
    # Through `matching/3` with the empty pattern, so a paged world's evicted
    # transactions answer too — reading only the resident tail silently
    # shortened history the day the world stopped holding all of it.
    answer(matching(state, tx, []), state)
  end

  def handle_call(:store_stats, _from, state) do
    stats =
      if function_exported?(state.module, :stats, 1),
        do: state.module.stats(state.store),
        else: %{}

    answer(stats, state)
  end

  def handle_call({:find_at, tx, pattern}, _from, state) do
    answer(Enum.map(matching(state, tx, pattern), &Erasure.reveal_fact(&1, state.name)), state)
  end

  # Not revealed: an id is never sealed, and revealing a value here would be
  # decrypting the whole world to answer a question that discards it.
  #
  # Sorted and de-duplicated HERE rather than by whoever asked, because this
  # process has no heap limit and the asker usually does. Sorting a hundred
  # thousand ids is the same work either way; doing it here means the guest is
  # handed the finished answer instead of building it under a cap.
  def handle_call({:ids_at, tx, pattern}, _from, state) do
    ids = state |> matching(tx, pattern) |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()
    answer(ids, state)
  end

  def handle_call({:facts_at, tx}, _from, state) do
    facts =
      state
      |> matching(tx, [])
      |> Enum.map(&Erasure.reveal_fact(&1, state.name))

    answer(facts, state)
  end

  # Every reply re-arms the idle clock. `:infinity` for a world nobody asked
  # to evict, which is a plain reply with a longer name.
  defp answer(reply, state), do: {:reply, reply, state, state.evict_after}

  @impl true
  # `evict_after:` elapsed with no reads and no writes: close the same way
  # `World.close/1` closes — terminate runs, the store is released, the file
  # stays. `{:shutdown, _}` so the transient child is not restarted, and so a
  # supervisor report is not written for a world that merely fell asleep.
  def handle_info(:timeout, state), do: {:stop, {:shutdown, :idle}, state}

  def handle_info(_other, state), do: {:noreply, state, state.evict_after}

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

  # Anything older than what is resident has to come from the store.
  defp evicted(%{oldest: nil}, _tx, _pattern), do: []
  defp evicted(%{oldest: oldest}, _tx, _pattern) when oldest <= 1, do: []

  # A seeking store answers by pattern off its own index — one pread per
  # candidate transaction, never a rescan.
  defp evicted(%{paged?: true} = state, tx, pattern) do
    state.module.seek(state.store, pattern, min(tx, state.oldest - 1))
  end

  # A store that cannot seek is re-read whole and filtered here: honest
  # rather than good — the measured thousand-x path the paged store closes.
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
      nil ->
        fact

      subject ->
        # Bound to WHERE it is: this world, this entity, this attribute, this
        # transaction. The binding is what makes a sealed answer worthless
        # anywhere but on the fact it was written for.
        bound = {state.name, fact.id, fact.attribute, fact.tx}
        %{fact | value: Erasure.protect(fact.value, subject, bound)}
    end
  end

  # Answered from the subjects map, never the fact index: ownership is a
  # property of the entity for all time, and the index forgets what eviction
  # takes. The one reader of this decides whether a write is encrypted.
  defp owner_of(state, id), do: Map.get(state.subjects, id)

  defp subjects_of(facts), do: remember_subjects(%{}, facts)

  defp remember_subjects(subjects, facts) do
    Enum.reduce(facts, subjects, fn
      %Fact{attribute: @subject} = fact, acc -> Map.put(acc, fact.id, fact.value)
      _fact, acc -> acc
    end)
  end

  defp oldest_of([]), do: nil
  defp oldest_of(facts), do: facts |> Enum.map(& &1.tx) |> Enum.min()

  # Tell whoever is watching. Only sends — a watcher that called back into this
  # world while it was still replying would deadlock, so it never does.
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
    Registry.dispatch(Blazie.Watchers, name, fn watchers ->
      for {pid, _ref} <- watchers, do: send(pid, {:appended, name, tx, facts})
    end)
  end

  defp to_fact({id, attribute, answer}, tx),
    do: %Fact{id: id, attribute: attribute, value: answer, tx: tx}

  defp to_fact({id, attribute, answer, by}, tx),
    do: %Fact{id: id, attribute: attribute, value: answer, tx: tx, by: by}
end
