defmodule Blazie.LoadTest do
  @moduledoc """
  What it costs at size, measured rather than assumed.

  Not a benchmark to win — a guard against the shapes that would make this
  unusable: a query whose cost grows with the world, memory that grows without
  bound, or a subscription storm that stalls writers.

      mix test --include load
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, World, Snapshot, Subscription, TestLedger}

  @moduletag :load
  @moduletag timeout: 600_000

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    %{world: world}
  end

  defp fill(world, count) do
    for chunk <- Enum.chunk_every(1..count, 500) do
      {:ok, _} = World.append(world, Enum.map(chunk, &{&1, "height", &1}))
    end
  end

  defp micros(fun), do: :timer.tc(fun) |> elem(0)

  describe "a targeted question does not get slower as the world grows" do
    test "ten times the facts is not ten times the cost", %{world: world} do
      fill(world, 10_000)
      small = Snapshot.open([world])
      Snapshot.find(small, id: 1)
      at_10k = Enum.map(1..20, fn _ -> micros(fn -> Snapshot.find(small, id: 5_000) end) end)

      fill(world, 100_000)
      big = Snapshot.open([world])
      at_110k = Enum.map(1..20, fn _ -> micros(fn -> Snapshot.find(big, id: 5_000) end) end)

      median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
      before = median.(at_10k)
      after_ = median.(at_110k)

      IO.puts("\n  by id: #{before}us at 10k facts -> #{after_}us at 110k")

      # A scan would be eleven times slower. An index is not.
      assert after_ < before * 4,
             "a targeted question grew #{Float.round(after_ / max(before, 1), 1)}x with the world"
    end
  end

  describe "memory stays where it is put" do
    test "a bounded world holds its bound however much is written" do
      dir = Path.join(System.tmp_dir!(), "lr_load_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      name = {:load, System.unique_integer([:positive])}

      {:ok, world} =
        World.open(name, store: {Blazie.Store.File, dir: dir}, resident: 5_000)

      {:ok, _} = World.append(world, Attribute.seed())
      fill(world, 100_000)

      resident = World.resident(world)
      IO.puts("  resident after 100k writes: #{resident}")

      assert resident < 8_000
      # And it still answers from the store for what it evicted.
      assert [%{value: 1}] = Snapshot.find(Snapshot.open([world]), id: 1)

      World.close(name)
    end
  end

  describe "writes keep flowing under a subscription storm" do
    test "five hundred watchers do not stall the writer", %{world: world} do
      test_process = self()

      for _ <- 1..500 do
        spawn_link(fn ->
          {:ok, _ref} = Subscription.watch([world], attribute: "height")
          send(test_process, :ready)
          receive do: (:never -> :ok)
        end)
      end

      for _ <- 1..500, do: assert_receive(:ready, 10_000)

      elapsed = micros(fn -> for n <- 1..200, do: World.append(world, [{n, "height", n}]) end)
      per_write = div(elapsed, 200)

      IO.puts("  200 writes with 500 watchers: #{per_write}us per write")

      # Fanning out to five hundred processes is real work, but it must not
      # turn a write into something a caller would notice.
      assert per_write < 20_000, "#{per_write}us per write under 500 watchers"
    end
  end

  describe "many ledgers" do
    test "a thousand open at once" do
      names = for n <- 1..1_000, do: {:many, n, System.unique_integer([:positive])}
      on_exit(fn -> Enum.each(names, &World.close/1) end)

      opened = micros(fn -> Enum.each(names, &World.open/1) end)
      IO.puts("  opening 1000 ledgers: #{div(opened, 1000)}us each")

      assert length(World.open_worlds()) >= 1_000
      assert div(opened, 1000) < 5_000
    end
  end
end
