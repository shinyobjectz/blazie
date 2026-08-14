defmodule Blazie.Formula.LearnedTest do
  @moduledoc """
  A skill learned from what a run did, not from what somebody wrote down.

  The claim P3 rests on is narrow and worth stating exactly: an agent that keeps
  calling out for the same answer is doing arithmetic over the network, and its
  own history is the specification for a formula that would make the call
  unnecessary. What is tested here is that the history is a good enough
  specification — and that it refuses when it is not.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Formula, Model, Run, Snapshot, Spend, Tool, World}

  setup do
    {:ok, world} = World.open("learn-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++
          Spend.seed() ++
          Model.seed() ++
          Run.seed() ++
          Tool.seed() ++
          Formula.Generated.seed()
      )

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  # A run that calls one tool, then answers.
  defp ran(world, id, calls) do
    held = :counters.new(1, [])

    speak = fn _r, _m, _t, _o ->
      at = :counters.get(held, 1)
      :counters.add(held, 1, 1)

      case Enum.at(calls, at) do
        nil ->
          {:ok, {:said, "done"}, %{in: 1, out: 1}}

        {args, _answer} ->
          {:ok, {:calls, [%{id: "c", name: "plan_of", arguments: args}]}, %{in: 1, out: 1}}
      end
    end

    # Answered by POSITION, not by arguments — otherwise identical arguments get
    # identical answers by construction and the disagreement case cannot be
    # written at all. That is the test bug this comment exists to prevent
    # somebody reintroducing.
    answering = :counters.new(1, [])

    ran = fn _call ->
      at = :counters.get(answering, 1)
      :counters.add(answering, 1, 1)
      {_args, answer} = Enum.at(calls, at)
      {:ok, answer}
    end

    {:ok, _, _} =
      Model.converse("openai:x", "work", [], ran,
        provider: speak,
        into: world,
        by: id,
        calls: 10
      )
  end

  test "what a run kept calling is answerable from its own history", %{world: world} do
    ran(world, "r1", [
      {%{"customer" => "ada"}, "pro"},
      {%{"customer" => "bo"}, "free"},
      {%{"customer" => "cy"}, "pro"}
    ])

    assert [{"plan_of", 3}] = Formula.Learned.repeated(snapshot(world), "r1")

    assert [
             {%{"customer" => "ada"}, "pro"},
             {%{"customer" => "bo"}, "free"},
             {%{"customer" => "cy"}, "pro"}
           ] = Formula.Learned.calls(snapshot(world), "r1", "plan_of")
  end

  test "a harvest is a brief the existing verifier can act on", %{world: world} do
    ran(world, "r1", [
      {%{"customer" => "ada"}, "pro"},
      {%{"customer" => "bo"}, "free"},
      {%{"customer" => "cy"}, "pro"}
    ])

    assert {:ok, facts} =
             Formula.Learned.harvest(snapshot(world), "r1", "plan_of",
               produces: "plan",
               given: ["customer"]
             )

    # Exactly the shape `Generated.declare/2` makes, because it IS that — the
    # harvest proposes evidence and never a body, so a learned formula clears
    # the same fence as a hand-written one.
    assert {"plan_of", "is", "formula"} in facts
    assert {"plan_of", "produces", "plan"} in facts

    examples = for {_id, "example", example} <- facts, do: example
    assert length(examples) == 3
    assert %{"given" => %{"customer" => "ada"}, "expect" => "pro"} in examples
  end

  test "and lands as a formula that WANTS a body", %{world: world} do
    ran(world, "r1", [
      {%{"customer" => "ada"}, "pro"},
      {%{"customer" => "bo"}, "free"},
      {%{"customer" => "cy"}, "pro"}
    ])

    {:ok, facts} =
      Formula.Learned.harvest(snapshot(world), "r1", "plan_of",
        produces: "plan",
        given: ["customer"]
      )

    {:ok, _} = World.append(world, facts)

    # The work list the generator already reads. Nothing new had to be taught
    # what a formula needing a body looks like.
    assert "plan_of" in Formula.Generated.wanted(snapshot(world))
  end

  test "a later call that contradicts what was learned makes it stale", %{world: world} do
    # The claim this whole phase rests on, and the one nothing else here has.
    # A learned skill that silently outlives the evidence for it is the central
    # failure of every memory system; here the read set already decides.
    ran(world, "r1", [
      {%{"customer" => "ada"}, "pro"},
      {%{"customer" => "bo"}, "free"},
      {%{"customer" => "cy"}, "pro"}
    ])

    {:ok, facts} =
      Formula.Learned.harvest(snapshot(world), "r1", "plan_of",
        produces: "plan",
        given: ["customer"]
      )

    {:ok, _} = World.append(world, facts)

    # Somebody writes the body and it is adopted.
    {:ok, _} =
      World.append(world, Formula.Generated.adopt("plan_of", "-- a body", "whoever"))

    refute "plan_of" in Formula.Generated.wanted(snapshot(world))

    # Then the world moves: ada is on `free` now, and a run sees it.
    {:ok, _} =
      World.append(world, [
        {"plan_of", "example", %{"given" => %{"customer" => "ada"}, "expect" => "free"}}
      ])

    # Nothing had to notice. The newest example is later than the source, so the
    # program that no longer satisfies it is back on the work list — exactly as
    # a derived value is stale when its input moves.
    assert "plan_of" in Formula.Generated.wanted(snapshot(world))
  end

  test "two answers for the same arguments is refused, not voted on", %{world: world} do
    ran(world, "r2", [
      {%{"customer" => "ada"}, "pro"},
      {%{"customer" => "ada"}, "free"},
      {%{"customer" => "bo"}, "free"}
    ])

    assert {:error, refusal} =
             Formula.Learned.harvest(snapshot(world), "r2", "plan_of",
               produces: "plan",
               given: ["customer"]
             )

    # Taking the majority would bake one of two answers in forever. The thing is
    # not a function, and the repair says what to do about that.
    assert refusal.problem == :not_a_function
    assert refusal.repair =~ "not in"
  end

  test "one call is a coincidence", %{world: world} do
    ran(world, "r3", [{%{"customer" => "ada"}, "pro"}])

    assert {:error, %{problem: :too_few}} =
             Formula.Learned.harvest(snapshot(world), "r3", "plan_of",
               produces: "plan",
               given: ["customer"]
             )
  end
end
