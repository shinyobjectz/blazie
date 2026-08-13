defmodule Blazie.Storage do
  @moduledoc """
  What each world is costing on disk, recorded as facts.

  A reading, not a gauge — the same reasoning as vitals. Asking how large a file
  is reaches outside: the answer depends on when you ask. So this is a **job**,
  and being one pays for itself immediately. Storage gets provenance, a cadence,
  history and a scheduler, and "how fast is this world growing" is a query over
  old readings rather than a second time-series to keep.

      World.append(world, Storage.declare(every: 300))

  ## One entity per world

  A reading is written against the world's own name, so `main.bytes` is how big
  `main` is and `each { bytes = true }` is every world with a size. That makes
  the storage page the same shape as the data page — entities and fields — with
  nothing new to render and no shape a console has to know about.

  Only worlds that are open are measured, because a closed world has no process
  to ask and reading the directory would report files this node may not own.
  That is a real limit and it is stated rather than hidden: what is here is what
  the node is holding, not everything on the disk.
  """

  alias Blazie.{Attribute, Job, World}

  @world "$storage"
  @every 300

  @doc "The world these readings go into."
  @spec world() :: String.t()
  def world, do: @world

  @doc "The attributes a reading is written with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Attribute.define("bytes", answers: "integer", cardinality: "many") ++
      Attribute.define("transactions", answers: "integer", cardinality: "many") ++
      Attribute.define("checkpoint_bytes", answers: "integer", cardinality: "many") ++
      Attribute.define("resident", answers: "integer", cardinality: "many")
  end

  @doc "Declare the job, with the cadence it should run at."
  @spec declare(keyword()) :: [{String.t(), String.t(), term()}]
  def declare(opts \\ []), do: Job.declare("storage", opts)

  @doc """
  The job. Its answer is what the disk held at one moment, which is why it is one.
  """
  @spec job() :: Job.t()
  def job do
    Job.new("storage", fn _snapshot ->
      Enum.flat_map(World.open_worlds(), &reading/1)
    end)
  end

  # A world that closed between being listed and being asked is skipped rather
  # than crashing the run. Everything else in the round is still worth writing.
  defp reading(name) do
    ref = World.via(name)
    stats = World.store_stats(ref)

    [
      {name, "bytes", Map.get(stats, :bytes, 0)},
      {name, "transactions", World.tx(ref)},
      {name, "resident", World.resident(ref)}
    ] ++
      case Map.get(stats, :checkpoint_bytes) do
        nil -> []
        bytes -> [{name, "checkpoint_bytes", bytes}]
      end
  catch
    :exit, _ -> []
  end

  # ── running it ─────────────────────────────────────────────────────────────

  @doc """
  Start the storage job under a runner, seeding its world if it is new.

  Built and never started is the same as not built, which this deployment kept
  proving — so this is what the supervision tree runs rather than a module
  somebody has to remember to wire.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_runner, [opts]}, type: :worker}
  end

  @doc false
  def start_runner(opts) do
    every = Keyword.get(opts, :every, @every)
    {:ok, world} = World.open(@world)

    if World.tx(world) == 0 do
      World.append(world, Attribute.seed() ++ Job.seed() ++ seed() ++ declare(every: every))
    end

    Job.Runner.start_link(
      world: world,
      jobs: [job()],
      every: :timer.seconds(every),
      name: __MODULE__.Runner
    )
  end
end
