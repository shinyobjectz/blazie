defmodule Blazie.LoadTest do
  @moduledoc """
  What it costs at size, measured rather than assumed.

  Not a benchmark to win — a guard against the shapes that would make this
  unusable: a query whose cost grows with the ledger, memory that grows without
  bound, or a subscription storm that stalls writers.

      mix test --include load
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Ledger, Snapshot, Subscription, TestLedger}

  @moduletag :load
  @moduletag timeout: 600_000

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
    %{ledger: ledger}
  end

  defp fill(ledger, count) do
    for chunk <- Enum.chunk_every(1..count, 500) do
      {:ok, _} = Ledger.append(ledger, Enum.map(chunk, &{&1, "height", &1}))
    end
  end

  defp micros(fun), do: :timer.tc(fun) |> elem(0)

  describe "a targeted question does not get slower as the ledger grows" do
    test "ten times the facts is not ten times the cost", %{ledger: ledger} do
      fill(ledger, 10_000)
      small = Snapshot.open([ledger])
      Snapshot.find(small, id: 1)
      at_10k = Enum.map(1..20, fn _ -> micros(fn -> Snapshot.find(small, id: 5_000) end) end)

      fill(ledger, 100_000)
      big = Snapshot.open([ledger])
      at_110k = Enum.map(1..20, fn _ -> micros(fn -> Snapshot.find(big, id: 5_000) end) end)

      median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
      before = median.(at_10k)
      after_ = median.(at_110k)

      IO.puts("\n  by id: #{before}us at 10k facts -> #{after_}us at 110k")

      # A scan would be eleven times slower. An index is not.
      assert after_ < before * 4,
             "a targeted question grew #{Float.round(after_ / max(before, 1), 1)}x with the ledger"
    end
  end

  describe "memory stays where it is put" do
    test "a bounded ledger holds its bound however much is written" do
      dir = Path.join(System.tmp_dir!(), "lr_load_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      name = {:load, System.unique_integer([:positive])}

      {:ok, ledger} =
        Ledger.open(name, store: {Blazie.Store.File, dir: dir}, resident: 5_000)

      {:ok, _} = Ledger.append(ledger, Attribute.seed())
      fill(ledger, 100_000)

      resident = Ledger.resident(ledger)
      IO.puts("  resident after 100k writes: #{resident}")

      assert resident < 8_000
      # And it still answers from the store for what it evicted.
      assert [%{value: 1}] = Snapshot.find(Snapshot.open([ledger]), id: 1)

      Ledger.close(name)
    end
  end

  describe "writes keep flowing under a subscription storm" do
    test "five hundred watchers do not stall the writer", %{ledger: ledger} do
      test_process = self()

      for _ <- 1..500 do
        spawn_link(fn ->
          {:ok, _ref} = Subscription.watch([ledger], attribute: "height")
          send(test_process, :ready)
          receive do: (:never -> :ok)
        end)
      end

      for _ <- 1..500, do: assert_receive(:ready, 10_000)

      elapsed = micros(fn -> for n <- 1..200, do: Ledger.append(ledger, [{n, "height", n}]) end)
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
      on_exit(fn -> Enum.each(names, &Ledger.close/1) end)

      opened = micros(fn -> Enum.each(names, &Ledger.open/1) end)
      IO.puts("  opening 1000 ledgers: #{div(opened, 1000)}us each")

      assert length(Ledger.open_ledgers()) >= 1_000
      assert div(opened, 1000) < 5_000
    end
  end
end
