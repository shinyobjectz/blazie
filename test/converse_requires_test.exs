defmodule Blazie.ConverseRequiresTest do
  @moduledoc """
  The general loop, required to hold — and tested rather than paraphrased.

  `Job.Generative` samples a declared field until its requirements hold. That
  covers the case where the answer IS a field. A coding loop's answer is prose,
  and until now nothing checked it: `converse/5` returned whatever the model
  last said, which is the one thing this tree says a generated value must never
  be.

  These drive `Model.converse/5` itself through the `provider:` seam. The loop
  had a test before, and it drove a `FakeLoop` carrying its own copy of the
  recursion — so it proved a copy caps its calls and said nothing about the
  function that spends the money.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Model, Snapshot, World}

  setup do
    {:ok, world} = World.open("converse-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++
          Attribute.requires_seed() ++
          Attribute.define("summary", answers: "name", requires: "short") ++
          [
            {"short", "is", "formula"},
            {"short", "source", "return #value <= 12"}
          ]
      )

    %{world: world, snapshot: Snapshot.open([world])}
  end

  defp saying(answers) do
    held = :counters.new(1, [])

    fn _reference, _messages, _tools, _opts ->
      at = :counters.get(held, 1)
      :counters.add(held, 1, 1)
      {:ok, {:said, Enum.at(answers, at, List.last(answers))}, %{in: 7, out: 3}}
    end
  end

  test "an answer that holds comes straight back", %{snapshot: snapshot} do
    assert {:ok, "short one", []} =
             Model.converse("openai:x", "say something", [], fn _ -> {:ok, %{}} end,
               provider: saying(["short one"]),
               answers: "summary",
               snapshot: snapshot
             )
  end

  test "an answer that does not is asked again, and the good one comes back", %{
    snapshot: snapshot
  } do
    assert {:ok, "short one", []} =
             Model.converse("openai:x", "say something", [], fn _ -> {:ok, %{}} end,
               provider: saying(["much too long to be a summary", "short one"]),
               answers: "summary",
               snapshot: snapshot
             )
  end

  test "the model is TOLD what was wrong, not merely asked again", %{snapshot: snapshot} do
    seen = :ets.new(:seen, [:public, :bag])

    speak = fn _r, messages, _t, _o ->
      :ets.insert(seen, {:turn, messages})

      if length(messages) > 1,
        do: {:ok, {:said, "short"}, %{in: 1, out: 1}},
        else: {:ok, {:said, "far too long for this"}, %{in: 1, out: 1}}
    end

    assert {:ok, "short", []} =
             Model.converse("openai:x", "say", [], fn _ -> {:ok, %{}} end,
               provider: speak,
               answers: "summary",
               snapshot: snapshot
             )

    # The second turn carries the rejected answer AND the reason. A model shown
    # only the complaint has to guess which of its sentences drew it.
    [{_, second} | _] = Enum.sort_by(:ets.tab2list(seen), fn {_, m} -> -length(m) end)
    said = Enum.map_join(second, " ", &(&1["content"] || ""))

    assert said =~ "far too long for this"
    assert said =~ "short"
  end

  test "running out of tries refuses, carrying why", %{snapshot: snapshot} do
    assert {:error, refusal} =
             Model.converse("openai:x", "say", [], fn _ -> {:ok, %{}} end,
               provider: saying(["always much too long to pass"]),
               answers: "summary",
               snapshot: snapshot,
               tries: 2
             )

    assert refusal.problem == :unmet
    assert refusal.repair =~ "summary"
  end

  test "without `answers` nothing is checked, which is the honest default", %{
    snapshot: _snapshot
  } do
    # A loop answering prose nobody declared a shape for has nothing to check
    # against. Said out loud because the absence is a decision, not an oversight.
    assert {:ok, "anything at all", []} =
             Model.converse("openai:x", "say", [], fn _ -> {:ok, %{}} end,
               provider: saying(["anything at all"])
             )
  end
end
