defmodule Blazie.MemoryTest do
  @moduledoc """
  A world holds its facts in RAM, which is fine until it is not.

  Bounding what stays resident only means something when the facts are durable
  somewhere else — with the memory store, the store *is* the memory, so there
  is no bound to give. That asymmetry is tested rather than assumed.
  """
  use ExUnit.Case, async: true

  alias Blazie.{World, Snapshot, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "blazie_mem_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: {:bounded, System.unique_integer([:positive])}}
  end

  defp on_disk(name, dir, opts) do
    {:ok, world} = World.open(name, [store: {Store.File, dir: dir}] ++ opts)
    world
  end

  defp write(world, range) do
    for chunk <- Enum.chunk_every(range, 50) do
      {:ok, _} = World.append(world, Enum.map(chunk, &{&1, "height", &1}))
    end
  end

  describe "a bounded world stops growing" do
    test "it keeps roughly what it was told to", ctx do
      world = on_disk(ctx.name, ctx.dir, resident: 100)
      write(world, 1..1000)

      resident = World.resident(world)
      assert resident <= 150, "kept #{resident}"
      assert resident >= 100

      World.close(ctx.name)
    end

    test "an unbounded world keeps everything, which is the default", ctx do
      world = on_disk(ctx.name, ctx.dir, [])
      write(world, 1..300)

      assert World.resident(world) == 300

      World.close(ctx.name)
    end
  end

  describe "bounding changes what is kept, never what is answered" do
    test "recent facts answer from memory", ctx do
      world = on_disk(ctx.name, ctx.dir, resident: 100)
      write(world, 1..1000)

      assert [%{value: 1000}] = Snapshot.find(Snapshot.open([world]), id: 1000)

      World.close(ctx.name)
    end

    test "evicted facts still answer, from the store", ctx do
      world = on_disk(ctx.name, ctx.dir, resident: 100)
      write(world, 1..1000)

      # Long since evicted from memory.
      assert [%{value: 1}] = Snapshot.find(Snapshot.open([world]), id: 1)
      assert [%{value: 500}] = Snapshot.find(Snapshot.open([world]), id: 500)

      World.close(ctx.name)
    end

    test "a whole-world question is still whole", ctx do
      world = on_disk(ctx.name, ctx.dir, resident: 100)
      write(world, 1..1000)

      assert length(Snapshot.find(Snapshot.open([world]), attribute: "height")) == 1000

      World.close(ctx.name)
    end

    test "an old name still answers what it always answered", ctx do
      world = on_disk(ctx.name, ctx.dir, resident: 100)
      write(world, 1..100)
      early = Snapshot.open([world])

      write(world, 101..1000)

      assert length(Snapshot.find(early, attribute: "height")) == 100

      World.close(ctx.name)
    end
  end

  describe "the memory store has no bound to give" do
    test "it holds everything however small the resident set", ctx do
      {:ok, world} = World.open(ctx.name, resident: 10)
      write(world, 1..300)

      # Resident is bounded — to a transaction boundary, so a 50-fact write
      # keeps 50 however small the setting. But the store kept all 300, because
      # with this store the store is the memory. Nothing was actually saved.
      assert World.resident(world) < 100
      assert length(Snapshot.find(Snapshot.open([world]), attribute: "height")) == 300

      World.close(ctx.name)
    end
  end
end
