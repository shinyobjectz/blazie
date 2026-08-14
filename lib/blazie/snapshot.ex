defmodule Blazie.Snapshot do
  @moduledoc """
  One or more ledgers read at a transaction (`snp`).

  A snapshot is what you hold and compute over — the argument to a question,
  never the endpoint of one. Composing ledgers is the only operation that
  crosses a world boundary, which is why nothing can leak across one by
  accident: you get what you opened and nothing else.

  A caller outside the cluster does not hold the bytes. It holds the
  snapshot's `name/1` — which ledgers, at which transaction — and asks
  questions of it. The part that matters survives the wire: an answer at a
  named snapshot is the same answer forever, so a client caches on
  `{name, question}` and never invalidates.
  """

  alias Blazie.{Fact, World}

  @enforce_keys [:at]
  defstruct [:at]

  @type refusal :: %{problem: atom(), repair: String.t()}

  @typedoc """
  Which ledgers, at which transaction — keyed by **what each world is called**,
  never by where it currently lives.

  Those were different maps until they were not allowed to be. A snapshot named
  by process addresses is not something JSON can carry, not something a caller
  can send back, and not the same map after a restart — so every layer that
  handed one outwards translated it first, and `watch` crashed on every real
  push because one of them forgot. One meaning, one shape, and the translations
  are gone.
  """
  @type name :: %{World.name() => non_neg_integer()}
  @type t :: %__MODULE__{at: name()}

  @doc """
  Open a snapshot over these ledgers, at wherever each one currently is.

  Authorization belongs here and nowhere else: which ledgers a caller may open
  is the whole of it. Not row rules, not predicates.
  """
  @spec open([World.ref()]) :: t()
  def open(ledgers) when is_list(ledgers) do
    %__MODULE__{at: Map.new(ledgers, &{World.name_of(&1), World.tx(&1)})}
  end

  @doc "The snapshot's name — small, stable, and safe to hand to a caller."
  @spec name(t()) :: name()
  def name(%__MODULE__{at: at}), do: at

  @doc """
  Reopen a snapshot from a name. The same name is the same snapshot.

  A name arrives from outside here, so nothing in it is trusted: an address
  handed in where a name belongs is normalised, and every transaction is
  checked against where its world actually is. A name pinned to a transaction
  that has not happened yet is not a snapshot — it silently means "everything,
  so far", which changes as the world moves, and a client that cached on it
  per the documented advice would hold an answer that goes stale in a
  direction whoever minted the name controls. Refused, never clamped:
  clamping would reintroduce the same lie at the clamp.

  A world this node cannot reach is refused for the same reason — a bound
  nobody can check is not a bound.
  """
  @spec reopen(name()) :: {:ok, t()} | {:error, refusal()}
  def reopen(at) when is_map(at) do
    named = Map.new(at, fn {world, tx} -> {World.name_of(world), tx} end)

    named
    |> Enum.find_value(fn {world, tx} ->
      case current(world) do
        {:ok, now} when is_integer(tx) and tx >= 0 and tx <= now -> nil
        {:ok, now} -> future(world, tx, now)
        :closed -> closed(world)
      end
    end)
    |> case do
      nil -> {:ok, %__MODULE__{at: named}}
      refusal -> {:error, refusal}
    end
  end

  @doc """
  `reopen/1` for a caller holding a name it derived from a live snapshot.

  The check still runs — a raise here is a caller's bug, not input — so there
  is no path around the bound, only a louder way to hit it.
  """
  @spec reopen!(name()) :: t()
  def reopen!(at) do
    case reopen(at) do
      {:ok, snapshot} -> snapshot
      {:error, refusal} -> raise ArgumentError, refusal.repair
    end
  end

  defp current(world) do
    {:ok, World.tx(World.via(world))}
  catch
    :exit, _ -> :closed
  end

  defp future(world, tx, now) do
    %{
      problem: :not_yet_a_transaction,
      repair:
        "#{inspect(world)} is at transaction #{now} and this name pins #{inspect(tx)}. " <>
          "A name may only pin a moment that has happened — one from the future is not a " <>
          "snapshot, it is 'everything so far', which changes. Take a name from a snapshot " <>
          "you actually opened."
    }
  end

  defp closed(world) do
    %{
      problem: :world_not_open,
      repair:
        "#{inspect(world)} is not open on this node, so nothing can check what this name " <>
          "pins against where the world actually is. Open the world, then reopen the name."
    }
  end

  @doc "Every fact visible in this snapshot, oldest first across all ledgers."
  @spec facts(t()) :: [Fact.t()]
  def facts(%__MODULE__{at: at}) do
    at
    |> Enum.flat_map(fn {world, tx} -> World.facts_at(World.via(world), tx) end)
    |> Enum.sort_by(& &1.tx)
  end

  @doc """
  The facts matching a pattern. An absent key is a wildcard.

      find(snapshot, id: 42)
      find(snapshot, attribute: :height)
      find(snapshot, id: 42, attribute: :height)

  This is the read a formula will make, which is why it is a pattern rather
  than a language: the evaluator can record what a question read, and that
  read set is what tells it when to answer again.
  """
  @spec find(t(), keyword()) :: [Fact.t()]
  def find(%__MODULE__{at: at}, pattern) do
    Fact.fields!(pattern)
    record_read(pattern)

    at
    |> Enum.flat_map(fn {world, tx} -> World.find_at(World.via(world), tx, pattern) end)
    |> Enum.sort_by(& &1.tx)
  end

  @doc """
  The ids matching a pattern, sorted, each one once.

  `find/2` with everything but the id thrown away, except that the throwing away
  happens in the world rather than here — so walking a large world costs one id
  per entity instead of every fact it holds. It records the same read, because
  it read the same thing: what came back is smaller, not narrower.

  Sorted so that a caller iterating it does not have to be, which matters more
  than it sounds: the caller is usually a guest under a heap limit, and sorting
  a hundred thousand ids there was itself enough to exceed one.
  """
  @spec ids(t(), keyword()) :: [term()]
  def ids(%__MODULE__{at: at}, pattern) do
    Fact.fields!(pattern)
    record_read(pattern)

    case Map.to_list(at) do
      # One world has already answered with each id once, in order. Merging that
      # with nothing costs a second copy of the whole answer and a map to prove
      # what was already true, which over a large world is the single largest
      # thing the asker allocates.
      [{world, tx}] ->
        World.ids_at(World.via(world), tx, pattern)

      several ->
        several
        |> Enum.flat_map(fn {world, tx} -> World.ids_at(World.via(world), tx, pattern) end)
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  @doc """
  The current value for an id's attribute, or nil.

  Current means latest: nothing is rewritten, so a later fact corrects an
  earlier one and the correction is simply the one with the higher transaction.
  """
  @spec value(t(), term(), String.t()) :: term() | nil
  def value(%__MODULE__{} = snapshot, id, attribute) do
    snapshot
    |> find(id: id, attribute: attribute)
    |> List.last()
    |> case do
      nil -> nil
      fact -> fact.value
    end
  end

  # ── read tracking ──────────────────────────────────────────────────────────
  #
  # What a question read is what tells the evaluator when to answer it again.
  # Tracking is process-local and off by default, so an ordinary read costs a
  # `Process.get/1` and nothing else — only a formula turns it on.

  @reads :blazie_reads

  # Past this many distinct reads, the set stops naming facts and starts naming
  # attributes. See `widen/1` — the number only decides where that happens, and
  # is small because a read set larger than this was never going to be read by a
  # person or checked cheaply by a runner.
  @many 256

  @doc """
  Run `fun`, and return what it returned alongside every pattern it read.

  This is the whole of re-execution: record the read set, and when a later fact
  falls inside it, answer again.

  A set, and a bounded one. It used to be a list appended to on every read,
  which made it as large as the data: a walk over 12,000 entities reading one
  field produced 12,005 patterns saying "I read `n` of e1", "I read `n` of
  e2" — 216,000 words to say `n`. That was two problems wearing one coat. It
  was enough by itself to exhaust a guest's heap, and it was a read set nothing
  could use, because `Job.touched?/2` asks the world once per pattern and would
  have run 12,005 queries on every tick to decide whether to do anything.
  """
  @spec track_reads((-> result)) :: {result, [keyword()]} when result: term()
  def track_reads(fun) when is_function(fun, 0) do
    outer = Process.put(@reads, MapSet.new())

    try do
      result = fun.()
      {result, @reads |> Process.get() |> Enum.sort()}
    after
      if outer, do: Process.put(@reads, outer), else: Process.delete(@reads)
    end
  end

  @doc """
  Record patterns read somewhere else as read here.

  A Lua guest runs in a process of its own, so what it read lands in ITS
  dictionary and `track_reads/1` — which watches the caller's — sees nothing. A
  formula whose read set came back empty would never be stale, which is worse
  than being slow: it would answer once and never notice the world had moved.

  So the guest hands its reads back and they are merged here. Only ever called
  with a read set that was genuinely observed; inventing one would make a
  formula re-run for writes it never looked at.
  """
  @spec record_reads([keyword()]) :: :ok
  def record_reads(patterns) when is_list(patterns) do
    if held = Process.get(@reads) do
      Process.put(@reads, Enum.reduce(patterns, held, &remember(&2, Enum.sort(&1))))
    end

    :ok
  end

  defp record_read(pattern) do
    case Process.get(@reads) do
      nil -> :ok
      seen -> Process.put(@reads, remember(seen, Enum.sort(pattern)))
    end
  end

  defp remember(seen, pattern) do
    cond do
      # Already covered. `[]` is the pattern `each {}` records — no constraint,
      # every fact — so once it is in the set nothing can be added that it does
      # not already match. A walk over every entity genuinely does depend on
      # everything, and saying so in one pattern is both smaller and truer than
      # saying it in twelve thousand.
      MapSet.member?(seen, []) -> seen
      MapSet.member?(seen, widest(pattern)) -> seen
      MapSet.size(seen) < @many -> MapSet.put(seen, pattern)
      true -> widen(MapSet.put(seen, pattern))
    end
  end

  # Remember WHICH ATTRIBUTES were read rather than which facts.
  #
  # Strictly broader, and that is the direction it has to err in: a wider read
  # set means answering again more often than strictly necessary, where a
  # narrower one would mean missing a change. So the bound costs re-runs at
  # worst, never a stale answer — and it makes the set the size of the
  # vocabulary instead of the size of the data.
  defp widen(seen) do
    widened = MapSet.new(seen, &widest/1)
    if MapSet.member?(widened, []), do: MapSet.new([[]]), else: widened
  end

  # A pattern with no attribute cannot be generalised to one, so it generalises
  # to everything — which is what reading a whole entity actually did.
  defp widest(pattern) do
    case Keyword.get(pattern, :attribute) do
      nil -> []
      attribute -> [attribute: attribute]
    end
  end
end
