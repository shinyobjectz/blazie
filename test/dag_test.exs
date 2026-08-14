defmodule Blazie.DagTest do
  @moduledoc """
  DAGs without a second queue: `after` is a fact, order is a comparison of
  `ran_at` facts, and a restart mid-chain resumes from what the facts say.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Job, TestLedger, World}
  alias Blazie.Job.{Author, Runner}

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Job.seed())

    {:ok, _} =
      World.append(world, Attribute.define("mark", answers: "integer", cardinality: "many"))

    %{world: world}
  end

  defp marker(id, agent) do
    Job.new(id, fn _snapshot ->
      Agent.update(agent, &(&1 ++ [id]))
      [{id, "mark", 1}]
    end)
  end

  defp settle(runner) do
    Enum.reduce_while(1..400, nil, fn _, _ ->
      if Runner.in_flight(runner) == [], do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
    end)
  end

  test "a chain of three runs in order, one tick each", %{world: world} do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, _} =
      World.append(
        world,
        Job.declare("a", every: 3_600) ++
          Job.declare("b", after: ["a"]) ++
          Job.declare("c", after: ["b"])
      )

    runner =
      start_supervised!(
        {Runner,
         world: world,
         jobs: [marker("a", agent), marker("b", agent), marker("c", agent)],
         name: :"dag_#{System.unique_integer([:positive])}"}
      )

    # Only the head has a cadence; the rest follow because their upstream's
    # ran_at moved past their own.
    assert {:ok, ["a"]} = Runner.tick(runner, 1_000)
    settle(runner)
    assert {:ok, ["b"]} = Runner.tick(runner, 1_001)
    settle(runner)
    assert {:ok, ["c"]} = Runner.tick(runner, 1_002)
    settle(runner)

    # And the chain is quiet until the head fires again.
    assert {:ok, []} = Runner.tick(runner, 1_003)
    assert Agent.get(agent, & &1) == ["a", "b", "c"]
  end

  test "a restart mid-chain resumes exactly where the facts say", %{world: world} do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, _} =
      World.append(world, Job.declare("a", every: 3_600) ++ Job.declare("b", after: ["a"]))

    runner =
      start_supervised!(
        Supervisor.child_spec(
          {Runner, world: world, jobs: [marker("a", agent), marker("b", agent)], name: :dag_r1},
          id: :dag_r1
        )
      )

    {:ok, ["a"]} = Runner.tick(runner, 1_000)
    settle(runner)

    # The runner dies with a ran but b not. The world is the queue, so the
    # NEW runner owes b and knows it — zero reconciliation code.
    :ok = stop_supervised(:dag_r1)

    runner =
      start_supervised!(
        Supervisor.child_spec(
          {Runner, world: world, jobs: [marker("a", agent), marker("b", agent)], name: :dag_r2},
          id: :dag_r2
        )
      )

    assert {:ok, ["b"]} = Runner.tick(runner, 1_001)
    settle(runner)
    assert Agent.get(agent, & &1) == ["a", "b"]
  end

  test "a join fires once, after ALL its upstreams", %{world: world} do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, _} =
      World.append(
        world,
        Job.declare("left", every: 3_600) ++
          Job.declare("right", every: 3_600) ++
          Job.declare("join", after: ["left", "right"])
      )

    runner =
      start_supervised!(
        {Runner,
         world: world,
         jobs: [marker("left", agent), marker("right", agent), marker("join", agent)],
         name: :"dag_join_#{System.unique_integer([:positive])}"}
      )

    # Both producers fire on the first tick; the join must not ride along
    # half-fed, and must fire exactly once when both inputs are fresh.
    {:ok, started} = Runner.tick(runner, 1_000)
    assert Enum.sort(started) == ["left", "right"]
    settle(runner)

    assert {:ok, ["join"]} = Runner.tick(runner, 1_001)
    settle(runner)
    assert {:ok, []} = Runner.tick(runner, 1_002)
  end

  describe "authored jobs: the error is the product" do
    test "a valid authored job lands with its cadence and source" do
      assert {:ok, facts} = Author.declare("refresh", "return 1 + 1", every: 300)
      assert {"refresh", "is", "job"} in facts
      assert {"refresh", "every", 300} in facts
    end

    test "every malformed shape answers a line and a repair" do
      table = [
        {"broken lua", "local x = ((", ~r/line/i},
        {"not even text", nil, ~r/Lua text/},
        {"an id that is not a string", "return 1", ~r/non-empty string/},
        {"a reserved id", "return 1", ~r/belong to the node/}
      ]

      for {name, source, wanted} <- table do
        {id, src} =
          case name do
            "an id that is not a string" -> {:atom_id, source}
            "a reserved id" -> {"$sneaky", source}
            _ -> {"job-x", source}
          end

        assert {:error, [complaint | _]} = Author.declare(id, src, []),
               "#{name} was accepted"

        assert complaint.repair =~ wanted, "#{name}: #{complaint.repair}"
        assert is_integer(complaint.line)
      end
    end

    test "the parse error names the line" do
      source = """
      local a = 1
      local b = 2
      this is not lua
      """

      assert {:error, [complaint | _]} = Author.parses(source)
      assert complaint.line == 3
    end
  end
end
