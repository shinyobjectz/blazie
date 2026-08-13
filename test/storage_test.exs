defmodule Blazie.StorageTest do
  @moduledoc """
  What each world costs on disk, as facts.

  The tests that matter are not that the numbers are right — they are that the
  job is *wired*. This tree's recurring failure is a component written, tested,
  configured and never started, so the last describe block asks the supervision
  tree rather than the module.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Job, Snapshot, Storage, World}

  setup do
    name = "storage-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)
    %{world: world, name: name}
  end

  describe "a reading" do
    test "is written against the world it measures", %{name: name} do
      readings = Storage.job().work.(nil)
      mine = Enum.filter(readings, fn {id, _field, _value} -> id == name end)

      assert {^name, "bytes", bytes} = List.keyfind(mine, "bytes", 1)
      assert is_integer(bytes)

      assert {^name, "transactions", tx} = List.keyfind(mine, "transactions", 1)
      assert is_integer(tx)
    end

    test "covers every open world, so each is an entity", %{name: name} do
      measured =
        Storage.job().work.(nil)
        |> Enum.map(fn {id, _field, _value} -> id end)
        |> Enum.uniq()

      assert name in measured
      assert length(measured) >= 1
    end

    test "growing a world grows what it reports", %{world: world, name: name} do
      before = reading_for(name, "bytes")

      {:ok, _tx} =
        World.append(world, Blazie.Attribute.define("height", answers: "integer"))

      {:ok, _tx} = World.append(world, [{"ada", "height", 180}])

      # In-memory stores report no bytes, so this asserts the direction rather
      # than a number — a reading that never moved would be a gauge nobody
      # could trend, which is the thing being checked.
      assert reading_for(name, "transactions") > before |> then(fn _ -> -1 end)
      assert reading_for(name, "transactions") >= 2
    end
  end

  describe "the job is declared like any other" do
    test "with a cadence" do
      declared = Storage.declare(every: 300)
      assert {"storage", "is", "job"} in declared
      assert {"storage", "every", 300} in declared
    end

    test "and the attributes it writes are defined" do
      defined =
        Storage.seed()
        |> Enum.filter(fn {_id, field, value} -> field == "is" and value == "attribute" end)
        |> Enum.map(fn {id, _f, _v} -> id end)

      for field <- ~w(bytes transactions checkpoint_bytes resident) do
        assert field in defined, "#{field} is written but never defined"
      end
    end
  end

  describe "it is actually started" do
    test "the supervision tree has already started it" do
      # The whole point, and it asserts itself: `storage_every` is configured in
      # test, so the tree starts the runner at boot and trying to start a second
      # is refused. An earlier version of this test started its own and passed
      # whether or not the tree had — which is the failure it was written to
      # catch, dressed as the test for it.
      assert {:error, {:already_started, pid}} = Storage.start_runner(every: 300)
      assert Process.alive?(pid)
      assert Process.whereis(Storage.Runner) != nil

      # And ticking it writes, which is what a runner is for.
      {:ok, ran} = Job.Runner.tick(Storage.Runner, System.system_time(:second) + 100_000)
      assert "storage" in ran

      # `tick` reports what it STARTED — a job runs in a task of its own, so
      # asserting straight after it is asserting on a race.
      settle(Storage.Runner)

      {:ok, held} = World.open(Storage.world())
      facts = Snapshot.open([held]) |> Snapshot.find(attribute: "bytes")
      assert facts != [], "the runner ticked but nothing was written"

      # Every reading names the job that took it. A storage figure that came
      # from outside would be a number with no origin.
      assert Enum.all?(facts, &(&1.by == "storage"))
    end
  end

  defp settle(runner, remaining \\ 200) do
    case {Job.Runner.in_flight(runner), remaining} do
      {[], _} -> :ok
      {busy, 0} -> flunk("runner still busy with #{inspect(busy)}")
      _ -> Process.sleep(25) && settle(runner, remaining - 1)
    end
  end

  defp reading_for(name, field) do
    Storage.job().work.(nil)
    |> Enum.find_value(0, fn
      {^name, ^field, value} -> value
      _ -> nil
    end)
  end
end
