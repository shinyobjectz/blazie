defmodule LazyRiver.Job.RunnerTest do
  @moduledoc """
  The thing that actually calls `Job.run/4`.

  The ledger is the queue, so the runner holds no work list — it asks which
  jobs are due and runs those. What it does hold is which are still in flight,
  because a job that is slow must not be started again just because its cadence
  came round.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Job, Ledger, Snapshot, TestLedger}
  alias LazyRiver.Job.Runner

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed() ++ Job.seed())
    %{ledger: ledger}
  end

  defp start_runner(ledger, jobs) do
    start_supervised!(
      {Runner, ledger: ledger, jobs: jobs, name: :"runner_#{System.unique_integer([:positive])}"}
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

  describe "the runner runs what the ledger says is due" do
    test "a due job runs and writes its facts", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, Job.declare("fetch", every: 100))
      {:ok, _} = Ledger.append(ledger, Attribute.define("headline"))

      runner = start_runner(ledger, [counter_job("fetch", agent)])
      assert {:ok, ["fetch"]} = Runner.tick(runner, 1000)
      settle(runner)

      assert Agent.get(agent, & &1) == 1
      assert Snapshot.answer(Snapshot.open([ledger]), "fetch", "headline") == "ran"
    end

    test "a job that is not due does not run", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, Job.declare("fetch", every: 100))
      {:ok, _} = Ledger.append(ledger, Attribute.define("headline"))

      runner = start_runner(ledger, [counter_job("fetch", agent)])
      assert {:ok, ["fetch"]} = Runner.tick(runner, 1000)
      settle(runner)

      # Ran at 1000, cadence 100, so nothing is due at 1050.
      assert {:ok, []} = Runner.tick(runner, 1050)
      settle(runner)

      assert Agent.get(agent, & &1) == 1
    end

    test "it becomes due again once the cadence passes", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, Job.declare("fetch", every: 100))
      {:ok, _} = Ledger.append(ledger, Attribute.define("headline"))

      runner = start_runner(ledger, [counter_job("fetch", agent)])
      Runner.tick(runner, 1000)
      settle(runner)
      Runner.tick(runner, 1200)
      settle(runner)

      assert Agent.get(agent, & &1) == 2
    end

    test "a job with no cadence is never picked up", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, Job.declare("on_demand"))

      runner = start_runner(ledger, [counter_job("on_demand", agent)])

      assert {:ok, []} = Runner.tick(runner, 999_999)
      assert Agent.get(agent, & &1) == 0
    end
  end

  describe "a slow job is not started twice" do
    test "a job still in flight is skipped", %{ledger: ledger} do
      {:ok, gate} = Agent.start_link(fn -> :closed end)
      {:ok, _} = Ledger.append(ledger, Job.declare("slow", every: 1))
      {:ok, _} = Ledger.append(ledger, Attribute.define("headline"))

      slow =
        Job.new("slow", fn _ ->
          Enum.reduce_while(1..400, nil, fn _, _ ->
            if Agent.get(gate, & &1) == :open, do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
          end)

          [{"slow", "headline", "done"}]
        end)

      runner = start_runner(ledger, [slow])

      assert {:ok, ["slow"]} = Runner.tick(runner, 1000)
      assert Runner.in_flight(runner) == ["slow"]

      # Due again by cadence, but already running.
      assert {:ok, []} = Runner.tick(runner, 2000)

      Agent.update(gate, fn _ -> :open end)
      settle(runner)

      assert Runner.in_flight(runner) == []
      assert Snapshot.answer(Snapshot.open([ledger]), "slow", "headline") == "done"
    end
  end

  describe "a failing job does not take the runner with it" do
    test "the failure is recorded and the runner keeps going", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Job.declare("broken", every: 100))
      broken = Job.new("broken", fn _ -> raise "the endpoint is down" end)

      runner = start_runner(ledger, [broken])
      assert {:ok, ["broken"]} = Runner.tick(runner, 1000)
      settle(runner)

      assert Process.alive?(GenServer.whereis(runner))
      assert [reason] = Job.failures(Snapshot.open([ledger]), "broken")
      assert reason =~ "the endpoint is down"
    end

    test "and it is due again next time, because failing still counts as running",
         %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Job.declare("broken", every: 100))
      broken = Job.new("broken", fn _ -> raise "still down" end)

      runner = start_runner(ledger, [broken])
      Runner.tick(runner, 1000)
      settle(runner)

      assert {:ok, []} = Runner.tick(runner, 1050)
      assert {:ok, ["broken"]} = Runner.tick(runner, 1200)
      settle(runner)

      assert length(Job.failures(Snapshot.open([ledger]), "broken")) == 2
    end
  end

  describe "a job the ledger declares but nobody registered" do
    test "is skipped and said so, rather than skipped silently", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Job.declare("nobody_wrote_this", every: 100))

      runner = start_runner(ledger, [])

      assert {:ok, []} = Runner.tick(runner, 1000)
      assert Runner.unclaimed(runner) == ["nobody_wrote_this"]
    end
  end
end
