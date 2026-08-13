defmodule Blazie.AttributeTest do
  @moduledoc """
  The doctrine, executable — schema as facts, and every write checked with a
  refusal that carries its repair.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, World, Snapshot}
  alias Blazie.TestLedger

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed())
    %{world: world}
  end

  defp known(world), do: Attribute.known(Snapshot.open([world]))
  defp checking(world), do: [check: &Attribute.check(&1, known(world))]

  # The vocabulary, and what a redeclaration would do to the facts already
  # written. Built fresh on every append, because that is the point.
  defp checking_the_facts(world),
    do: [check: &Attribute.check(&1, Snapshot.open([world]))]

  describe "schema is facts" do
    test "an attribute is defined by writing facts about it", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
      snapshot = Snapshot.open([world])

      assert Attribute.defined?(snapshot, "height")
      assert Snapshot.value(snapshot, "height", "is") == "attribute"
      assert Snapshot.value(snapshot, "height", "answers") == "integer"
    end

    test "definitions are ordinary facts in the same row shape", %{world: world} do
      {:ok, tx} = World.append(world, Attribute.define("height", answers: "integer"))

      World.facts_at(world, tx)
      |> Enum.filter(&(&1.tx == tx))
      |> Enum.each(fn fact -> assert fact.id == "height" end)
    end

    test "the vocabulary bootstraps itself", %{world: world} do
      snapshot = Snapshot.open([world])

      for name <- Attribute.root() do
        assert Attribute.defined?(snapshot, name)
      end
    end
  end

  describe "if an attribute can say it, the engine does not grow" do
    test "cardinality is a fact about the attribute", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("tags", cardinality: "many"))
      snapshot = Snapshot.open([world])

      assert Attribute.cardinality(snapshot, "tags") == "many"
      assert Attribute.cardinality(snapshot, "is") == "one"
    end

    test "an undeclared attribute answers with the default", %{world: world} do
      snapshot = Snapshot.open([world])

      assert Attribute.cardinality(snapshot, "never_defined") == "one"
      assert Attribute.answers(snapshot, "never_defined") == "any"
    end
  end

  describe "every write is checked, and a refusal carries its repair" do
    test "a defined attribute is accepted", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))

      assert {:ok, _tx} = World.append(world, [{42, "height", 180}], checking(world))
    end

    test "an undefined attribute is refused", %{world: world} do
      assert {:error, [refusal]} =
               World.append(world, [{42, "heigth", 180}], checking(world))

      assert refusal.attribute == "heigth"
      assert refusal.problem == :undefined
    end

    test "the refusal says how to comply", %{world: world} do
      {:error, [refusal]} = World.append(world, [{42, "heigth", 180}], checking(world))

      # The repair is how you comply, and complying now means writing it —
      # a field declares itself, so there is no define step to point at.
      assert refusal.repair =~ ~s|heigth = <a value>|
    end

    test "a refused write leaves the world where it was", %{world: world} do
      before = World.tx(world)
      {:error, _} = World.append(world, [{42, "heigth", 180}], checking(world))

      assert World.tx(world) == before
    end

    test "every undefined attribute is reported, not just the first", %{world: world} do
      {:error, refusals} =
        World.append(world, [{42, "one", 1}, {43, "two", 2}], checking(world))

      assert Enum.map(refusals, & &1.attribute) |> Enum.sort() == ["one", "two"]
    end

    test "checking is opt-in, so the vocabulary can be seeded", %{world: world} do
      assert {:ok, _tx} = World.append(world, [{42, "undefined_anywhere", 1}])
    end
  end

  describe "everything extends, nothing redefines" do
    test "a vocabulary composed from another world is visible", %{world: tenant} do
      shared = TestLedger.open()
      {:ok, _} = World.append(shared, Attribute.define("height", answers: "integer"))

      refute Attribute.defined?(Snapshot.open([tenant]), "height")
      assert Attribute.defined?(Snapshot.open([tenant, shared]), "height")
    end
  end

  describe "a declaration is checked against what has already been answered" do
    setup %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("height", answers: "any"))
      :ok
    end

    test "widening costs nothing, because nothing answers differently", %{world: world} do
      {:ok, _} = World.append(world, [{"height", "answers", "integer"}])
      {:ok, _} = World.append(world, [{42, "height", 180}])

      assert {:ok, _tx} =
               World.append(world, [{"height", "answers", "any"}], checking_the_facts(world))

      assert Attribute.answers(Snapshot.open([world]), "height") == "any"
    end

    test "narrowing is accepted when every live answer fits", %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", 180}, {43, "height", 172}])

      assert {:ok, _tx} =
               World.append(
                 world,
                 [{"height", "answers", "integer"}],
                 checking_the_facts(world)
               )
    end

    test "narrowing past the facts is refused", %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", "tall"}, {43, "height", 172}])

      assert {:error, [refusal]} =
               World.append(
                 world,
                 [{"height", "answers", "integer"}],
                 checking_the_facts(world)
               )

      assert refusal.attribute == "height"
      assert refusal.problem == :contradicted
    end

    test "the refusal counts what violates it and says how to find it", %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", "tall"}, {43, "height", "short"}])

      {:error, [refusal]} =
        World.append(world, [{"height", "answers", "integer"}], checking_the_facts(world))

      assert refusal.repair =~ "2 values"
      assert refusal.repair =~ "42"
      assert refusal.repair =~ ~s|Snapshot.find(snapshot, attribute: "height")|
    end

    test "widen, backfill, narrow — with a later fact where another database would rewrite",
         %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", "tall"}, {43, "height", 172}])
      narrowing = [{"height", "answers", "integer"}]

      assert {:error, [_]} = World.append(world, narrowing, checking_the_facts(world))

      {:ok, _} = World.append(world, [{42, "height", 190}])

      assert {:ok, _tx} = World.append(world, narrowing, checking_the_facts(world))
    end

    test "a refused redeclaration leaves the world where it was", %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", "tall"}])
      before = World.tx(world)

      {:error, _} =
        World.append(world, [{"height", "answers", "integer"}], checking_the_facts(world))

      assert World.tx(world) == before
    end

    test "a first declaration is checked too, if facts got there first", %{world: world} do
      {:ok, _} = World.append(world, [{42, "depth", "deep"}])

      assert {:error, [refusal]} =
               World.append(
                 world,
                 Attribute.define("depth", answers: "integer"),
                 checking_the_facts(world)
               )

      assert refusal.attribute == "depth"
    end

    test "saying the same thing again is not a redeclaration", %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", "tall"}])

      assert {:ok, _tx} =
               World.append(
                 world,
                 Attribute.seed() ++ Attribute.define("height", answers: "any"),
                 checking_the_facts(world)
               )
    end

    test "the vocabulary check comes first, so a typo is named as one", %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", "tall"}])

      assert {:error, [refusal]} =
               World.append(
                 world,
                 [{42, "heigth", 1}, {"height", "answers", "integer"}],
                 checking_the_facts(world)
               )

      assert refusal.problem == :undefined
    end

    test "every contradicted declaration is reported, not just the first", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("depth", answers: "any"))
      {:ok, _} = World.append(world, [{42, "height", "tall"}, {42, "depth", "deep"}])

      {:error, refusals} =
        World.append(
          world,
          [{"height", "answers", "integer"}, {"depth", "answers", "integer"}],
          checking_the_facts(world)
        )

      assert Enum.map(refusals, & &1.attribute) |> Enum.sort() == ["depth", "height"]
    end

    test "a shape the engine cannot decide constrains nothing, and says so", %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", "tall"}])

      assert {:ok, _tx} =
               World.append(world, [{"height", "answers", "email"}], checking_the_facts(world))

      assert Attribute.satisfies?("anything at all", "email")
      refute Attribute.satisfies?("tall", "integer")
    end

    test "which answers are live is read the way cardinality is declared today" do
      one = TestLedger.open()
      {:ok, _} = World.append(one, Attribute.seed() ++ Attribute.define("tags", answers: "any"))

      many = TestLedger.open()

      {:ok, _} =
        World.append(
          many,
          Attribute.seed() ++ Attribute.define("tags", answers: "any", cardinality: "many")
        )

      for each <- [one, many] do
        {:ok, _} = World.append(each, [{42, "tags", "loose"}])
        {:ok, _} = World.append(each, [{42, "tags", 1}])
      end

      narrowing = [{"tags", "answers", "integer"}]

      # Under `one` the string was superseded and no longer answers; under
      # `many` it still does, so the same narrowing is refused.
      assert {:ok, _tx} = World.append(one, narrowing, checking_the_facts(one))
      assert {:error, [_]} = World.append(many, narrowing, checking_the_facts(many))
    end
  end

  describe "cardinality changes what answers, so it is refused where answers would move" do
    setup %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("tags", answers: "any"))
      :ok
    end

    test "one to many is free while no id has been corrected", %{world: world} do
      {:ok, _} = World.append(world, [{42, "tags", "a"}, {43, "tags", "b"}])
      to_many = [{"tags", "cardinality", "many"}]

      assert {:ok, _tx} = World.append(world, to_many, checking_the_facts(world))
      assert Attribute.cardinality(Snapshot.open([world]), "tags") == "many"
    end

    test "many to one is free while no id holds two values", %{world: world} do
      {:ok, _} = World.append(world, [{"tags", "cardinality", "many"}])
      {:ok, _} = World.append(world, [{42, "tags", "a"}, {43, "tags", "b"}])

      assert {:ok, _tx} =
               World.append(world, [{"tags", "cardinality", "one"}], checking_the_facts(world))
    end

    test "one to many is refused where it would resurrect a correction", %{world: world} do
      {:ok, _} = World.append(world, [{42, "tags", "a"}])
      {:ok, _} = World.append(world, [{42, "tags", "b"}])
      to_many = [{"tags", "cardinality", "many"}]

      assert {:error, [refusal]} = World.append(world, to_many, checking_the_facts(world))
      assert refusal.attribute == "tags"
      assert refusal.problem == :would_change_answers
      assert refusal.repair =~ "answer again"
    end

    test "many to one is refused where it would silence a live answer", %{world: world} do
      {:ok, _} = World.append(world, [{"tags", "cardinality", "many"}])
      {:ok, _} = World.append(world, [{42, "tags", "a"}, {42, "tags", "b"}])

      assert {:error, [refusal]} =
               World.append(world, [{"tags", "cardinality", "one"}], checking_the_facts(world))

      assert refusal.problem == :would_change_answers
      assert refusal.repair =~ "silence every answer but the latest"
    end

    test "the repair is a second attribute, because history cannot be un-written",
         %{world: world} do
      {:ok, _} = World.append(world, [{42, "tags", "a"}])
      {:ok, _} = World.append(world, [{42, "tags", "b"}])

      {:error, [refusal]} =
        World.append(world, [{"tags", "cardinality", "many"}], checking_the_facts(world))

      assert refusal.repair =~ "1 id"
      assert refusal.repair =~ "Define a second attribute"
      assert refusal.repair =~ ~s|Snapshot.find(snapshot, attribute: "tags")|
    end

    test "writing a value an id already holds is not a correction", %{world: world} do
      {:ok, _} = World.append(world, [{42, "tags", "a"}])
      {:ok, _} = World.append(world, [{42, "tags", "a"}])
      to_many = [{"tags", "cardinality", "many"}]

      assert {:ok, _tx} = World.append(world, to_many, checking_the_facts(world))
    end
  end

  describe "an old snapshot answers what it always answered" do
    test "a widened attribute still answers the old shape at the old name", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
      {:ok, _} = World.append(world, [{42, "height", 180}])
      before = Snapshot.open([world])

      {:ok, _} =
        World.append(world, [{"height", "answers", "any"}], checking_the_facts(world))

      {:ok, _} = World.append(world, [{42, "height", "tall"}])
      now = Snapshot.open([world])

      assert Attribute.answers(before, "height") == "integer"
      assert Snapshot.value(before, 42, "height") == 180

      assert Attribute.answers(now, "height") == "any"
      assert Snapshot.value(now, 42, "height") == "tall"
    end

    test "a widened cardinality is not visible before it was written", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("tags", answers: "any"))
      {:ok, _} = World.append(world, [{42, "tags", "a"}])
      before = Snapshot.open([world])

      {:ok, _} =
        World.append(world, [{"tags", "cardinality", "many"}], checking_the_facts(world))

      assert Attribute.cardinality(before, "tags") == "one"
      assert Attribute.cardinality(Snapshot.open([world]), "tags") == "many"
    end
  end
end
