defmodule Blazie.AgentsTest do
  @moduledoc """
  Declared agents, running — the difference between a framework and a folder of
  functions.

  The load-bearing test is the last one. A generative job on a cadence that
  called a model before checking whether anything was due would bill for every
  tick of a world where nothing happened, and it would do that silently. So the
  gate is proven rather than assumed: with a deliberately bogus provider, an
  empty work list must return quietly and a non-empty one must raise, which
  shows exactly where the call does and does not happen.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Agent, Agents, Attribute, Job, Snapshot, World}

  setup do
    name = "agents-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Agents.seed())
    {:ok, _} = World.append(world, Attribute.define("body", answers: "name"))

    %{world: world, name: name}
  end

  defp snapshot(world), do: Snapshot.open([world])

  defp declare(world, asks) do
    World.append(
      world,
      Agent.declare("severity",
        produces: "ticket",
        watches: ["body"],
        asks: asks,
        answers: "name",
        describe: "low, medium or high"
      ) ++ Job.declare("severity")
    )
  end

  describe "finding what has been declared" do
    test "a field that says who to ask is an agent", %{world: world} do
      {:ok, _} = declare(world, "openai:gpt-4o-mini")

      assert Agents.declared(snapshot(world)) == ["severity"]
    end

    test "an ordinary attribute is not", %{world: world} do
      assert Agents.declared(snapshot(world)) == []
    end

    test "each becomes a job with the field's own name", %{world: world} do
      {:ok, _} = declare(world, "openai:gpt-4o-mini")

      assert [%Job{id: "severity"}] = Agents.jobs(snapshot(world))
    end

    test "the registry is the world, so it cannot drift", %{world: world} do
      {:ok, _} = declare(world, "openai:gpt-4o-mini")
      assert length(Agents.jobs(snapshot(world))) == 1

      # A second agent arrives by being written. Nothing was told.
      {:ok, _} = World.append(world, Attribute.define("mood", answers: "name"))

      {:ok, _} =
        World.append(
          world,
          Agent.declare("mood", produces: "ticket", watches: ["body"], asks: "openai:gpt-4o-mini", answers: "name")
        )

      assert length(Agents.jobs(snapshot(world))) == 2
    end
  end

  describe "the runner routes it" do
    test "a declared agent is a job the runner knows about", %{world: world, name: name} do
      {:ok, _} = declare(world, "openai:gpt-4o-mini")
      {:ok, pid} = Agents.start_link(world: name, every: 3600)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # Nothing is due — no ticket has a body — so a tick starts nothing.
      {:ok, started} = Job.Runner.tick(Agents.runner(name), System.system_time(:second) + 100_000)
      assert started == []
    end
  end

  describe "naming" do
    test "a world name never becomes an atom", %{world: world, name: name} do
      # An atom is never collected, so building one from a world name would be
      # a way to exhaust the atom table one claimed world at a time. The
      # application moduledoc says this about worlds; it is as true of anything
      # named after one.
      {:ok, _} = declare(world, "openai:gpt-4o-mini")
      {:ok, pid} = Agents.start_link(world: name, every: 3600)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir.Blazie.Agents.#{name}") end
      assert match?({:via, Registry, _}, Agents.runner(name))
    end
  end

  describe "nothing is asked until there is something to ask about" do
    test "an empty work list never reaches the model", %{world: world} do
      # A provider that does not exist. If the model were called at all, this
      # would raise — so returning quietly IS the proof that it was not.
      {:ok, _} = declare(world, "no_such_provider:whatever")

      work = Agent.work(snapshot(world), "severity")
      assert work.(snapshot(world), 1) == []
    end

    test "and a non-empty one does reach it", %{world: world} do
      # The other half. Without this the test above passes for a system that
      # never calls a model at all, which is not the property being checked.
      {:ok, _} = declare(world, "no_such_provider:whatever")
      {:ok, _} = World.append(world, [{"t1", "body", "the server is on fire"}])

      work = Agent.work(snapshot(world), "severity")

      assert_raise RuntimeError, ~r/not a provider here/, fn ->
        work.(snapshot(world), 1)
      end
    end
  end

  describe "a budget stops it" do
    test "an agent over budget refuses itself and writes why", %{world: world} do
      # A provider that does not exist: if the model were reached this would
      # raise, so a clean refusal is proof the budget was checked FIRST.
      {:ok, _} = declare(world, "no_such_provider:whatever")
      {:ok, _} = World.append(world, Blazie.Spend.seed())
      {:ok, _} = World.append(world, [{"severity", "budget", 10}])
      {:ok, _} = World.append(world, Blazie.Spend.of("severity", %{in: 50, out: 0}, "severity"))
      {:ok, _} = World.append(world, [{"t1", "body", "the server is on fire"}])

      work = Agent.work(snapshot(world), "severity")
      written = work.(snapshot(world), 1)

      assert [{"severity", "refused", why, "severity"}] = written
      assert why =~ "budget"
    end

    test "and under budget it gets as far as the model", %{world: world} do
      {:ok, _} = declare(world, "no_such_provider:whatever")
      {:ok, _} = World.append(world, Blazie.Spend.seed())
      {:ok, _} = World.append(world, [{"severity", "budget", 1_000_000}])
      {:ok, _} = World.append(world, [{"t1", "body", "the server is on fire"}])

      work = Agent.work(snapshot(world), "severity")
      assert_raise RuntimeError, ~r/not a provider here/, fn -> work.(snapshot(world), 1) end
    end
  end
end
