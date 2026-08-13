defmodule Blazie.Job do
  @moduledoc """
  Declared work that needs the outside world (`job`): fetching, calling a
  hosted model, an agent taking a turn.

  A job is the mirror of a formula, and the asymmetry is the point. A formula
  can be thrown away and rebuilt, so storing its answer is a performance
  choice. A job's answer happened once and cannot be reproduced, so `run/4`
  writes it — there is no version that hands the answer back and lets you
  decide.

  It is also the only thing a schedule can attach to, because it is the only
  thing whose answer depends on when you ask.

  ## Nothing here is a queue

  Cron is an attribute of a job, not a word of its own. Its cadence, the times
  it ran, and the times it failed are all ordinary facts in the world, so the
  scheduler reads the world and there is no second store to keep in step. A
  redeploy mid-flight loses nothing: whatever finished wrote a fact before the
  restart, and `due/2` picks up from there.

  ## Failure is data

  Work that reaches outside fails, so a raise is caught and recorded as a fact
  naming the job rather than propagated. "What is failing, and since when" is a
  question rather than a log search.

  ## Time comes from outside

  Reading a clock is reaching outside, so `now` is an argument here rather than
  something these functions fetch. That keeps `due?/3` a pure function of a
  snapshot and a moment, and confines the impurity to the caller at the edge.

  ## Not yet true

  Doctrine 14 says a formula and a job run in the same sandbox and only the job
  is handed network. Nothing here enforces that — there is no sandbox yet. This
  module is the shape that boundary will sit on, not the boundary.
  """

  alias Blazie.{Attribute, Snapshot, World}

  @enforce_keys [:id, :work]
  defstruct [:id, :work]

  @type t :: %__MODULE__{id: term(), work: (Snapshot.t() -> [assertion()])}
  @type assertion :: {term(), String.t(), term()}

  @doc "The attributes a job describes itself with, defined the ordinary way."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Attribute.define("every", answers: "integer") ++
      Attribute.define("ran_at", answers: "integer", cardinality: "many") ++
      Attribute.define("failed", answers: "any", cardinality: "many") ++
      Attribute.define("reads", answers: "any", cardinality: "many")
  end

  @doc "Declare a job. Nothing runs."
  @spec new(term(), (Snapshot.t() -> [assertion()])) :: t()
  def new(id, work) when is_function(work, 1), do: %__MODULE__{id: id, work: work}

  @doc """
  The facts that declare a job and its cadence.

      declare(:refresh_feed, every: 3600)

  A job with no cadence is declared but never due — it runs when something asks
  it to.
  """
  @spec declare(term(), keyword()) :: [assertion()]
  def declare(id, opts \\ []) do
    case Keyword.get(opts, :every) do
      nil -> [{id, "is", "job"}]
      seconds -> [{id, "is", "job"}, {id, "every", seconds}]
    end
  end

  @doc """
  Run the job and write what happened.

  On success the job's facts land alongside a `ran_at`. On failure the reason
  lands alongside a `ran_at` too, because a job that failed still ran. Either
  way the answer is durable, since nothing can rebuild it.
  """
  @spec run(t(), World.ref(), Snapshot.t(), integer()) ::
          {:ok, pos_integer()} | {:failed, pos_integer(), String.t()}
  def run(%__MODULE__{} = job, world, %Snapshot{} = snapshot, now) do
    try do
      {produced, read} = Snapshot.track_reads(fn -> job.work.(snapshot) end)
      assertions = Enum.map(produced, &stamp(&1, job.id))

      # The read set is written, not held. A runner that kept it in memory
      # would forget on restart why a job was ever going to fire, and the
      # property this runner has — that a restart needs no reconciliation —
      # would quietly stop being true.
      {:ok, tx} =
        World.append(
          world,
          assertions ++ reads(job.id, read) ++ [{job.id, "ran_at", now, job.id}]
        )

      {:ok, tx}
    rescue
      error ->
        reason = Exception.message(error)

        {:ok, tx} =
          World.append(world, [
            {job.id, "failed", reason, job.id},
            {job.id, "ran_at", now, job.id}
          ])

        {:failed, tx, reason}
    end
  end

  @doc "When this job last ran, or nil."
  @spec last_run(Snapshot.t(), term()) :: integer() | nil
  def last_run(%Snapshot{} = snapshot, id) do
    snapshot
    |> Snapshot.find(id: id, attribute: "ran_at")
    |> Enum.map(& &1.value)
    |> Enum.max(fn -> nil end)
  end

  @doc """
  Is this job due at `now`?

  Due when it has a cadence and has either never run or not run within it. A
  job without a cadence is never due on its own.
  """
  @spec due?(Snapshot.t(), term(), integer()) :: boolean()
  def due?(%Snapshot{} = snapshot, id, now) do
    cadence_due?(snapshot, id, now) or touched?(snapshot, id)
  end

  defp cadence_due?(snapshot, id, now) do
    case Snapshot.value(snapshot, id, "every") do
      nil -> false
      every -> due_by?(last_run(snapshot, id), every, now)
    end
  end

  # The other way to be due: something this job read has changed since it ran.
  #
  # This is the dependency graph, and it is observed rather than declared —
  # exactly as a formula's is. A job that reads what another job writes fires
  # after it, and nobody wrote the edge down, so nobody can write it down wrong.
  #
  # A job with no recorded reads is never stale, which is what makes this
  # additive: every job that only ever had a cadence still only has a cadence.
  defp touched?(%Snapshot{} = snapshot, id) do
    case read_set(snapshot, id) do
      [] ->
        false

      reads ->
        since = ran_at_tx(snapshot, id)

        # Asked pattern by pattern, so the world answers from its index. The
        # first version of this read EVERY fact and filtered here, which made a
        # staleness check cost the size of the world — per job, per tick. A
        # reactive system whose trigger is O(everything) is a reactive system
        # that gets turned off.
        Enum.any?(reads, fn pattern ->
          snapshot
          |> Snapshot.find(pattern)
          # Facts the job itself wrote do not make it stale. Without this a job
          # that reads what it writes re-fires forever, which is a loop that
          # looks like a working reactive system for about a minute.
          |> Enum.any?(&(&1.tx > since and &1.by != id))
        end)
    end
  end

  defp read_set(%Snapshot{} = snapshot, id) do
    snapshot
    |> Snapshot.find(id: id, attribute: "reads")
    |> Enum.map(& &1.value)
    |> Enum.map(&decode_read/1)
  end

  defp ran_at_tx(%Snapshot{} = snapshot, id) do
    snapshot
    |> Snapshot.find(id: id, attribute: "ran_at")
    |> Enum.map(& &1.tx)
    |> Enum.max(fn -> 0 end)
  end

  # A read is a keyword pattern. It goes into a fact as a map, because a fact
  # value crosses a wire and a keyword list does not survive JSON.
  defp reads(id, read_set) do
    read_set
    |> Enum.uniq()
    |> Enum.map(fn pattern ->
      {id, "reads", Map.new(pattern, fn {key, value} -> {to_string(key), value} end), id}
    end)
  end

  defp decode_read(pattern) when is_map(pattern) do
    Enum.map(pattern, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp decode_read(pattern) when is_list(pattern), do: pattern
  defp decode_read(_other), do: []

  @doc """
  Every job due at `now`, read out of the world.

  This is the whole scheduler: there is no queue, no separate store, and
  nothing to reconcile after a restart.
  """
  @spec due(Snapshot.t(), integer()) :: [term()]
  def due(%Snapshot{} = snapshot, now) do
    snapshot
    |> Snapshot.find(attribute: "is", value: "job")
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.filter(&due?(snapshot, &1, now))
  end

  @doc "Everything this job has failed with, oldest first."
  @spec failures(Snapshot.t(), term()) :: [term()]
  def failures(%Snapshot{} = snapshot, id) do
    snapshot |> Snapshot.find(id: id, attribute: "failed") |> Enum.map(& &1.value)
  end

  defp due_by?(nil, _every, _now), do: true
  defp due_by?(last, every, now), do: now - last >= every

  defp stamp({id, attribute, value}, by), do: {id, attribute, value, by}
  defp stamp({id, attribute, value, _by}, by), do: {id, attribute, value, by}
end
