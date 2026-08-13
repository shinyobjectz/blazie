defmodule Blazie.SymbolTest do
  @moduledoc """
  The doctrine, executable — assert and represent share a row, and the two
  rulings recorded on `sym` are enforced rather than described.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Fact, Formula, World, Snapshot, Symbol}
  alias Blazie.TestLedger

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Symbol.seed())

    {:ok, _} =
      World.append(world, Attribute.define("embedding", answers: "symbol", space: "potion_256"))

    %{world: world}
  end

  describe "assert and represent are different, and share a row" do
    test "a symbol is an ordinary answer", %{world: world} do
      symbol = Symbol.new("potion_256", [1.0, 0.0])
      {:ok, tx} = World.append(world, [{42, "embedding", symbol, :potion}])

      assert [%Fact{attribute: "embedding", value: ^symbol, by: :potion}] =
               World.facts_at(world, tx) |> Enum.filter(&(&1.tx == tx))
    end

    test "an attribute declares its space", %{world: world} do
      snapshot = Snapshot.open([world])

      assert Snapshot.value(snapshot, "embedding", "space") == "potion_256"
      assert Snapshot.value(snapshot, "embedding", "answers") == "symbol"
    end
  end

  describe "a symbol is always produced by a formula" do
    test "one taken from outside is refused", %{world: world} do
      loose = [{42, "embedding", Symbol.new("potion_256", [1.0, 0.0])}]

      assert {:error, [refusal]} = World.append(world, loose, check: &Symbol.check/1)
      assert refusal.problem == :symbol_from_outside
      assert refusal.repair =~ "naming no formula"
    end

    test "one a formula produced is accepted", %{world: world} do
      {:ok, _} = World.append(world, [{42, "height", 180}])

      embed =
        Formula.new(:potion, fn snapshot ->
          for fact <- Snapshot.find(snapshot, attribute: "height") do
            {fact.id, "embedding", Symbol.new("potion_256", [fact.value / 100, 1.0])}
          end
        end)

      {assertions, _reads} = Formula.run(embed, Snapshot.open([world]))

      assert Symbol.check(assertions) == :ok
      assert {:ok, _tx} = World.append(world, assertions, check: &Symbol.check/1)
    end

    test "a literal answer is untouched by the check", %{world: world} do
      assert Symbol.check([{42, "height", 180}]) == :ok
      assert {:ok, _} = World.append(world, [{42, "height", 180}], check: &Symbol.check/1)
    end
  end

  describe "comparing across spaces is refused" do
    test "nearness within a space is a number" do
      a = Symbol.new("potion_256", [1.0, 0.0])
      b = Symbol.new("potion_256", [1.0, 0.0])

      assert {:ok, score} = Symbol.near(a, b)
      assert_in_delta score, 1.0, 0.0001
    end

    test "orthogonal is zero, opposite is minus one" do
      assert {:ok, zero} = Symbol.near(Symbol.new("s", [1.0, 0.0]), Symbol.new("s", [0.0, 1.0]))
      assert {:ok, minus} = Symbol.near(Symbol.new("s", [1.0, 0.0]), Symbol.new("s", [-1.0, 0.0]))

      assert_in_delta zero, 0.0, 0.0001
      assert_in_delta minus, -1.0, 0.0001
    end

    test "across spaces is refused, with why" do
      assert {:error, refusal} =
               Symbol.near(Symbol.new("potion_256", [1.0]), Symbol.new("openai_1536", [1.0]))

      assert refusal.problem == :different_spaces
      assert refusal.repair =~ "different spaces"
    end

    test "a space of two widths is refused" do
      assert {:error, refusal} =
               Symbol.near(Symbol.new("potion_256", [1.0, 0.0]), Symbol.new("potion_256", [1.0]))

      assert refusal.problem == :dimension_mismatch
    end

    test "a zero symbol is near nothing rather than crashing" do
      assert {:ok, score} = Symbol.near(Symbol.new("s", [0.0, 0.0]), Symbol.new("s", [1.0, 0.0]))
      assert_in_delta score, 0.0, 0.0001
    end
  end

  describe "search is one pass, exact" do
    setup %{world: world} do
      {:ok, _} =
        World.append(world, [
          {1, "embedding", Symbol.new("potion_256", [1.0, 0.0]), :potion},
          {2, "embedding", Symbol.new("potion_256", [0.9, 0.1]), :potion},
          {3, "embedding", Symbol.new("potion_256", [0.0, 1.0]), :potion}
        ])

      %{snapshot: Snapshot.open([world])}
    end

    test "nearest returns the nearest first", %{snapshot: snapshot} do
      query = Symbol.new("potion_256", [1.0, 0.0])

      assert [{%Fact{id: 1}, _}, {%Fact{id: 2}, _}] =
               Symbol.nearest(snapshot, "embedding", query, 2)
    end

    test "k bounds the answer", %{snapshot: snapshot} do
      query = Symbol.new("potion_256", [1.0, 0.0])
      assert length(Symbol.nearest(snapshot, "embedding", query, 1)) == 1
      assert length(Symbol.nearest(snapshot, "embedding", query, 10)) == 3
    end

    test "another space is skipped, not refused", %{world: world, snapshot: _} do
      {:ok, _} =
        World.append(world, [{4, "embedding", Symbol.new("openai_1536", [1.0, 0.0]), :openai}])

      query = Symbol.new("potion_256", [1.0, 0.0])
      found = Symbol.nearest(Snapshot.open([world]), "embedding", query, 10)

      assert Enum.map(found, fn {fact, _} -> fact.id end) |> Enum.sort() == [1, 2, 3]
    end

    test "a literal answer under the same attribute is skipped", %{world: world} do
      {:ok, _} = World.append(world, [{5, "embedding", "not a symbol"}])

      query = Symbol.new("potion_256", [1.0, 0.0])
      found = Symbol.nearest(Snapshot.open([world]), "embedding", query, 10)

      refute Enum.any?(found, fn {fact, _} -> fact.id == 5 end)
    end
  end
end
