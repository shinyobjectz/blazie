defmodule Blazie.Subscription do
  @moduledoc """
  A question the evaluator keeps answering.

  The mechanism was already here: running a question records what it read, and
  a later fact falling inside that read set is what makes the answer stale.
  This holds one of those read sets and pushes when it is touched.

      {:ok, ref} = Subscription.watch([world], attribute: "height")
      # ... a matching fact lands ...
      receive do: ({:blazie, ^ref, answer} -> answer.facts)

  A question is a pattern or a `Blazie.Formula`. Either way the read set is
  what decides: a write outside it pushes nothing, which is what keeps a
  subscription from being a firehose with a filter on the far end.

  ## The answer carries its name

  Every push includes the snapshot name it was answered at, so a subscriber can
  tell exactly which transaction it is looking at, cache on it, and ask the same
  question again later and get the same answer. A subscription is the same
  question asked again as the name advances — not a different mechanism.

  ## It dies with whoever asked

  The subscriber is monitored, so a client that goes away takes its
  subscription with it rather than leaving one pushing into the void.
  """

  use GenServer

  alias Blazie.{Fact, Formula, World, Snapshot}

  @type question :: keyword() | Formula.t()
  @type answer :: %{name: Snapshot.name(), facts: [Fact.t()] | [tuple()]}

  @doc "Watch a question over these ledgers. Answers are pushed to the caller."
  @spec watch([World.name() | World.ref()], question(), keyword()) :: {:ok, reference()}
  def watch(ledgers, question, opts \\ []) do
    to = Keyword.get(opts, :to, self())
    ref = make_ref()

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Blazie.SubscriptionSupervisor,
        {__MODULE__, ledgers: ledgers, question: question, to: to, ref: ref}
      )

    {:ok, ref}
  end

  @doc "Stop watching. Idempotent — a subscription that already went is fine."
  @spec unwatch(reference()) :: :ok
  def unwatch(ref) do
    case Registry.lookup(Blazie.Registry, {:subscription, ref}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    :ok
  end

  @doc "How many subscriptions are live."
  @spec count() :: non_neg_integer()
  def count do
    %{active: active} = DynamicSupervisor.count_children(Blazie.SubscriptionSupervisor)
    active
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :ref)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    ref = Keyword.fetch!(opts, :ref)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Blazie.Registry, {:subscription, ref}}}
    )
  end

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    ledgers = Keyword.fetch!(opts, :ledgers)
    question = Keyword.fetch!(opts, :question)
    to = Keyword.fetch!(opts, :to)
    ref = Keyword.fetch!(opts, :ref)

    Process.monitor(to)

    # Watch the ledgers too, not only the subscriber. A world that closes
    # while somebody is watching it used to arrive as a crash — the next
    # announcement tried to open a snapshot of something that had gone.
    for world <- ledgers do
      Registry.register(Blazie.Watchers, watched_name(world), ref)

      case GenServer.whereis(world) do
        pid when is_pid(pid) -> Process.monitor(pid)
        _ -> :ok
      end
    end

    {:ok,
     %{
       ledgers: ledgers,
       question: question,
       to: to,
       ref: ref,
       reads: reads_of(question, Snapshot.open(ledgers))
     }}
  end

  @impl true
  def handle_info({:appended, _ledger, _tx, facts}, state) do
    if Formula.stale?(state.reads, facts) do
      try do
        snapshot = Snapshot.open(state.ledgers)
        {answered, reads} = answer(state.question, snapshot)

        send(
          state.to,
          {:blazie, state.ref, %{name: Snapshot.name(snapshot), facts: answered}}
        )

        {:noreply, %{state | reads: reads}}
      catch
        # A world went between the announcement and the answer. The monitor
        # will say so; there is nothing to report in the meantime.
        :exit, _ -> {:stop, :normal, state}
      end
    else
      {:noreply, state}
    end
  end

  # Whoever asked has gone, or a world being watched has. Either way there is
  # nothing left to answer — going quietly beats crashing on the next write.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  # ── questions ──────────────────────────────────────────────────────────────

  # Lua, which is what the wire watches. `watch` is a run, kept: the same chunk
  # answered again as the name advances, rather than a second mechanism with its
  # own idea of what a question is.
  #
  # A chunk that writes is answered for its value and its writes are dropped —
  # a subscription re-runs whenever anything it read changes, so a writing
  # subscription would feed itself forever.
  defp answer({:lua, source}, snapshot) do
    case Blazie.Lua.Binding.watching(source, snapshot) do
      {:ok, value, _staged, read} -> {value, read}
      {:error, refusal} -> {%{error: refusal}, []}
    end
  end

  defp answer(%Formula{} = formula, snapshot), do: Formula.run(formula, snapshot)

  defp answer(pattern, snapshot) when is_list(pattern),
    do: {Snapshot.find(snapshot, pattern), [Enum.sort(pattern)]}

  defp reads_of({:lua, _source} = question, snapshot) do
    {_answered, read} = answer(question, snapshot)
    read
  end

  defp reads_of(%Formula{} = formula, snapshot) do
    {_answered, reads} = Formula.run(formula, snapshot)
    reads
  end

  defp reads_of(pattern, _snapshot) when is_list(pattern), do: [Enum.sort(pattern)]

  # A world may be given by name or by the reference `open/1` handed back.
  defp watched_name({:via, Registry, {Blazie.Registry, name}}), do: name
  defp watched_name(name), do: name
end
