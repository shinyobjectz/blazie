defmodule Blazie.MemoryTest do
  @moduledoc """
  A ledger holds its facts in RAM, which is fine until it is not.

  Bounding what stays resident only means something when the facts are durable
  somewhere else — with the memory store, the store *is* the memory, so there
  is no bound to give. That asymmetry is tested rather than assumed.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Ledger, Snapshot, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "blazie_mem_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: {:bounded, System.unique_integer([:positive])}}
  end

  defp on_disk(name, dir, opts) do
    {:ok, ledger} = Ledger.open(name, [store: {Store.File, dir: dir}] ++ opts)
    ledger
  end

  defp write(ledger, range) do
    for chunk <- Enum.chunk_every(range, 50) do
      {:ok, _} = Ledger.append(ledger, Enum.map(chunk, &{&1, "height", &1}))
    end
  end

  describe "a bounded ledger stops growing" do
    test "it keeps roughly what it was told to", ctx do
      ledger = on_disk(ctx.name, ctx.dir, resident: 100)
      write(ledger, 1..1000)

      resident = Ledger.resident(ledger)
      assert resident <= 150, "kept #{resident}"
      assert resident >= 100

      Ledger.close(ctx.name)
    end

    test "an unbounded ledger keeps everything, which is the default", ctx do
      ledger = on_disk(ctx.name, ctx.dir, [])
      write(ledger, 1..300)

      assert Ledger.resident(ledger) == 300

      Ledger.close(ctx.name)
    end
  end

  describe "bounding changes what is kept, never what is answered" do
    test "recent facts answer from memory", ctx do
      ledger = on_disk(ctx.name, ctx.dir, resident: 100)
      write(ledger, 1..1000)

      assert [%{value: 1000}] = Snapshot.find(Snapshot.open([ledger]), id: 1000)

      Ledger.close(ctx.name)
    end

    test "evicted facts still answer, from the store", ctx do
      ledger = on_disk(ctx.name, ctx.dir, resident: 100)
      write(ledger, 1..1000)

      # Long since evicted from memory.
      assert [%{value: 1}] = Snapshot.find(Snapshot.open([ledger]), id: 1)
      assert [%{value: 500}] = Snapshot.find(Snapshot.open([ledger]), id: 500)

      Ledger.close(ctx.name)
    end

    test "a whole-ledger question is still whole", ctx do
      ledger = on_disk(ctx.name, ctx.dir, resident: 100)
      write(ledger, 1..1000)

      assert length(Snapshot.find(Snapshot.open([ledger]), attribute: "height")) == 1000

      Ledger.close(ctx.name)
    end

    test "an old name still answers what it always answered", ctx do
      ledger = on_disk(ctx.name, ctx.dir, resident: 100)
      write(ledger, 1..100)
      early = Snapshot.open([ledger])

      write(ledger, 101..1000)

      assert length(Snapshot.find(early, attribute: "height")) == 100

      Ledger.close(ctx.name)
    end
  end

  describe "the memory store has no bound to give" do
    test "it holds everything however small the resident set", ctx do
      {:ok, ledger} = Ledger.open(ctx.name, resident: 10)
      write(ledger, 1..300)

      # Resident is bounded — to a transaction boundary, so a 50-fact write
      # keeps 50 however small the setting. But the store kept all 300, because
      # with this store the store is the memory. Nothing was actually saved.
      assert Ledger.resident(ledger) < 100
      assert length(Snapshot.find(Snapshot.open([ledger]), attribute: "height")) == 300

      Ledger.close(ctx.name)
    end
  end
end
