defmodule Blazie.Job.Runner do
  @moduledoc """
  The thing that actually calls `Job.run/4`.

  It holds no work list. The ledger is the queue, so each tick asks which jobs
  are due and runs those — which is why a restart needs no reconciliation and a
  job added while the system runs is picked up without telling anybody.

  ## What it does hold

  Two things the ledger cannot say. **The work**, because a job's cadence is a
  fact but its body is code, so a job has to be registered before the runner
  can run it. And **what is still in flight**, because a slow job must not be
  started again just because its cadence came round — the ledger only learns a
  job ran once it finished.

  A job that the ledger declares and nobody registered is skipped and reported
  by `unclaimed/1`, rather than skipped silently. A gap between what is
  declared and what is deployed is worth being able to see.

  ## Failure is contained twice

  `Job.run/4` already records a raise as a fact rather than propagating it. On
  top of that each job runs in its own task, so a job that dies in a way `run`
  cannot catch takes nothing with it.

  ## Time comes from outside

  `tick/2` takes `now`, which keeps it a pure function of a snapshot and a
  moment. Only the periodic timer reads a clock, which is the one place the
  impurity belongs.
  """

  use GenServer

  alias Blazie.{Job, Ledger, Snapshot}

  @type option ::
          {:ledger, Ledger.name() | Ledger.ref()}
          | {:jobs, [Job.t()]}
          | {:every, pos_integer() | nil}
          | {:name, GenServer.name()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Run everything due at `now`, and return which ones started.

  Started, not finished — jobs run in their own tasks. Ask `in_flight/1` to see
  what has not come back yet.
  """
  @spec tick(GenServer.server(), integer()) :: {:ok, [term()]}
  def tick(runner, now), do: GenServer.call(runner, {:tick, now})

  @doc "Jobs started and not yet finished."
  @spec in_flight(GenServer.server()) :: [term()]
  def in_flight(runner), do: GenServer.call(runner, :in_flight)

  @doc "Jobs the ledger declares that nobody registered work for."
  @spec unclaimed(GenServer.server()) :: [term()]
  def unclaimed(runner), do: GenServer.call(runner, :unclaimed)

  @doc "Register a job's work while the system runs."
  @spec register(GenServer.server(), Job.t()) :: :ok
  def register(runner, %Job{} = job), do: GenServer.call(runner, {:register, job})

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    jobs = opts |> Keyword.get(:jobs, []) |> Map.new(&{&1.id, &1})
    every = Keyword.get(opts, :every)

    if every, do: :timer.send_interval(every, :beat)

    {:ok, %{ledger: ledger, jobs: jobs, running: %{}, unclaimed: [], every: every}}
  end

  @impl true
  def handle_call({:tick, now}, _from, state), do: run_due(state, now)

  def handle_call(:in_flight, _from, state),
    do: {:reply, state.running |> Map.values() |> Enum.sort(), state}

  def handle_call(:unclaimed, _from, state), do: {:reply, Enum.sort(state.unclaimed), state}

  def handle_call({:register, job}, _from, state),
    do: {:reply, :ok, put_in(state.jobs[job.id], job)}

  @impl true
  # The clock is read here and nowhere else.
  def handle_info(:beat, state) do
    {:reply, _started, state} = run_due(state, System.system_time(:second))
    {:noreply, state}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, update_in(state.running, &Map.delete(&1, ref))}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, update_in(state.running, &Map.delete(&1, ref))}

  defp run_due(state, now) do
    snapshot = Snapshot.open([state.ledger])
    due = Job.due(snapshot, now)

    {claimed, unclaimed} = Enum.split_with(due, &Map.has_key?(state.jobs, &1))
    busy = Map.values(state.running)
    startable = Enum.reject(claimed, &(&1 in busy))

    running =
      Enum.reduce(startable, state.running, fn id, acc ->
        job = state.jobs[id]
        ledger = state.ledger

        task =
          Task.async(fn ->
            # A fresh snapshot per job: it may have been waiting behind another.
            Job.run(job, ledger, Snapshot.open([ledger]), now)
          end)

        Map.put(acc, task.ref, id)
      end)

    {:reply, {:ok, Enum.sort(startable)}, %{state | running: running, unclaimed: unclaimed}}
  end
end
