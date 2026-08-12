defmodule LazyRiver.FormulaTest do
  @moduledoc """
  The doctrine, executable — the blocks about formulas, provenance, and the
  graph being observed rather than declared.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Fact, Formula, Ledger, Snapshot}
  alias LazyRiver.TestLedger

  setup do
    %{ledger: TestLedger.open()}
  end

  defp doubled do
    Formula.new(:doubled, fn snapshot ->
      for fact <- Snapshot.find(snapshot, attribute: "height") do
        {fact.id, "double_height", fact.answer * 2}
      end
    end)
  end

  describe "a formula is a fact" do
    test "every fact it produced names it", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      {assertions, _reads} = Formula.run(doubled(), Snapshot.open([ledger]))

      assert assertions == [{42, "double_height", 360, :doubled}]
    end

    test "materializing writes facts that name the formula", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      snapshot = Snapshot.open([ledger])

      {:ok, tx, _reads} = Formula.materialize(doubled(), snapshot, ledger)

      assert [%Fact{attribute: "double_height", answer: 360, by: :doubled} = fact] =
               Ledger.facts_at(ledger, tx) |> Enum.filter(&(&1.tx == tx))

      refute Fact.from_outside?(fact)
    end

    test "provenance is a column, so what a formula made is a question", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      {:ok, _, _} = Formula.materialize(doubled(), Snapshot.open([ledger]), ledger)

      snapshot = Snapshot.open([ledger])
      assert [%Fact{attribute: "double_height"}] = Snapshot.find(snapshot, by: :doubled)
    end
  end

  describe "the graph is observed, not declared" do
    test "running a formula records what it read", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      {_assertions, reads} = Formula.run(doubled(), Snapshot.open([ledger]))

      assert reads == [[attribute: "height"]]
    end

    test "a formula carries nothing but its identity and its answer" do
      # No inputs field, no dependency list, no schedule. If one is ever added,
      # the graph has stopped being observed and this fails.
      assert doubled() |> Map.from_struct() |> Map.keys() |> Enum.sort() == [:compute, :id]
    end
  end

  describe "a formula says what, never when" do
    test "the same snapshot gives the same answer", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      snapshot = Snapshot.open([ledger])

      {first, _} = Formula.run(doubled(), snapshot)
      {:ok, _} = Ledger.append(ledger, [{43, "height", 190}])
      {second, _} = Formula.run(doubled(), snapshot)

      assert first == second
    end

    test "a later snapshot gives a later answer", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      {early, _} = Formula.run(doubled(), Snapshot.open([ledger]))

      {:ok, _} = Ledger.append(ledger, [{43, "height", 190}])
      {late, _} = Formula.run(doubled(), Snapshot.open([ledger]))

      assert length(early) == 1
      assert length(late) == 2
    end
  end

  describe "re-execution is bounded by the read set" do
    setup %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      before = Snapshot.open([ledger])
      {_assertions, reads} = Formula.run(doubled(), before)
      %{before: before, reads: reads}
    end

    test "a fact inside the read set makes it stale", ctx do
      {:ok, _} = Ledger.append(ctx.ledger, [{43, "height", 190}])
      arrived = Formula.since(ctx.before, Snapshot.open([ctx.ledger]))

      assert Formula.stale?(ctx.reads, arrived)
    end

    test "a fact outside the read set does not", ctx do
      {:ok, _} = Ledger.append(ctx.ledger, [{43, "favourite_colour", :green}])
      arrived = Formula.since(ctx.before, Snapshot.open([ctx.ledger]))

      assert arrived != []
      refute Formula.stale?(ctx.reads, arrived)
    end

    test "nothing arriving is never stale", ctx do
      assert Formula.since(ctx.before, Snapshot.open([ctx.ledger])) == []
      refute Formula.stale?(ctx.reads, [])
    end
  end

  describe "tracking is off unless a formula turned it on" do
    test "an ordinary read records nothing", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      Snapshot.find(Snapshot.open([ledger]), attribute: "height")

      assert Process.get(:lazy_river_reads) == nil
    end

    test "tracking is restored after a formula runs", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      Formula.run(doubled(), Snapshot.open([ledger]))

      assert Process.get(:lazy_river_reads) == nil
    end
  end
end
