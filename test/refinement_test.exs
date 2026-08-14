defmodule Blazie.RefinementTest do
  @moduledoc """
  The harness changing itself, and the two things that makes safe.

  A system that edits its own declarations is the most dangerous thing in this
  tree, and the danger is not that it will be wrong — it is that it will be
  RIGHT about a bad remedy. "This run failed because it could not name that
  world" is a true observation whose obvious fix is catastrophic.

  So the bound is tested harder than the feature: what may be refined, what may
  not, and that the refusal does not care who proposed it.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Refinement, Run, Snapshot, World}

  setup do
    {:ok, world} = World.open("refine-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++
          Run.seed() ++
          Refinement.seed() ++
          Attribute.define("failed", answers: "any", cardinality: "many") ++
          Attribute.define("describe", answers: "any") ++
          Attribute.define("calls_allowed", answers: "integer") ++
          Attribute.define("severity", answers: "name")
      )

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  describe "what keeps going wrong" do
    test "one failure is an incident; the same one repeatedly is a declaration", %{world: world} do
      {:ok, _} =
        World.append(world, [
          {"run-1", "failed", "severity was not one of low, medium, high"},
          {"run-2", "failed", "severity was not one of low, medium, high"},
          {"run-3", "failed", "the network went away"}
        ])

      # The one-off is not a trigger. A harness that refined itself in response
      # to every incident would chase noise.
      assert [%{reason: reason, times: 2}] = Refinement.triggers(snapshot(world))
      assert reason =~ "severity"
    end
  end

  describe "the bound" do
    test "what a thing says about itself may be refined", %{world: world} do
      assert {:ok, _} =
               Refinement.adopt(
                 world,
                 "severity",
                 %{attribute: "describe", value: "one of low, medium or high"},
                 because: "kept answering with a paragraph"
               )

      assert Snapshot.value(snapshot(world), "severity", "describe") ==
               "one of low, medium or high"
    end

    test "what it is PERMITTED to do may not", %{world: world} do
      # The failure this bound exists to make impossible. `requires` is
      # refinable and `may_name` is not — one is a constraint a thing puts on
      # itself, the other is authority.
      assert {:error, refusal} =
               Refinement.adopt(
                 world,
                 "some-token",
                 %{attribute: "may_name", value: "$authority"},
                 because: "a run failed because it could not name that world"
               )

      assert refusal.problem == :outside_the_bound
      assert refusal.repair =~ "widen its own authority"
    end

    test "a formula's source may not, because examples are a stronger gate", %{world: world} do
      assert {:error, %{problem: :outside_the_bound}} =
               Refinement.adopt(world, "adults", %{attribute: "source", value: "return true"},
                 because: "it was wrong"
               )
    end

    test "the node's own worlds may not, whatever the evidence", %{world: world} do
      assert {:error, refusal} =
               Refinement.adopt(world, "$vitals", %{attribute: "describe", value: "anything"},
                 because: "a perfectly good reason"
               )

      assert refusal.problem == :reserved
      assert refusal.repair =~ "whatever the evidence"
    end
  end

  describe "a refinement is a fact" do
    test "so it carries why it was made", %{world: world} do
      {:ok, _} =
        Refinement.adopt(
          world,
          "severity",
          %{attribute: "describe", value: "low, medium or high"},
          because: "answered with a paragraph twice",
          now: 100
        )

      assert [%{because: "answered with a paragraph twice", at: 100, undone: nil}] =
               Refinement.of(snapshot(world), "severity")
    end

    test "and undoing it is a later fact, not a restore", %{world: world} do
      {:ok, _} =
        Refinement.adopt(
          world,
          "severity",
          %{attribute: "describe", value: "low, medium or high"},
          because: "a try",
          now: 100
        )

      [%{id: id}] = Refinement.of(snapshot(world), "severity")
      {:ok, _} = Refinement.undo(world, id, now: 200)

      # The reasoning stays readable: what was tried, why, and that it was
      # undone. A refinement that made things worse is evidence too.
      assert [%{because: "a try", undone: 200}] = Refinement.of(snapshot(world), "severity")
    end
  end

  describe "whether it helped" do
    test "is a query, because both sets of runs are still there", %{world: world} do
      reason = "severity was not one of low, medium, high"

      # Two runs before the refinement, both failing.
      {:ok, _} = World.append(world, [{"early-1", "began", 10}, {"early-1", "failed", reason}])
      {:ok, _} = World.append(world, [{"early-2", "began", 20}, {"early-2", "failed", reason}])

      {:ok, _} =
        Refinement.adopt(
          world,
          "severity",
          %{attribute: "describe", value: "low, medium or high"},
          because: reason,
          now: 50
        )

      [%{id: id}] = Refinement.of(snapshot(world), "severity")

      # One after, still failing — so it helped, but not entirely.
      {:ok, _} = World.append(world, [{"late-1", "began", 60}, {"late-1", "failed", reason}])

      assert %{before: 2, since: 1, at: 50} = Refinement.outcome(snapshot(world), id, reason)
    end

    test "a run already in flight is not counted against the change", %{world: world} do
      reason = "the same old thing"

      # Began before the refinement, failed after it. It was never tested by the
      # change, so counting it as a failure of the change would be wrong.
      {:ok, _} = World.append(world, [{"in-flight", "began", 10}])

      {:ok, _} =
        Refinement.adopt(world, "severity", %{attribute: "describe", value: "better"},
          because: reason,
          now: 50
        )

      [%{id: id}] = Refinement.of(snapshot(world), "severity")
      {:ok, _} = World.append(world, [{"in-flight", "failed", reason}])

      assert %{before: 1, since: 0} = Refinement.outcome(snapshot(world), id, reason)
    end
  end
end
