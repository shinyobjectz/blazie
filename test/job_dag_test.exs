defmodule Blazie.JobDagTest do
  @moduledoc """
  A job is due when its clock says so, OR when what it read has changed.

  That second clause is the dependency graph, and it is observed rather than
  declared — the same way a formula's is. A job downstream of another fires
  after it because it *read* what the other wrote, so there is no edge anybody
  could write down wrong, and no edge to keep in step when the code changes.

  The read set is written into the world rather than held by the runner. A
  restart that forgot why a job would fire would quietly cost the runner the
  property it advertises: that a restart needs no reconciliation.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Job, Snapshot, World}

  setup do
    name = "dag-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Job.seed())
    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  describe "a job with only a cadence is unchanged" do
    test "never stale, because it recorded no reads", %{world: world} do
      {:ok, _} = World.append(world, Job.declare("ticker", every: 60))
      {:ok, _} = World.append(world, [{"ticker", "ran_at", 1000, "ticker"}])

      # Something lands. A cadence job does not care.
      {:ok, _} = World.append(world, Attribute.define("noise") ++ [{"x", "noise", 1}])

      refute Job.due?(snapshot(world), "ticker", 1030)
      assert Job.due?(snapshot(world), "ticker", 1100), "its clock still works"
    end
  end

  describe "a job that read something" do
    setup %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
      {:ok, _} = World.append(world, [{"ada", "height", 180}])

      # A job that reads heights. Running it records what it read.
      job =
        Job.new("watcher", fn snap ->
          [{"watcher", "saw", length(Snapshot.find(snap, attribute: "height"))}]
        end)

      {:ok, _} =
        World.append(world, Attribute.define("saw", answers: "integer", cardinality: "many"))

      {:ok, _} = World.append(world, Job.declare("watcher"))
      {:ok, _tx} = Job.run(job, world, snapshot(world), 1000)

      %{job: job}
    end

    test "records what it read, into the world", %{world: world} do
      reads = Snapshot.find(snapshot(world), id: "watcher", attribute: "reads")

      assert reads != [], "a job that read nothing can never be stale"
      assert Enum.any?(reads, &(&1.value["attribute"] == "height"))
    end

    test "is not due while nothing it read has changed", %{world: world} do
      refute Job.due?(snapshot(world), "watcher", 9_999_999)
    end

    test "becomes due when something it read changes", %{world: world} do
      {:ok, _} = World.append(world, [{"grace", "height", 175}])

      assert Job.due?(snapshot(world), "watcher", 1001),
             "a fact inside the read set should make it due, with no cadence at all"
    end

    test "stays quiet when something OUTSIDE its read set changes", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("colour") ++ [{"ada", "colour", "blue"}])

      refute Job.due?(snapshot(world), "watcher", 1001),
             "a write outside the read set is not a reason to run"
    end

    test "does not fire on its own writes", %{world: world, job: job} do
      # The loop that looks like a working reactive system for about a minute:
      # a job reads what it writes, so its own output makes it stale, forever.
      {:ok, _tx} = Job.run(job, world, snapshot(world), 1001)

      refute Job.due?(snapshot(world), "watcher", 1002),
             "a job's own writes must not make it due again"
    end
  end

  describe "one job downstream of another" do
    test "fires because it read what the other wrote", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("raw", answers: "integer"))
      {:ok, _} = World.append(world, Attribute.define("doubled", answers: "integer"))
      {:ok, _} = World.append(world, Job.declare("upstream", every: 60))
      {:ok, _} = World.append(world, Job.declare("downstream"))

      upstream = Job.new("upstream", fn _snap -> [{"n", "raw", 21}] end)

      downstream =
        Job.new("downstream", fn snap ->
          case Snapshot.value(snap, "n", "raw") do
            nil -> []
            value -> [{"n", "doubled", value * 2}]
          end
        end)

      # Downstream runs first and finds nothing, but records that it looked.
      {:ok, _} = Job.run(downstream, world, snapshot(world), 1000)
      refute Job.due?(snapshot(world), "downstream", 1001)

      # Upstream writes. Nobody declared an edge between them.
      {:ok, _} = Job.run(upstream, world, snapshot(world), 1002)

      assert Job.due?(snapshot(world), "downstream", 1003),
             "downstream read `n.raw`, upstream wrote it — that is the edge"

      {:ok, _} = Job.run(downstream, world, snapshot(world), 1004)
      assert Snapshot.value(snapshot(world), "n", "doubled") == 42
    end
  end
end
