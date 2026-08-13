defmodule Blazie.RequirementTest do
  @moduledoc """
  What an attribute requires of its values, beyond their shape.

  A requirement is a formula attached to an attribute by a fact. No new word:
  `answers:` says what shape a value has, `requires` says what must be true of
  it, and both are read the same way.

  Checked BEFORE anything is written, which is what lets a generative job sample
  again rather than write something wrong and correct it. A correction is cheap
  here; an unchecked wrong answer is not a correction, it is a lie with a
  timestamp.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Snapshot, World}

  setup do
    name = "req-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Attribute.requires_seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  defp require_that(world, attribute, id, source) do
    {:ok, _} =
      World.append(world, [
        {attribute, "requires", id},
        {id, "is", "formula"},
        {id, "source", source}
      ])
  end

  describe "an attribute with no requirements" do
    test "accepts anything of the right shape", %{world: world} do
      assert Attribute.unmet([{"ada", "height", 180}], snapshot(world)) == []
      assert Attribute.unmet([{"ada", "height", -5}], snapshot(world)) == []
    end
  end

  describe "a requirement that holds" do
    setup %{world: world} do
      require_that(world, "height", "positive", "return value > 0")
      :ok
    end

    test "lets a satisfying value through", %{world: world} do
      assert Attribute.unmet([{"ada", "height", 180}], snapshot(world)) == []
    end

    test "refuses one that does not satisfy it", %{world: world} do
      assert [refusal] = Attribute.unmet([{"ada", "height", -5}], snapshot(world))

      assert refusal.requirement == "positive"
      assert refusal.attribute == "height"
      assert refusal.id == "ada"
      assert refusal.repair =~ "positive"
    end

    test "says which entity failed, not just that something did", %{world: world} do
      unmet = Attribute.unmet([{"ada", "height", 180}, {"grace", "height", -1}], snapshot(world))

      assert [%{id: "grace"}] = unmet
    end
  end

  describe "a requirement that explains itself" do
    test "a returned string is the reason", %{world: world} do
      require_that(world, "height", "sane", """
      if value > 300 then return 'a person is not three metres tall' end
      return true
      """)

      assert [refusal] = Attribute.unmet([{"ada", "height", 400}], snapshot(world))
      assert refusal.repair =~ "three metres"
    end
  end

  describe "several requirements on one attribute" do
    test "every one that fails is reported", %{world: world} do
      require_that(world, "height", "positive", "return value > 0")
      require_that(world, "height", "sane", "return value < 300")

      assert [] = Attribute.unmet([{"ada", "height", 180}], snapshot(world))
      assert [_one] = Attribute.unmet([{"ada", "height", 400}], snapshot(world))
      assert [_also] = Attribute.unmet([{"ada", "height", -5}], snapshot(world))
    end
  end

  describe "a requirement that is broken" do
    test "one with no source says so rather than silently passing", %{world: world} do
      {:ok, _} = World.append(world, [{"height", "requires", "ghost"}])

      assert [refusal] = Attribute.unmet([{"ada", "height", 1}], snapshot(world))
      assert refusal.repair =~ "no `source`"
    end

    test "one that will not run is a refusal, not a pass", %{world: world} do
      require_that(world, "height", "broken", "this is not lua ((")

      assert [refusal] = Attribute.unmet([{"ada", "height", 1}], snapshot(world))
      assert refusal.repair =~ "broken"
    end

    test "one that loops forever is stopped and refused", %{world: world} do
      # A requirement is a formula, so it gets a formula's deadline. Without
      # this a bad requirement wedges every write to the attribute it guards.
      require_that(world, "height", "spin", "while true do end")

      assert [refusal] = Attribute.unmet([{"ada", "height", 1}], snapshot(world))
      assert refusal.repair =~ "spin"
    end
  end

  describe "a requirement cannot reach outside" do
    test "it runs in the formula world, so there is no http", %{world: world} do
      require_that(world, "height", "reaching", "return http == nil")

      # Passes precisely because `http` is absent. A requirement that could
      # fetch would make "does this hold" depend on when you asked.
      assert Attribute.unmet([{"ada", "height", 1}], snapshot(world)) == []
    end
  end

  describe "strings" do
    test "are bound safely, quotes and all", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("name", answers: "name"))
      require_that(world, "name", "nonempty", "return #value > 0")

      assert Attribute.unmet([{"ada", "name", "Ada"}], snapshot(world)) == []
      assert [_] = Attribute.unmet([{"ada", "name", ""}], snapshot(world))
      # An apostrophe must not break out of the literal.
      assert Attribute.unmet([{"ada", "name", "O'Hara"}], snapshot(world)) == []
    end
  end

  describe "shown or hidden" do
    test "a hidden requirement is not in the ask", %{world: world} do
      require_that(world, "height", "positive", "return value > 0")
      {:ok, _} = World.append(world, [{"positive", "describe", "must be a positive number"}])

      # Hidden is the default and deliberately so: a requirement in the prompt
      # is one the model optimises against rather than is tested on.
      assert Attribute.instructions(snapshot(world), "height") == []
    end

    test "a shown one is", %{world: world} do
      require_that(world, "height", "positive", "return value > 0")

      {:ok, _} =
        World.append(world, [
          {"positive", "describe", "must be a positive number"},
          {"positive", "shown", true}
        ])

      assert Attribute.instructions(snapshot(world), "height") == ["must be a positive number"]
    end

    test "showing it does not stop it being checked", %{world: world} do
      require_that(world, "height", "positive", "return value > 0")

      {:ok, _} =
        World.append(world, [
          {"positive", "describe", "must be a positive number"},
          {"positive", "shown", true}
        ])

      # The same fact is the instruction AND the gate, so they cannot disagree.
      assert [_] = Attribute.unmet([{"ada", "height", -5}], snapshot(world))
      assert Attribute.unmet([{"ada", "height", 5}], snapshot(world)) == []
    end
  end

  describe "a requirement with no predicate" do
    test "and no judge says so rather than passing", %{world: world} do
      {:ok, _} =
        World.append(world, [{"height", "requires", "vague"}, {"vague", "is", "formula"}])

      assert [refusal] = Attribute.unmet([{"ada", "height", 1}], snapshot(world))
      assert refusal.repair =~ "no `source`"
    end

    test "a predicate wins over a judge when both are there", %{world: world} do
      # Code that can decide should — a judge is for what Lua cannot answer.
      require_that(world, "height", "positive", "return value > 0")

      {:ok, _} =
        World.append(world, [
          {"positive", "judge", "no_such_provider:whatever"},
          {"positive", "describe", "must be positive"}
        ])

      # If the judge were consulted this would raise on an unknown provider.
      assert Attribute.unmet([{"ada", "height", 5}], snapshot(world)) == []
    end
  end
end
