defmodule Blazie.Vitals do
  @moduledoc """
  What this node is doing, recorded as facts.

  Observability is facts, and that has a consequence worth stating: reading the
  clock, the VM, or how many ledgers are open is reaching outside, because the
  answer depends on when you ask. So vitals is a **job**, not a formula — not
  as a workaround, but because it is the same line everything else obeys.

  Being a job pays for itself immediately. Vitals get provenance, a cadence,
  failure records, history, and a scheduler, and none of it is built twice. A
  trend is a query over old readings rather than a time-series database, and
  "when did this node last report" is `Job.last_run/2` like anything else.

      World.append(world, Vitals.declare(every: 60))
      # ... the runner picks it up like any other job ...

  ## What is not here

  No exporter, no metrics endpoint, no dashboards. Facts are the substrate; a
  reader that turns them into whatever a monitoring system wants is an
  application concern, and building one before there is a monitoring system to
  feed would be guessing at its shape.
  """

  alias Blazie.{Attribute, Job, World, Subscription}

  @id "vitals"
  @world "$vitals"

  @doc "The attributes a reading is written with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    # `open_ledgers`, not `open_worlds`. The word moved; this string did not,
    # because it is data — a thousand readings are already written under it, and
    # renaming it would orphan every one while the suite stayed green, since tests
    # write with the same code they read. Storage layout is not vocabulary.
    Attribute.define("open_ledgers", answers: "integer", cardinality: "many") ++
      Attribute.define("subscriptions", answers: "integer", cardinality: "many") ++
      Attribute.define("memory_bytes", answers: "integer", cardinality: "many") ++
      Attribute.define("processes", answers: "integer", cardinality: "many") ++
      Attribute.define("node", answers: "name", cardinality: "many")
  end

  @doc "The world readings are written to."
  @spec world() :: String.t()
  def world, do: @world

  @doc """
  Start the vitals job under a runner, seeding its world if it is new.

  Built and never started is the same as not built, which the deployment kept
  proving — so this is what the supervision tree runs rather than a module
  somebody has to remember to wire.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_runner, [opts]}, type: :worker}
  end

  @doc false
  def start_runner(opts) do
    every = Keyword.get(opts, :every, 60)
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

  @doc "Declare vitals as a job, with how often to take a reading."
  @spec declare(keyword()) :: [tuple()]
  def declare(opts \\ []), do: Job.declare(@id, opts)

  @doc "The job. Its answer is a reading of this moment, which is why it is one."
  @spec job() :: Job.t()
  def job do
    Job.new(@id, fn _snapshot ->
      [
        {@id, "open_ledgers", length(World.open_worlds())},
        {@id, "subscriptions", Subscription.count()},
        {@id, "memory_bytes", :erlang.memory(:total)},
        {@id, "processes", :erlang.system_info(:process_count)},
        {@id, "node", Atom.to_string(node())}
      ]
    end)
  end
end
