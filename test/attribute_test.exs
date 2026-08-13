defmodule Blazie.AttributeTest do
  @moduledoc """
  The doctrine, executable — schema as facts, and every write checked with a
  refusal that carries its repair.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Ledger, Snapshot}
  alias Blazie.TestLedger

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed())
    %{ledger: ledger}
  end

  defp known(ledger), do: Attribute.known(Snapshot.open([ledger]))
  defp checking(ledger), do: [check: &Attribute.check(&1, known(ledger))]

  # The vocabulary, and what a redeclaration would do to the facts already
  # written. Built fresh on every append, because that is the point.
  defp checking_the_facts(ledger),
    do: [check: &Attribute.check(&1, Snapshot.open([ledger]))]

  describe "schema is facts" do
    test "an attribute is defined by writing facts about it", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
      snapshot = Snapshot.open([ledger])

      assert Attribute.defined?(snapshot, "height")
      assert Snapshot.value(snapshot, "height", "is") == "attribute"
      assert Snapshot.value(snapshot, "height", "answers") == "integer"
    end

    test "definitions are ordinary facts in the same row shape", %{ledger: ledger} do
      {:ok, tx} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))

      Ledger.facts_at(ledger, tx)
      |> Enum.filter(&(&1.tx == tx))
      |> Enum.each(fn fact -> assert fact.id == "height" end)
    end

    test "the vocabulary bootstraps itself", %{ledger: ledger} do
      snapshot = Snapshot.open([ledger])

      for name <- Attribute.root() do
        assert Attribute.defined?(snapshot, name)
      end
    end
  end

  describe "if an attribute can say it, the engine does not grow" do
    test "cardinality is a fact about the attribute", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("tags", cardinality: "many"))
      snapshot = Snapshot.open([ledger])

      assert Attribute.cardinality(snapshot, "tags") == "many"
      assert Attribute.cardinality(snapshot, "is") == "one"
    end

    test "an undeclared attribute answers with the default", %{ledger: ledger} do
      snapshot = Snapshot.open([ledger])

      assert Attribute.cardinality(snapshot, "never_defined") == "one"
      assert Attribute.answers(snapshot, "never_defined") == "any"
    end
  end

  describe "every write is checked, and a refusal carries its repair" do
    test "a defined attribute is accepted", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))

      assert {:ok, _tx} = Ledger.append(ledger, [{42, "height", 180}], checking(ledger))
    end

    test "an undefined attribute is refused", %{ledger: ledger} do
      assert {:error, [refusal]} =
               Ledger.append(ledger, [{42, "heigth", 180}], checking(ledger))

      assert refusal.attribute == "heigth"
      assert refusal.problem == :undefined
    end

    test "the refusal says how to comply", %{ledger: ledger} do
      {:error, [refusal]} = Ledger.append(ledger, [{42, "heigth", 180}], checking(ledger))

      assert refusal.repair =~ ~s|Attribute.define("heigth")|
    end

    test "a refused write leaves the ledger where it was", %{ledger: ledger} do
      before = Ledger.tx(ledger)
      {:error, _} = Ledger.append(ledger, [{42, "heigth", 180}], checking(ledger))

      assert Ledger.tx(ledger) == before
    end

    test "every undefined attribute is reported, not just the first", %{ledger: ledger} do
      {:error, refusals} =
        Ledger.append(ledger, [{42, "one", 1}, {43, "two", 2}], checking(ledger))

      assert Enum.map(refusals, & &1.attribute) |> Enum.sort() == ["one", "two"]
    end

    test "checking is opt-in, so the vocabulary can be seeded", %{ledger: ledger} do
      assert {:ok, _tx} = Ledger.append(ledger, [{42, "undefined_anywhere", 1}])
    end
  end

  describe "everything extends, nothing redefines" do
    test "a vocabulary composed from another ledger is visible", %{ledger: tenant} do
      shared = TestLedger.open()
      {:ok, _} = Ledger.append(shared, Attribute.define("height", answers: "integer"))

      refute Attribute.defined?(Snapshot.open([tenant]), "height")
      assert Attribute.defined?(Snapshot.open([tenant, shared]), "height")
    end
  end

  describe "a declaration is checked against what has already been answered" do
    setup %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "any"))
      :ok
    end

    test "widening costs nothing, because nothing answers differently", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{"height", "answers", "integer"}])
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

      assert {:ok, _tx} =
               Ledger.append(ledger, [{"height", "answers", "any"}], checking_the_facts(ledger))

      assert Attribute.answers(Snapshot.open([ledger]), "height") == "any"
    end

    test "narrowing is accepted when every live answer fits", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}, {43, "height", 172}])

      assert {:ok, _tx} =
               Ledger.append(
                 ledger,
                 [{"height", "answers", "integer"}],
                 checking_the_facts(ledger)
               )
    end

    test "narrowing past the facts is refused", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}, {43, "height", 172}])

      assert {:error, [refusal]} =
               Ledger.append(
                 ledger,
                 [{"height", "answers", "integer"}],
                 checking_the_facts(ledger)
               )

      assert refusal.attribute == "height"
      assert refusal.problem == :contradicted
    end

    test "the refusal counts what violates it and says how to find it", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}, {43, "height", "short"}])

      {:error, [refusal]} =
        Ledger.append(ledger, [{"height", "answers", "integer"}], checking_the_facts(ledger))

      assert refusal.repair =~ "2 values"
      assert refusal.repair =~ "42"
      assert refusal.repair =~ ~s|Snapshot.find(snapshot, attribute: "height")|
    end

    test "widen, backfill, narrow — with a later fact where another database would rewrite",
         %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}, {43, "height", 172}])
      narrowing = [{"height", "answers", "integer"}]

      assert {:error, [_]} = Ledger.append(ledger, narrowing, checking_the_facts(ledger))

      {:ok, _} = Ledger.append(ledger, [{42, "height", 190}])

      assert {:ok, _tx} = Ledger.append(ledger, narrowing, checking_the_facts(ledger))
    end

    test "a refused redeclaration leaves the ledger where it was", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}])
      before = Ledger.tx(ledger)

      {:error, _} =
        Ledger.append(ledger, [{"height", "answers", "integer"}], checking_the_facts(ledger))

      assert Ledger.tx(ledger) == before
    end

    test "a first declaration is checked too, if facts got there first", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "depth", "deep"}])

      assert {:error, [refusal]} =
               Ledger.append(
                 ledger,
                 Attribute.define("depth", answers: "integer"),
                 checking_the_facts(ledger)
               )

      assert refusal.attribute == "depth"
    end

    test "saying the same thing again is not a redeclaration", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}])

      assert {:ok, _tx} =
               Ledger.append(
                 ledger,
                 Attribute.seed() ++ Attribute.define("height", answers: "any"),
                 checking_the_facts(ledger)
               )
    end

    test "the vocabulary check comes first, so a typo is named as one", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}])

      assert {:error, [refusal]} =
               Ledger.append(
                 ledger,
                 [{42, "heigth", 1}, {"height", "answers", "integer"}],
                 checking_the_facts(ledger)
               )

      assert refusal.problem == :undefined
    end

    test "every contradicted declaration is reported, not just the first", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("depth", answers: "any"))
      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}, {42, "depth", "deep"}])

      {:error, refusals} =
        Ledger.append(
          ledger,
          [{"height", "answers", "integer"}, {"depth", "answers", "integer"}],
          checking_the_facts(ledger)
        )

      assert Enum.map(refusals, & &1.attribute) |> Enum.sort() == ["depth", "height"]
    end

    test "a shape the engine cannot decide constrains nothing, and says so", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}])

      assert {:ok, _tx} =
               Ledger.append(ledger, [{"height", "answers", "email"}], checking_the_facts(ledger))

      assert Attribute.satisfies?("anything at all", "email")
      refute Attribute.satisfies?("tall", "integer")
    end

    test "which answers are live is read the way cardinality is declared today" do
      one = TestLedger.open()
      {:ok, _} = Ledger.append(one, Attribute.seed() ++ Attribute.define("tags", answers: "any"))

      many = TestLedger.open()

      {:ok, _} =
        Ledger.append(
          many,
          Attribute.seed() ++ Attribute.define("tags", answers: "any", cardinality: "many")
        )

      for each <- [one, many] do
        {:ok, _} = Ledger.append(each, [{42, "tags", "loose"}])
        {:ok, _} = Ledger.append(each, [{42, "tags", 1}])
      end

      narrowing = [{"tags", "answers", "integer"}]

      # Under `one` the string was superseded and no longer answers; under
      # `many` it still does, so the same narrowing is refused.
      assert {:ok, _tx} = Ledger.append(one, narrowing, checking_the_facts(one))
      assert {:error, [_]} = Ledger.append(many, narrowing, checking_the_facts(many))
    end
  end

  describe "cardinality changes what answers, so it is refused where answers would move" do
    setup %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("tags", answers: "any"))
      :ok
    end

    test "one to many is free while no id has been corrected", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "a"}, {43, "tags", "b"}])
      to_many = [{"tags", "cardinality", "many"}]

      assert {:ok, _tx} = Ledger.append(ledger, to_many, checking_the_facts(ledger))
      assert Attribute.cardinality(Snapshot.open([ledger]), "tags") == "many"
    end

    test "many to one is free while no id holds two values", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{"tags", "cardinality", "many"}])
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "a"}, {43, "tags", "b"}])

      assert {:ok, _tx} =
               Ledger.append(ledger, [{"tags", "cardinality", "one"}], checking_the_facts(ledger))
    end

    test "one to many is refused where it would resurrect a correction", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "a"}])
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "b"}])
      to_many = [{"tags", "cardinality", "many"}]

      assert {:error, [refusal]} = Ledger.append(ledger, to_many, checking_the_facts(ledger))
      assert refusal.attribute == "tags"
      assert refusal.problem == :would_change_answers
      assert refusal.repair =~ "answer again"
    end

    test "many to one is refused where it would silence a live answer", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{"tags", "cardinality", "many"}])
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "a"}, {42, "tags", "b"}])

      assert {:error, [refusal]} =
               Ledger.append(ledger, [{"tags", "cardinality", "one"}], checking_the_facts(ledger))

      assert refusal.problem == :would_change_answers
      assert refusal.repair =~ "silence every answer but the latest"
    end

    test "the repair is a second attribute, because history cannot be un-written",
         %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "a"}])
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "b"}])

      {:error, [refusal]} =
        Ledger.append(ledger, [{"tags", "cardinality", "many"}], checking_the_facts(ledger))

      assert refusal.repair =~ "1 id"
      assert refusal.repair =~ "Define a second attribute"
      assert refusal.repair =~ ~s|Snapshot.find(snapshot, attribute: "tags")|
    end

    test "writing a value an id already holds is not a correction", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "a"}])
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "a"}])
      to_many = [{"tags", "cardinality", "many"}]

      assert {:ok, _tx} = Ledger.append(ledger, to_many, checking_the_facts(ledger))
    end
  end

  describe "an old snapshot answers what it always answered" do
    test "a widened attribute still answers the old shape at the old name", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      before = Snapshot.open([ledger])

      {:ok, _} =
        Ledger.append(ledger, [{"height", "answers", "any"}], checking_the_facts(ledger))

      {:ok, _} = Ledger.append(ledger, [{42, "height", "tall"}])
      now = Snapshot.open([ledger])

      assert Attribute.answers(before, "height") == "integer"
      assert Snapshot.value(before, 42, "height") == 180

      assert Attribute.answers(now, "height") == "any"
      assert Snapshot.value(now, 42, "height") == "tall"
    end

    test "a widened cardinality is not visible before it was written", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("tags", answers: "any"))
      {:ok, _} = Ledger.append(ledger, [{42, "tags", "a"}])
      before = Snapshot.open([ledger])

      {:ok, _} =
        Ledger.append(ledger, [{"tags", "cardinality", "many"}], checking_the_facts(ledger))

      assert Attribute.cardinality(before, "tags") == "one"
      assert Attribute.cardinality(Snapshot.open([ledger]), "tags") == "many"
    end
  end
end
