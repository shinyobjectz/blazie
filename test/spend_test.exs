defmodule Blazie.SpendTest do
  @moduledoc """
  What a run cost, and whether it was allowed to.

  The test that matters is that a budget is checked BEFORE a call. Checked
  after, it is a bill. And a refused run must write why — an agent that went
  quiet and one that stopped itself look identical from outside and mean
  opposite things.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Snapshot, Spend, World}

  setup do
    name = "spend-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Spend.seed())
    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  describe "spending is facts" do
    test "each run is its own reading, and the total is their sum", %{world: world} do
      {:ok, _} = World.append(world, Spend.of("severity", %{in: 100, out: 20}, "severity"))
      {:ok, _} = World.append(world, Spend.of("severity", %{in: 50, out: 10}, "severity"))

      # Summed from history rather than kept as a counter. A counter is a second
      # account of something the facts already hold, and the two disagree the
      # first time one is written and the other is not.
      assert Spend.so_far(snapshot(world), "severity") == %{in: 150, out: 30}
    end

    test "an id that never ran has spent nothing", %{world: world} do
      assert Spend.so_far(snapshot(world), "never") == %{in: 0, out: 0}
    end
  end

  describe "a budget" do
    test "lets a run through while there is room", %{world: world} do
      {:ok, _} = World.append(world, [{"severity", "budget", 1000}])
      {:ok, _} = World.append(world, Spend.of("severity", %{in: 100, out: 20}, "severity"))

      assert Spend.allowed?(snapshot(world), "severity") == :ok
    end

    test "refuses one that would go over, and says what against what", %{world: world} do
      {:ok, _} = World.append(world, [{"severity", "budget", 100}])
      {:ok, _} = World.append(world, Spend.of("severity", %{in: 90, out: 20}, "severity"))

      assert {:error, refusal} = Spend.allowed?(snapshot(world), "severity")
      assert refusal.problem == :over_budget
      assert refusal.repair =~ "110"
      assert refusal.repair =~ "100"
    end

    test "no budget means no limit, not a limit of zero", %{world: world} do
      {:ok, _} = World.append(world, Spend.of("severity", %{in: 999_999, out: 0}, "severity"))

      assert Spend.allowed?(snapshot(world), "severity") == :ok
    end

    test "a refusal is written, so stopping itself is distinguishable from going quiet", %{
      world: world
    } do
      {:ok, _} = World.append(world, [{"severity", "budget", 10}])
      {:ok, _} = World.append(world, Spend.of("severity", %{in: 20, out: 0}, "severity"))

      {:error, refusal} = Spend.allowed?(snapshot(world), "severity")
      {:ok, _} = World.append(world, Spend.refused("severity", refusal, "severity"))

      assert [%{value: why}] = Snapshot.find(snapshot(world), id: "severity", attribute: "refused")
      assert why =~ "budget"
    end
  end

  describe "what a provider reported" do
    test "both usage shapes are read" do
      assert Blazie.Model.Provider.spent(%{"usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7}}) ==
               %{in: 5, out: 7}

      assert Blazie.Model.Provider.spent(%{"usage" => %{"input_tokens" => 5, "output_tokens" => 7}}) ==
               %{in: 5, out: 7}
    end

    test "silence is zero, and that is a stated limitation not a guess" do
      assert Blazie.Model.Provider.spent(%{}) == %{in: 0, out: 0}
    end
  end
end
