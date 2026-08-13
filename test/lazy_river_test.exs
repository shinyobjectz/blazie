defmodule LazyRiverTest do
  @moduledoc """
  The doctrine, executable. Each test names the block it holds to account, so
  drift in the engine shows up as a failure rather than as prose going stale.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Fact, Ledger, Snapshot}
  alias LazyRiver.TestLedger

  setup do
    %{a: TestLedger.open(), b: TestLedger.open()}
  end

  describe "one row shape" do
    test "a fact is an id, an attribute, an answer and a transaction", %{a: a} do
      {:ok, tx} = Ledger.append(a, [{42, "height", 180}])

      assert [%Fact{id: 42, attribute: "height", value: 180, tx: ^tx, by: nil}] =
               Ledger.facts_at(a, tx)
    end

    test "an edge is a fact whose answer is another id", %{a: a} do
      {:ok, tx} = Ledger.append(a, [{42, "parent", 7}])
      assert [%Fact{value: 7}] = Ledger.facts_at(a, tx)
    end
  end

  describe "what came from outside happened once" do
    test "a fact naming no formula or job came from outside", %{a: a} do
      {:ok, tx} = Ledger.append(a, [{42, "headline", "hello"}, {42, "vector", [0.1], :potion}])
      [outside, derived] = Ledger.facts_at(a, tx)

      assert Fact.from_outside?(outside)
      refute Fact.from_outside?(derived)
      assert derived.by == :potion
    end
  end

  describe "the database is a snapshot, not a service" do
    test "an answer at a name is the same answer forever", %{a: a} do
      {:ok, _} = Ledger.append(a, [{42, "height", 180}])
      early = Snapshot.open([a])
      name = Snapshot.name(early)

      {:ok, _} = Ledger.append(a, [{42, "height", 181}])

      assert Snapshot.value(early, 42, "height") == 180
      assert Snapshot.value(Snapshot.reopen(name), 42, "height") == 180
      assert Snapshot.value(Snapshot.open([a]), 42, "height") == 181
    end

    test "a name reopens to the same snapshot", %{a: a} do
      {:ok, _} = Ledger.append(a, [{42, "height", 180}])
      snapshot = Snapshot.open([a])

      assert Snapshot.facts(Snapshot.reopen(Snapshot.name(snapshot))) ==
               Snapshot.facts(snapshot)
    end

    test "a writer reads its own write without polling", %{a: a} do
      {:ok, tx} = Ledger.append(a, [{42, "height", 180}])
      assert [%Fact{value: 180}] = Ledger.facts_at(a, tx)
    end

    test "a fact written after a transaction is invisible at it", %{a: a} do
      {:ok, first} = Ledger.append(a, [{42, "height", 180}])
      {:ok, _second} = Ledger.append(a, [{43, "height", 190}])

      assert [%Fact{id: 42}] = Ledger.facts_at(a, first)
    end
  end

  describe "sovereignty is which ledger, not which filter" do
    test "composing returns facts from every ledger opened", %{a: a, b: b} do
      {:ok, _} = Ledger.append(a, [{42, "held_by", :tenant_a}])
      {:ok, _} = Ledger.append(b, [{99, "held_by", :tenant_b}])

      ids = Snapshot.open([a, b]) |> Snapshot.facts() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == [42, 99]
    end

    test "a ledger not opened cannot leak into the answer", %{a: a, b: b} do
      {:ok, _} = Ledger.append(a, [{42, "held_by", :tenant_a}])
      {:ok, _} = Ledger.append(b, [{99, "held_by", :tenant_b}])

      assert [%Fact{id: 42}] = Snapshot.facts(Snapshot.open([a]))
      assert Snapshot.value(Snapshot.open([a]), 99, "held_by") == nil
    end
  end

  describe "nothing is rewritten" do
    test "a later fact corrects an earlier one", %{a: a} do
      {:ok, _} = Ledger.append(a, [{42, "height", 180}])
      {:ok, _} = Ledger.append(a, [{42, "height", 181}])

      snapshot = Snapshot.open([a])

      assert Snapshot.value(snapshot, 42, "height") == 181
      assert length(Snapshot.find(snapshot, id: 42, attribute: "height")) == 2
    end
  end

  describe "reading by pattern" do
    test "an absent key is a wildcard", %{a: a} do
      {:ok, _} = Ledger.append(a, [{42, "height", 180}, {43, "height", 190}, {42, "name", "x"}])
      snapshot = Snapshot.open([a])

      assert length(Snapshot.find(snapshot, attribute: "height")) == 2
      assert length(Snapshot.find(snapshot, id: 42)) == 2
      assert length(Snapshot.find(snapshot, id: 42, attribute: "height")) == 1
      assert length(Snapshot.find(snapshot, [])) == 3
    end
  end
end
