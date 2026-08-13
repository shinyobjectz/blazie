defmodule Blazie.ConcurrencyTest do
  @moduledoc """
  What happens when many things happen at once.

  The invariants that have to survive it: transactions are unique and
  contiguous, a snapshot name still answers the same forever, and nothing is
  lost or double-counted when writers race.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Formula, World, Snapshot, Subscription, TestLedger}

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    %{world: world}
  end

  describe "concurrent writers" do
    test "every transaction is unique", %{world: world} do
      txs =
        1..200
        |> Task.async_stream(fn n -> World.append(world, [{n, "height", n}]) end,
          max_concurrency: 50,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, {:ok, tx}} -> tx end)

      assert length(Enum.uniq(txs)) == 200
    end

    test "transactions are contiguous — none skipped, none reused", %{world: world} do
      before = World.tx(world)

      1..200
      |> Task.async_stream(fn n -> World.append(world, [{n, "height", n}]) end,
        max_concurrency: 50,
        timeout: 30_000
      )
      |> Stream.run()

      assert World.tx(world) == before + 200
    end

    test "nothing written is lost", %{world: world} do
      1..300
      |> Task.async_stream(fn n -> World.append(world, [{n, "height", n}]) end,
        max_concurrency: 50,
        timeout: 30_000
      )
      |> Stream.run()

      found = Snapshot.find(Snapshot.open([world]), attribute: "height")

      assert length(found) == 300
      assert found |> Enum.map(& &1.id) |> Enum.sort() == Enum.to_list(1..300)
    end
  end

  describe "reading while writing" do
    test "a name taken mid-storm still answers the same forever", %{world: world} do
      writers =
        Task.async(fn ->
          Enum.each(1..300, fn n -> World.append(world, [{n, "height", n}]) end)
        end)

      Process.sleep(5)
      snapshot = Snapshot.open([world])
      first = Snapshot.find(snapshot, attribute: "height")

      Task.await(writers, 30_000)

      # The storm finished. The name answers exactly what it did mid-storm.
      assert Snapshot.find(snapshot, attribute: "height") == first
      assert length(Snapshot.find(Snapshot.open([world]), attribute: "height")) == 300
    end

    test "concurrent readers all agree", %{world: world} do
      Enum.each(1..100, fn n -> World.append(world, [{n, "height", n}]) end)
      snapshot = Snapshot.open([world])

      answers =
        1..40
        |> Task.async_stream(fn _ -> length(Snapshot.find(snapshot, attribute: "height")) end,
          max_concurrency: 40
        )
        |> Enum.map(fn {:ok, n} -> n end)

      assert Enum.uniq(answers) == [100]
    end
  end

  describe "concurrent opens" do
    test "many processes opening one world get one world" do
      name = "raced-#{System.unique_integer([:positive])}"
      on_exit(fn -> World.close(name) end)

      refs =
        1..40
        |> Task.async_stream(fn _ -> World.open(name) end, max_concurrency: 40)
        |> Enum.map(fn {:ok, {:ok, ref}} -> ref end)

      assert Enum.uniq(refs) |> length() == 1
      assert length(World.open_worlds() |> Enum.filter(&(&1 == name))) == 1
    end
  end

  describe "many subscriptions" do
    test "a hundred watchers all get the answer", %{world: world} do
      test_process = self()

      watchers =
        for n <- 1..100 do
          spawn_link(fn ->
            {:ok, ref} = Subscription.watch([world], attribute: "height")
            send(test_process, {:ready, n})

            receive do
              {:blazie, ^ref, answer} ->
                send(test_process, {:answered, n, length(answer.facts)})
            after
              5_000 -> send(test_process, {:timeout, n})
            end
          end)
        end

      for _ <- 1..100, do: assert_receive({:ready, _}, 5_000)

      {:ok, _} = World.append(world, [{1, "height", 1}])

      counts =
        for _ <- 1..100 do
          receive do
            {:answered, _, count} -> count
            {:timeout, n} -> flunk("watcher #{n} never heard")
          after
            10_000 -> flunk("a watcher never reported")
          end
        end

      assert Enum.uniq(counts) == [1]
      Enum.each(watchers, &Process.unlink/1)
    end
  end

  describe "formulas under load" do
    test "the same snapshot gives the same answer to everyone", %{world: world} do
      Enum.each(1..100, fn n -> World.append(world, [{n, "height", n}]) end)

      doubling =
        Formula.new("doubling", fn snapshot ->
          for fact <- Snapshot.find(snapshot, attribute: "height") do
            {fact.id, "doubled", fact.value * 2}
          end
        end)

      snapshot = Snapshot.open([world])

      answers =
        1..30
        |> Task.async_stream(fn _ -> Formula.run(doubling, snapshot) |> elem(0) end,
          max_concurrency: 30
        )
        |> Enum.map(fn {:ok, a} -> Enum.sort(a) end)

      assert Enum.uniq(answers) |> length() == 1
    end
  end
end
