defmodule Blazie.RunningJobsTest do
  @moduledoc """
  Jobs that are built and never started are jobs that do not run.

  This exists because the deployment kept finding the same shape of bug: a
  component written, tested, configured — and absent from the supervision tree,
  so production had none of it. A world with no store, a job runner nobody
  started. The test is whether the thing is *running*, not whether it exists.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Job, World, Snapshot, Vitals}

  test "the formula engine is running" do
    assert pid = Process.whereis(Blazie.Formula.Engine),
           "nothing is running the formula engine, so nothing caches an answer"

    assert Process.alive?(pid)
  end

  test "the running engine answers and caches" do
    world = Blazie.TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    {:ok, _} = World.append(world, [{1, "height", 10}])

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    formula =
      Blazie.Formula.new("running-#{System.unique_integer([:positive])}", fn snapshot ->
        Agent.update(agent, &(&1 + 1))
        for f <- Snapshot.find(snapshot, attribute: "height"), do: {f.id, "doubled", f.value * 2}
      end)

    :ok = Blazie.Formula.Engine.register(Blazie.Formula.Engine, formula)
    snapshot = Snapshot.open([world])

    {:ok, first} = Blazie.Formula.Engine.answer(Blazie.Formula.Engine, formula.id, snapshot)
    {:ok, again} = Blazie.Formula.Engine.answer(Blazie.Formula.Engine, formula.id, snapshot)

    assert first == again
    assert Agent.get(agent, & &1) == 1
  end

  test "the vitals job is running and taking readings" do
    assert pid = Process.whereis(Blazie.Vitals.Runner),
           "nothing is running the vitals job"

    assert Process.alive?(pid)
  end

  test "its world is seeded, so a reading has somewhere to go" do
    {:ok, world} = World.open(Vitals.world())
    snapshot = Snapshot.open([world])

    assert Attribute.defined?(snapshot, "open_ledgers")
    assert Attribute.defined?(snapshot, "every")
  end

  test "vitals is declared as a job with a cadence" do
    {:ok, world} = World.open(Vitals.world())
    snapshot = Snapshot.open([world])

    assert Snapshot.value(snapshot, "vitals", "is") == "job"
    assert is_integer(Snapshot.value(snapshot, "vitals", "every"))
  end

  test "ticking the running runner actually writes a reading" do
    {:ok, world} = World.open(Vitals.world())
    before = length(Snapshot.find(Snapshot.open([world]), id: "vitals", attribute: "node"))

    # A tick refuses a job already in flight, so a previous run still finishing
    # makes `ran` empty and this test fail for a reason that is not a bug.
    # Wait for the runner to be idle before asking it to run again.
    settle(Blazie.Vitals.Runner)

    {:ok, ran} = Job.Runner.tick(Blazie.Vitals.Runner, System.system_time(:second) + 100_000)
    assert "vitals" in ran

    # And wait for the work itself rather than for a fixed budget. `tick`
    # returns what it *started* — the reading lands when the task finishes, and
    # a two-second guess at how long that takes is what made this flake about
    # one run in fifteen.
    settle(Blazie.Vitals.Runner)

    assert length(Snapshot.find(Snapshot.open([world]), id: "vitals", attribute: "node")) >
             before
  end

  # Blocks until the runner has nothing in flight. Polls because "in flight" is
  # the runner's own state and it has no other way to say so.
  defp settle(runner, remaining \\ 200) do
    case {Job.Runner.in_flight(runner), remaining} do
      {[], _} -> :ok
      {busy, 0} -> flunk("runner still busy with #{inspect(busy)}")
      _ -> Process.sleep(25) && settle(runner, remaining - 1)
    end
  end
end
