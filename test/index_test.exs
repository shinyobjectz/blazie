defmodule Blazie.IndexTest do
  @moduledoc """
  Facts are reached by a sort order rather than by scanning.

  Doctrine 12: an index is the engine's business. Nothing above the world
  knows these exist — the tests below are about answers being identical and
  the work being smaller.
  """
  use ExUnit.Case, async: true

  alias Blazie.{World, Snapshot, TestLedger}

  setup do
    world = TestLedger.open()

    {:ok, _} =
      World.append(world, [
        {1, "height", 180},
        {1, "colour", "blue"},
        {2, "height", 190},
        {2, "parent", 1}
      ])

    {:ok, _} = World.append(world, [{3, "height", 200}, {3, "parent", 1}])

    %{world: world, snapshot: Snapshot.open([world])}
  end

  describe "every pattern shape answers the same as a scan would" do
    test "by id", %{snapshot: snapshot} do
      found = Snapshot.find(snapshot, id: 1)
      assert length(found) == 2
      assert Enum.all?(found, &(&1.id == 1))
    end

    test "by attribute", %{snapshot: snapshot} do
      assert length(Snapshot.find(snapshot, attribute: "height")) == 3
    end

    test "by id and attribute", %{snapshot: snapshot} do
      assert [%{value: 180}] = Snapshot.find(snapshot, id: 1, attribute: "height")
    end

    test "by answer — the value order", %{snapshot: snapshot} do
      assert [%{id: 2}] = Snapshot.find(snapshot, attribute: "height", value: 190)
    end

    test "by answer alone — edges backwards", %{snapshot: snapshot} do
      # Everything pointing at entity 1.
      found = Snapshot.find(snapshot, value: 1)
      assert Enum.map(found, & &1.id) |> Enum.sort() == [2, 3]
    end

    test "with no pattern at all", %{snapshot: snapshot} do
      assert length(Snapshot.find(snapshot, [])) == 6
    end

    test "a pattern nothing matches", %{snapshot: snapshot} do
      assert Snapshot.find(snapshot, id: 999) == []
      assert Snapshot.find(snapshot, attribute: "never_written") == []
    end
  end

  describe "answers stay ordered and bounded by the name" do
    test "oldest first", %{snapshot: snapshot} do
      txs = Snapshot.find(snapshot, attribute: "height") |> Enum.map(& &1.tx)
      assert txs == Enum.sort(txs)
    end

    test "an earlier name does not see later facts", %{world: world} do
      early = Snapshot.open([world])
      {:ok, _} = World.append(world, [{4, "height", 210}])

      assert length(Snapshot.find(early, attribute: "height")) == 3
      assert length(Snapshot.find(Snapshot.open([world]), attribute: "height")) == 4
    end

    test "composing several ledgers still answers across them", %{world: a} do
      b = TestLedger.open()
      {:ok, _} = World.append(b, [{9, "height", 1}])

      assert length(Snapshot.find(Snapshot.open([a, b]), attribute: "height")) == 4
    end
  end

  describe "the work is smaller, not just the same" do
    @tag timeout: 30_000
    test "a targeted question over a large world stays fast" do
      world = TestLedger.open()

      # 20k facts across 10k entities and two attributes.
      for chunk <- Enum.chunk_every(1..10_000, 500) do
        facts =
          Enum.flat_map(chunk, fn n -> [{n, "height", n}, {n, "colour", "c#{rem(n, 7)}"}] end)

        {:ok, _} = World.append(world, facts)
      end

      snapshot = Snapshot.open([world])

      {by_id, _} = :timer.tc(fn -> Snapshot.find(snapshot, id: 7777) end)
      {by_pair, _} = :timer.tc(fn -> Snapshot.find(snapshot, id: 7777, attribute: "height") end)

      assert Snapshot.find(snapshot, id: 7777) |> length() == 2

      # A full scan and sort of 20k facts per question would not be close to
      # this. Generous enough not to be flaky, tight enough to catch a
      # regression to scanning.
      assert by_id < 20_000, "find by id took #{by_id}us"
      assert by_pair < 20_000, "find by id and attribute took #{by_pair}us"
    end
  end
end
