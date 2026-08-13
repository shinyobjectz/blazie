defmodule Blazie.JudgedRequirementLiveTest do
  @moduledoc """
  A requirement no predicate could answer, put to a model.

  Live because that is the whole point: "is this polite" is not a thing Lua can
  decide, and a stub deciding it would be testing the stub.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Snapshot, World}

  @moduletag :live
  @moduletag timeout: 60_000

  setup do
    name = "judged-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Attribute.requires_seed())
    {:ok, _} = World.append(world, Attribute.define("summary", answers: "name"))

    {:ok, _} =
      World.append(world, [
        {"summary", "requires", "polite"},
        {"polite", "is", "formula"},
        {"polite", "describe", "The text must be polite and free of insults."},
        {"polite", "judge", "openrouter:openai/gpt-4o-mini"}
      ])

    %{world: world}
  end

  test "it passes what holds and refuses what does not, with a reason", %{world: world} do
    at = Snapshot.open([world])

    assert Attribute.unmet([{"a", "summary", "Thank you for reporting this."}], at) == []

    assert [refusal] =
             Attribute.unmet([{"b", "summary", "This is a stupid question."}], at)

    assert refusal.requirement == "polite"

    # The reason is what a rejected sample carries into its next attempt, so a
    # judge that only said "no" would cost the repair loop what makes it work.
    assert String.length(refusal.repair) > 20
  end
end
