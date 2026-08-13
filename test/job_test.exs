defmodule Blazie.JobTest do
  @moduledoc """
  The doctrine, executable — the outside world happens once, only a job has a
  schedule, and there is no queue anywhere.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Fact, Job, World, Snapshot, Attribute}
  alias Blazie.TestLedger

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Job.seed())
    %{world: world}
  end

  defp fetcher(answer \\ "hello") do
    Job.new(:fetch, fn _snapshot -> [{42, "headline", answer}] end)
  end

  describe "what came from outside happened once" do
    test "a job writes its answer rather than handing it back", %{world: world} do
      assert {:ok, tx} = Job.run(fetcher(), world, Snapshot.open([world]), 1000)

      landed = World.facts_at(world, tx) |> Enum.filter(&(&1.tx == tx))
      assert %Fact{attribute: "headline", value: "hello", by: :fetch} = hd(landed)
    end

    test "every fact a job wrote names it, so it cannot be rebuilt", %{world: world} do
      {:ok, _} = Job.run(fetcher(), world, Snapshot.open([world]), 1000)
      snapshot = Snapshot.open([world])

      for fact <- Snapshot.find(snapshot, by: :fetch) do
        refute Fact.from_outside?(fact)
        assert fact.by == :fetch
      end
    end

    test "running twice records both, because both happened", %{world: world} do
      {:ok, _} = Job.run(fetcher("first"), world, Snapshot.open([world]), 1000)
      {:ok, _} = Job.run(fetcher("second"), world, Snapshot.open([world]), 2000)

      snapshot = Snapshot.open([world])
      assert length(Snapshot.find(snapshot, id: 42, attribute: "headline")) == 2
      assert Snapshot.value(snapshot, 42, "headline") == "second"
    end
  end

  describe "failure is data" do
    setup do
      %{broken: Job.new(:broken, fn _ -> raise "the endpoint is down" end)}
    end

    test "a raise is recorded, not propagated", %{world: world, broken: broken} do
      assert {:failed, _tx, reason} = Job.run(broken, world, Snapshot.open([world]), 1000)
      assert reason =~ "the endpoint is down"
    end

    test "what is failing is a question", %{world: world, broken: broken} do
      {:failed, _, _} = Job.run(broken, world, Snapshot.open([world]), 1000)

      assert [reason] = Job.failures(Snapshot.open([world]), :broken)
      assert reason =~ "the endpoint is down"
    end

    test "a job that failed still ran", %{world: world, broken: broken} do
      {:failed, _, _} = Job.run(broken, world, Snapshot.open([world]), 1000)

      assert Job.last_run(Snapshot.open([world]), :broken) == 1000
    end
  end

  describe "only a job has a schedule, and the world is the queue" do
    test "cadence is a fact, not a field", %{world: world} do
      {:ok, _} = World.append(world, Job.declare(:fetch, every: 3600))

      assert Snapshot.value(Snapshot.open([world]), :fetch, "every") == 3600
      assert Map.keys(Map.from_struct(fetcher())) |> Enum.sort() == [:id, :work]
    end

    test "a job that never ran is due", %{world: world} do
      {:ok, _} = World.append(world, Job.declare(:fetch, every: 3600))

      assert Job.due?(Snapshot.open([world]), :fetch, 0)
    end

    test "a job is not due again until its cadence has passed", %{world: world} do
      {:ok, _} = World.append(world, Job.declare(:fetch, every: 3600))
      {:ok, _} = Job.run(fetcher(), world, Snapshot.open([world]), 1000)

      snapshot = Snapshot.open([world])
      refute Job.due?(snapshot, :fetch, 2000)
      assert Job.due?(snapshot, :fetch, 4600)
    end

    test "a job with no cadence is never due on its own", %{world: world} do
      {:ok, _} = World.append(world, Job.declare(:on_demand))

      refute Job.due?(Snapshot.open([world]), :on_demand, 999_999)
    end

    test "the scheduler is a read", %{world: world} do
      {:ok, _} = World.append(world, Job.declare(:hourly, every: 3600))
      {:ok, _} = World.append(world, Job.declare(:daily, every: 86_400))
      {:ok, _} = World.append(world, Job.declare(:on_demand))

      assert Job.due(Snapshot.open([world]), 0) |> Enum.sort() == [:daily, :hourly]

      {:ok, _} = Job.run(fetcher(), world, Snapshot.open([world]), 0)
      # :fetch has no cadence declared, so running it changes nothing here.
      assert Job.due(Snapshot.open([world]), 0) |> Enum.sort() == [:daily, :hourly]
    end

    test "in-flight work survives a restart because it wrote a fact", %{world: world} do
      {:ok, _} = World.append(world, Job.declare(:fetch, every: 3600))
      {:ok, _} = Job.run(fetcher(), world, Snapshot.open([world]), 1000)

      # Nothing is held in a process. A new reader picks up from the world.
      assert Job.last_run(Snapshot.open([world]), :fetch) == 1000
      refute Job.due?(Snapshot.open([world]), :fetch, 1500)
    end
  end

  describe "time comes from outside" do
    test "due? is a pure function of a snapshot and a moment", %{world: world} do
      {:ok, _} = World.append(world, Job.declare(:fetch, every: 100))
      snapshot = Snapshot.open([world])

      assert Job.due?(snapshot, :fetch, 0) == Job.due?(snapshot, :fetch, 0)
      refute Job.due?(snapshot, :fetch, 0) == false
    end
  end
end
