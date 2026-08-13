defmodule Blazie.Job.RunnerTest do
  @moduledoc """
  The thing that actually calls `Job.run/4`.

  The world is the queue, so the runner holds no work list — it asks which
  jobs are due and runs those. What it does hold is which are still in flight,
  because a job that is slow must not be started again just because its cadence
  came round.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Job, World, Snapshot, TestLedger}
  alias Blazie.Job.Runner

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Job.seed())
    %{world: world}
  end

  defp start_runner(world, jobs) do
    start_supervised!(
      {Runner, world: world, jobs: jobs, name: :"runner_#{System.unique_integer([:positive])}"}
    )
  end

  defp settle(runner) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      if Runner.in_flight(runner) == [], do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
    end)
  end

  defp counter_job(id, agent) do
    Job.new(id, fn _snapshot ->
      Agent.update(agent, &(&1 + 1))
      [{id, "headline", "ran"}]
    end)
  end

  describe "the runner runs what the world says is due" do
    test "a due job runs and writes its facts", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, Job.declare("fetch", every: 100))
      {:ok, _} = World.append(world, Attribute.define("headline"))

      runner = start_runner(world, [counter_job("fetch", agent)])
      assert {:ok, ["fetch"]} = Runner.tick(runner, 1000)
      settle(runner)

      assert Agent.get(agent, & &1) == 1
      assert Snapshot.value(Snapshot.open([world]), "fetch", "headline") == "ran"
    end

    test "a job that is not due does not run", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, Job.declare("fetch", every: 100))
      {:ok, _} = World.append(world, Attribute.define("headline"))

      runner = start_runner(world, [counter_job("fetch", agent)])
      assert {:ok, ["fetch"]} = Runner.tick(runner, 1000)
      settle(runner)

      # Ran at 1000, cadence 100, so nothing is due at 1050.
      assert {:ok, []} = Runner.tick(runner, 1050)
      settle(runner)

      assert Agent.get(agent, & &1) == 1
    end

    test "it becomes due again once the cadence passes", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, Job.declare("fetch", every: 100))
      {:ok, _} = World.append(world, Attribute.define("headline"))

      runner = start_runner(world, [counter_job("fetch", agent)])
      Runner.tick(runner, 1000)
      settle(runner)
      Runner.tick(runner, 1200)
      settle(runner)

      assert Agent.get(agent, & &1) == 2
    end

    test "a job with no cadence is never picked up", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, Job.declare("on_demand"))

      runner = start_runner(world, [counter_job("on_demand", agent)])

      assert {:ok, []} = Runner.tick(runner, 999_999)
      assert Agent.get(agent, & &1) == 0
    end
  end

  describe "a slow job is not started twice" do
    test "a job still in flight is skipped", %{world: world} do
      {:ok, gate} = Agent.start_link(fn -> :closed end)
      {:ok, _} = World.append(world, Job.declare("slow", every: 1))
      {:ok, _} = World.append(world, Attribute.define("headline"))

      slow =
        Job.new("slow", fn _ ->
          Enum.reduce_while(1..400, nil, fn _, _ ->
            if Agent.get(gate, & &1) == :open, do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
          end)

          [{"slow", "headline", "done"}]
        end)

      runner = start_runner(world, [slow])

      assert {:ok, ["slow"]} = Runner.tick(runner, 1000)
      assert Runner.in_flight(runner) == ["slow"]

      # Due again by cadence, but already running.
      assert {:ok, []} = Runner.tick(runner, 2000)

      Agent.update(gate, fn _ -> :open end)
      settle(runner)

      assert Runner.in_flight(runner) == []
      assert Snapshot.value(Snapshot.open([world]), "slow", "headline") == "done"
    end
  end

  describe "a failing job does not take the runner with it" do
    test "the failure is recorded and the runner keeps going", %{world: world} do
      {:ok, _} = World.append(world, Job.declare("broken", every: 100))
      broken = Job.new("broken", fn _ -> raise "the endpoint is down" end)

      runner = start_runner(world, [broken])
      assert {:ok, ["broken"]} = Runner.tick(runner, 1000)
      settle(runner)

      assert Process.alive?(GenServer.whereis(runner))
      assert [reason] = Job.failures(Snapshot.open([world]), "broken")
      assert reason =~ "the endpoint is down"
    end

    test "and it is due again next time, because failing still counts as running",
         %{world: world} do
      {:ok, _} = World.append(world, Job.declare("broken", every: 100))
      broken = Job.new("broken", fn _ -> raise "still down" end)

      runner = start_runner(world, [broken])
      Runner.tick(runner, 1000)
      settle(runner)

      assert {:ok, []} = Runner.tick(runner, 1050)
      assert {:ok, ["broken"]} = Runner.tick(runner, 1200)
      settle(runner)

      assert length(Job.failures(Snapshot.open([world]), "broken")) == 2
    end
  end

  describe "a job the world declares but nobody registered" do
    test "is skipped and said so, rather than skipped silently", %{world: world} do
      {:ok, _} = World.append(world, Job.declare("nobody_wrote_this", every: 100))

      runner = start_runner(world, [])

      assert {:ok, []} = Runner.tick(runner, 1000)
      assert Runner.unclaimed(runner) == ["nobody_wrote_this"]
    end
  end
end
