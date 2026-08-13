defmodule LazyRiver.Symbol.TextTest do
  @moduledoc """
  Text becomes a symbol through a formula, which is the only way a symbol may
  come to exist. The properties that matter are that it is deterministic and
  that it survives being recomputed — a stand-in you cannot re-derive is a
  number you have to trust.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Formula, Ledger, Snapshot, Symbol, TestLedger}

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("caption"))
    {:ok, _} = Ledger.append(ledger, Symbol.Text.seed("caption_symbol", "sketch_64"))
    %{ledger: ledger}
  end

  defp formula do
    Symbol.Text.embedding("captions",
      over: "caption",
      into: "caption_symbol",
      space: "sketch_64",
      embed: &Symbol.Text.sketch(&1, 64)
    )
  end

  describe "the sketch is an embedder a formula may use" do
    test "the same text gives the same numbers, forever" do
      assert Symbol.Text.sketch("a ceramic pan", 64) == Symbol.Text.sketch("a ceramic pan", 64)
    end

    test "it is normalised, so length is not similarity" do
      for text <- ["short", "a much longer caption with a good many more words in it"] do
        norm =
          text |> Symbol.Text.sketch(64) |> Enum.reduce(0.0, fn v, a -> a + v * v end)

        assert_in_delta norm, 1.0, 0.0001
      end
    end

    test "it is the declared width" do
      assert length(Symbol.Text.sketch("anything", 64)) == 64
      assert length(Symbol.Text.sketch("anything", 256)) == 256
    end

    test "empty text has no direction to point in" do
      assert Enum.all?(Symbol.Text.sketch("", 64), &(&1 == 0.0))
    end

    test "shared words are nearer than unshared ones" do
      a = Symbol.new("s", Symbol.Text.sketch("a ceramic frying pan", 64))
      shares = Symbol.new("s", Symbol.Text.sketch("a ceramic pan", 64))
      shares_nothing = Symbol.new("s", Symbol.Text.sketch("quarterly revenue report", 64))

      {:ok, near} = Symbol.near(a, shares)
      {:ok, far} = Symbol.near(a, shares_nothing)

      assert near > far
    end
  end

  describe "as a formula" do
    test "it writes symbols naming itself", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{1, "caption", "a ceramic pan"}])

      {assertions, _reads} = Formula.run(formula(), Snapshot.open([ledger]))

      assert [{1, "caption_symbol", %Symbol{space: "sketch_64"}, "captions"}] = assertions
    end

    test "the answer is the same at the same snapshot", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{1, "caption", "a ceramic pan"}])
      snapshot = Snapshot.open([ledger])

      assert Formula.run(formula(), snapshot) == Formula.run(formula(), snapshot)
    end

    test "what it wrote passes the symbol check, because a formula made it",
         %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{1, "caption", "a ceramic pan"}])
      {assertions, _} = Formula.run(formula(), Snapshot.open([ledger]))

      assert Symbol.check(assertions) == :ok
      assert {:ok, _tx} = Ledger.append(ledger, assertions, check: &Symbol.check/1)
    end

    test "empty and blank captions are skipped rather than pointed nowhere",
         %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{1, "caption", ""}, {2, "caption", "   "}])

      {assertions, _} = Formula.run(formula(), Snapshot.open([ledger]))

      assert assertions == []
    end

    test "a non-text answer under the same attribute is skipped", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{1, "caption", 42}])

      {assertions, _} = Formula.run(formula(), Snapshot.open([ledger]))

      assert assertions == []
    end

    test "the attribute declares its space, so search cannot cross one",
         %{ledger: ledger} do
      assert Snapshot.answer(Snapshot.open([ledger]), "caption_symbol", "space") == "sketch_64"
    end

    test "search finds the nearest caption", %{ledger: ledger} do
      {:ok, _} =
        Ledger.append(ledger, [
          {1, "caption", "a ceramic frying pan"},
          {2, "caption", "quarterly revenue report"}
        ])

      {assertions, _} = Formula.run(formula(), Snapshot.open([ledger]))
      {:ok, _} = Ledger.append(ledger, assertions)

      query = Symbol.new("sketch_64", Symbol.Text.sketch("ceramic pan", 64))

      [{nearest, _score} | _] =
        Symbol.nearest(Snapshot.open([ledger]), "caption_symbol", query, 2)

      assert nearest.id == 1
    end
  end
end
