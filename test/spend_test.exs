defmodule Blazie.SpendTest do
  @moduledoc """
  What a run cost, and whether it was allowed to.

  This records and does not refuse, deliberately. A run is stopped by a
  REQUIREMENT it cannot satisfy, never by a ceiling on what it cost — an answer
  that is right is worth having whatever it took, and a wrong one is not made
  acceptable by being cheap. So there is no budget to test, and that absence is
  the design rather than a gap.
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

  describe "what a provider reported" do
    test "both usage shapes are read" do
      assert Blazie.Model.Provider.spent(%{
               "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7}
             }) ==
               %{in: 5, out: 7}

      assert Blazie.Model.Provider.spent(%{
               "usage" => %{"input_tokens" => 5, "output_tokens" => 7}
             }) ==
               %{in: 5, out: 7}
    end

    test "silence is zero, and that is a stated limitation not a guess" do
      assert Blazie.Model.Provider.spent(%{}) == %{in: 0, out: 0}
    end
  end
end
