defmodule LazyRiver.Symbol.TextTest do
  @moduledoc """
  The doctrine, executable: a symbol for text is produced by a formula, so the
  ledger accepts it — and the same symbol written directly is refused.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Formula, Ledger, Snapshot, Symbol}
  alias LazyRiver.Symbol.Text
  alias LazyRiver.TestLedger

  @space "sketch_64"
  @width 64

  # A module attribute cannot hold a closure, so the embedder is built here.
  defp embedder, do: &Text.sketch(&1, @width)

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed() ++ Symbol.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("caption", answers: "any"))
    {:ok, _} = Ledger.append(ledger, Text.seed("caption_symbol", @space))

    {:ok, _} =
      Ledger.append(ledger, [
        {1, "caption", "ceramic pan review, no oil needed"},
        {2, "caption", "ceramic pan review, no oil needed"},
        {3, "caption", "running shoes for marathon training"},
        {4, "caption", ""}
      ])

    formula =
      Text.formula(:caption_symbols,
        over: "caption",
        into: "caption_symbol",
        space: @space,
        embed: embedder()
      )

    %{ledger: ledger, formula: formula}
  end

  defp answers(ledger, formula) do
    {assertions, _reads} = Formula.run(formula, Snapshot.open([ledger]))
    assertions
  end

  test "the formula turns text into symbols in its declared space", %{
    ledger: ledger,
    formula: formula
  } do
    assertions = answers(ledger, formula)

    # Three captions carry text; the empty one is not a thing to represent.
    assert length(assertions) == 3

    assert Enum.all?(assertions, fn {_id, attr, sym, by} ->
             attr == "caption_symbol" and sym.space == @space and by == :caption_symbols
           end)

    assert Enum.all?(assertions, fn {_id, _attr, sym, _by} -> Symbol.dimension(sym) == @width end)
  end

  test "a symbol from the formula is accepted where the same symbol written directly is refused",
       %{ledger: ledger, formula: formula} do
    {assertions, _} = Formula.run(formula, Snapshot.open([ledger]))

    # Produced by a formula: every assertion names it, so the check passes.
    assert {:ok, _tx} = Ledger.append(ledger, assertions, check: &Symbol.check/1)

    # The identical answer, written by hand, is a symbol naming no formula.
    loose = [{9, "caption_symbol", Symbol.new(@space, Text.sketch("anything", @width))}]
    assert {:error, [refusal]} = Ledger.append(ledger, loose, check: &Symbol.check/1)
    assert refusal.problem == :symbol_from_outside
  end

  test "the same text always gives the same symbol — a formula is reproducible", %{
    ledger: ledger,
    formula: formula
  } do
    first = answers(ledger, formula)
    second = answers(ledger, formula)
    assert first == second

    # Ids 1 and 2 hold identical captions, so they must land on one point.
    by_id = Map.new(first, fn {id, _attr, sym, _by} -> {id, sym} end)
    assert {:ok, 1.0} = Symbol.near(by_id[1], by_id[2]) |> round_near()
  end

  test "near text sits closer than unrelated text", %{ledger: ledger, formula: formula} do
    by_id = answers(ledger, formula) |> Map.new(fn {id, _a, s, _by} -> {id, s} end)

    {:ok, same} = Symbol.near(by_id[1], by_id[2])
    {:ok, different} = Symbol.near(by_id[1], by_id[3])

    assert same > different
  end

  test "a sketch is normalised, so length does not masquerade as similarity" do
    long = Text.sketch(String.duplicate("ceramic pan ", 50), 64)
    norm = :math.sqrt(Enum.reduce(long, 0.0, fn v, acc -> acc + v * v end))
    assert_in_delta norm, 1.0, 1.0e-9
  end

  test "text with no words yields a zero sketch rather than a crash" do
    assert Enum.all?(Text.sketch("!!! ???", 16), &(&1 == 0.0))
  end

  defp round_near({:ok, value}), do: {:ok, Float.round(value, 6)}
  defp round_near(other), do: other
end
