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
  @spec new(term(), (Snapshot.t() -> [assertion()]) | (Snapshot.t(), pos_integer() -> [assertion()])) ::
          t()
  def new(id, work) when is_function(work, 1), do: %__MODULE__{id: id, work: work}

  # Arity two is the same job, told which attempt this is. A sampled job wants
  # that — to vary a temperature, or to ask differently after a refusal — and
  # nothing else about it changes, so it is the same constructor rather than a
  # second kind of job.
  def new(id, work) when is_function(work, 2), do: %__MODULE__{id: id, work: work}

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
      {produced, read} = Snapshot.track_reads(fn -> work(job, snapshot) end)
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
  # An unsampled run is the first attempt, which is what `1` means here.
  defp work(%__MODULE__{work: work}, snapshot) do
    if is_function(work, 2), do: work.(snapshot, 1), else: work.(snapshot)
  end

  @doc """
  A job whose body is Lua held in the world.

      {"fetch", "is", "job"}
      {"fetch", "every", 300}
      {"fetch", "source", "rates.gbp = tonumber(http.get('https://…'))"}

  The same shape a formula uses, in the other world: a job gets the real clock
  and `http`, because a job is the only thing handed the outside. That is the
  whole difference between the two, and it is one argument.

  Whatever the chunk writes becomes the job's assertions, and `Job.run/4` stamps
  them — so a guest cannot claim provenance here any more than a wasm one can.
  """
  @spec of_source(term(), String.t()) :: t()
  def of_source(id, source) when is_binary(source) do
    %__MODULE__{
      id: id,
      work: fn snapshot ->
        case Blazie.Lua.Binding.watching(source, snapshot, as: :job, at: System.system_time(:second)) do
          {:ok, _value, staged, read} ->
            Snapshot.record_reads(read)
            Enum.map(staged, fn {entity, field, value} -> {entity, field, value} end)

          {:error, refusal} ->
            raise "job #{inspect(id)} did not run: #{Map.get(refusal, :repair, inspect(refusal))}"
        end
      end
    }
  end

  @doc """
  Every job declared in a snapshot whose body is stored Lua.

  The registry is the world, as it is for formulas and agents. A job arrives by
  being written.
  """
  @spec declared(Snapshot.t()) :: [t()]
  def declared(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find(attribute: "is", value: "job")
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
  The work of a job whose body is an image rather than a function.

  Returns a `work` function, so a sandboxed job IS a job — the runner, the
  cadence, the read set and the failure facts are all the ones that already
  exist, and only what happens inside changes.

  The image is fetched and its hash checked before anything runs. A blob is
  content-addressed, so bytes that do not hash to their key are not a stale
  version, they are somebody else's bytes under this name.
  """
  @spec sandboxed(Snapshot.t(), term(), module(), keyword()) ::
          (Snapshot.t() -> [assertion()])
  def sandboxed(%Snapshot{} = declared, id, target, target_opts) do
    fn snapshot ->
      image = Snapshot.value(declared, id, "image")

      unless match?(%Blazie.Blob{}, image) do
        raise "#{inspect(id)} declares no image to run"
      end

      case Blazie.Blob.fetch(image, target, target_opts) do
        {:error, refusal} ->
          raise refusal.repair

        {:ok, bytes} ->
          run_image(bytes, snapshot, declared, id)
      end
    end
  end

  defp run_image(bytes, snapshot, declared, id) do
    opts =
      for field <- [:fuel, :memory_bytes],
          value = Snapshot.value(declared, id, to_string(field)),
          is_integer(value),
          do: {field, value}

    # A guest gets what the world says, not the world. It cannot hold a
    # snapshot, cannot read past what it was handed, and cannot ask for more —
    # so what it may see is decided out here, where it can be read.
    input = %{"id" => id, "facts" => Blazie.Wire.facts_for(snapshot, id)}

    case Blazie.Sandbox.run(bytes, input, opts) do
      {:ok, answer, spent} ->
        assertions(answer, id) ++ [{id, "fuel_spent", spent.fuel}]

      {:error, refusal} ->
        raise refusal.repair
    end
  end

  # A guest returns a list of three-wide rows. It cannot claim provenance —
  # `Job.run` stamps everything with the job's own id on the way in.
  defp assertions(answer, id) when is_list(answer) do
    Enum.map(answer, fn
      [entity, field, value] -> {entity, field, value}
      %{"id" => entity, "attribute" => field, "value" => value} -> {entity, field, value}
      other -> raise "#{inspect(id)} returned #{inspect(other)}, not [id, field, value]"
    end)
  end

  defp assertions(nil, _id), do: []

  defp assertions(other, id),
    do: raise("#{inspect(id)} returned #{inspect(other)}, not a list of [id, field, value]")

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
