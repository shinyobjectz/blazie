defmodule Blazie.Agents do
  @moduledoc """
  The declared agents, running.

  `Blazie.Agent` says what an agent IS — a field declared as produced, with what
  it watches and who it asks. This is what makes one run: a world whose declared
  fields become jobs at boot, the same way `Vitals` and `Storage` do. Without it
  an agent is a shape somebody has to invoke by hand, which is the difference
  between a framework and a folder of functions.

  ## Declarations live in the world they act on

  A field declared in `main` produces facts in `main`, so its runner watches
  `main`. There is no central registry: opening a world and finding fields that
  declare `asks` IS the registry, and it cannot drift from what is actually
  there because it is not a copy.

  ## Nothing is asked until there is something to ask about

  A cadence tick calls `Agent.due/2` first, and an empty work list ends the run
  before a model is reached. That ordering is the whole cost story — a
  generative job that called out on every tick would bill for a world where
  nothing happened.
  """

  use GenServer

  alias Blazie.{Agent, Attribute, Job, Snapshot, World}
  alias Blazie.Job.Generative

  @every 30

  @doc "The attributes an agent world needs before anything can be declared in it."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.seed() ++
      Attribute.requires_seed() ++
      Job.seed() ++
      Generative.seed() ++
      Agent.seed() ++
      Attribute.define("tries_allowed", answers: "integer")
  end

  @doc """
  Every field in this world declared as produced by a model.

  The work list of agents, derived. A field with `asks` is one; a field without
  is an ordinary attribute, and nothing here has to be told the difference.
  """
  @spec declared(Snapshot.t()) :: [String.t()]
  def declared(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find(attribute: "asks")
    |> Enum.map(&to_string(&1.id))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  A job for each declared field, ready for a runner.

  Each is an ordinary `Blazie.Job` whose work asks a model — so the cadence, the
  read set, the failure facts and the sampling are all the machinery that
  already existed. Nothing here is a second runtime.
  """
  @spec jobs(Snapshot.t(), keyword()) :: [Job.t()]
  def jobs(%Snapshot{} = snapshot, opts \\ []) do
    for field <- declared(snapshot) do
      Job.new(field, Agent.work(snapshot, field, opts))
    end
  end

  # ── running them ───────────────────────────────────────────────────────────

  @doc """
  Start a runner over one world's declared agents.

  Built and never started is the same as not built, which this deployment kept
  proving — so this is what the supervision tree runs rather than a module
  somebody has to remember to wire.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :world)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name_for(opts))

  # Opened in `init`, not in a `handle_continue`. A continue runs AFTER
  # `start_link` returns, so the runner would not exist yet for anything that
  # asked for it immediately — including a supervisor's next child. Opening a
  # world and starting a runner is fast, and `Vitals` and `Storage` do it
  # synchronously for the same reason.
  @impl true
  def init(opts) do
    state = Map.new(opts)
    {:ok, world} = World.open(state.world)

    if World.tx(world) == 0 do
      {:ok, _tx} = World.append(world, seed())
    end

    every = Map.get(state, :every, @every)

    # Declarations are read once at boot to build the job list, and re-read on
    # every tick to decide staleness. A field declared later is picked up by
    # `refresh/1` rather than a restart.
    {:ok, runner} =
      Job.Runner.start_link(
        world: world,
        jobs: jobs(Snapshot.open([world]), Map.get(state, :model_opts, [])),
        every: :timer.seconds(every),
        name: runner_for(state.world)
      )

    {:ok, Map.merge(state, %{world: world, runner: runner, name: state.world})}
  end

  @doc """
  Pick up fields declared since this started.

  A declaration is a fact, so a new agent arrives by being written — and this is
  what notices. Called rather than polled, because a world that gains an agent
  once an hour should not be re-read every second to find out.
  """
  @spec refresh(String.t()) :: :ok
  def refresh(world), do: GenServer.call(name_for(world: world), :refresh)

  @impl true
  def handle_call(:refresh, _from, state) do
    for job <- jobs(Snapshot.open([state.world]), Map.get(state, :model_opts, [])) do
      Job.Runner.register(state.runner, job)
    end

    {:reply, :ok, state}
  end

  # Registered through `Blazie.Registry`, never as an atom built from the name.
  # A world name arrives from a request, and an atom is never collected — so
  # `:"#{__MODULE__}.#{world}"` would be a way to exhaust the atom table from
  # the wire, one claimed world at a time. The application moduledoc says this
  # about worlds themselves and it is just as true of anything named after one.
  defp name_for(opts) when is_list(opts), do: name_for(Keyword.fetch!(opts, :world))
  defp name_for(world), do: {:via, Registry, {Blazie.Registry, {__MODULE__, world}}}

  defp runner_for(world), do: {:via, Registry, {Blazie.Registry, {__MODULE__, :runner, world}}}

  @doc "The runner watching one world's agents."
  @spec runner(String.t()) :: GenServer.server()
  def runner(world), do: runner_for(world)
end
