defmodule Blazie.StoreTest do
  @moduledoc """
  Persistence behind the world seam, and what each store honestly gives you.
  """
  use ExUnit.Case, async: true

  alias Blazie.{World, Snapshot, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "blazie_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: {:tenant, System.unique_integer([:positive])}}
  end

  defp on_disk(name, dir, opts \\ []) do
    {:ok, world} = World.open(name, store: {Store.File, [dir: dir] ++ opts})
    world
  end

  describe "a world survives a restart" do
    test "facts are still there after closing and reopening", ctx do
      world = on_disk(ctx.name, ctx.dir)
      {:ok, _} = World.append(world, [{42, "height", 180}])
      {:ok, _} = World.append(world, [{42, "height", 181}])
      :ok = World.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir)
      snapshot = Snapshot.open([reopened])

      assert Snapshot.value(snapshot, 42, "height") == 181
      assert length(Snapshot.find(snapshot, id: 42, attribute: "height")) == 2

      World.close(ctx.name)
    end

    test "the transaction counter resumes rather than restarting", ctx do
      world = on_disk(ctx.name, ctx.dir)
      {:ok, _} = World.append(world, [{1, "x", 1}])
      {:ok, two} = World.append(world, [{2, "x", 2}])
      :ok = World.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir)

      assert World.tx(reopened) == two
      assert {:ok, three} = World.append(reopened, [{3, "x", 3}])
      assert three == two + 1

      World.close(ctx.name)
    end

    test "a name that is any term still gets a file", ctx do
      # Unique per run, because a world name is global. Hard-coding `{:tenant, 1}`
      # here raced the setup's own `{:tenant, unique_integer()}` — when the
      # counter reached 1 the two tests shared one world, `World.open/2`
      # handed back the one already open, and the file appeared in the other
      # test's directory. About one run in ten, and nothing to do with stores.
      n = System.unique_integer([:positive])

      for name <- [{:tenant, n}, "a string #{n}", %{tenant: n}, ["nested", ["list", n]]] do
        world = on_disk(name, ctx.dir)
        {:ok, _} = World.append(world, [{1, "x", 1}])
        :ok = World.close(name)

        assert File.exists?(Path.join(ctx.dir, Store.File.filename(name)))
      end
    end

    test "reopening a name nothing was ever written under is empty", ctx do
      world = on_disk(ctx.name, ctx.dir)

      assert World.tx(world) == 0
      assert Snapshot.facts(Snapshot.open([world])) == []

      World.close(ctx.name)
    end
  end

  describe "a torn tail loses only the transaction that never finished" do
    test "everything before the tear survives", ctx do
      world = on_disk(ctx.name, ctx.dir)
      {:ok, _} = World.append(world, [{1, "x", 1}])
      {:ok, _} = World.append(world, [{2, "x", 2}])
      :ok = World.close(ctx.name)

      # A process killed mid-write leaves a record that claims more bytes than
      # it wrote.
      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      File.write!(path, <<999_999::32, 0::32, "half a record">>, [:append])

      reopened = on_disk(ctx.name, ctx.dir)

      assert World.tx(reopened) == 2
      assert length(Snapshot.facts(Snapshot.open([reopened]))) == 2

      World.close(ctx.name)
    end

    test "a corrupted record stops the read rather than being trusted", ctx do
      world = on_disk(ctx.name, ctx.dir)
      {:ok, _} = World.append(world, [{1, "x", 1}])
      :ok = World.close(ctx.name)

      # Right length, wrong checksum.
      payload = :erlang.term_to_binary([:garbage])
      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      File.write!(path, <<byte_size(payload)::32, 0::32, payload::binary>>, [:append])

      reopened = on_disk(ctx.name, ctx.dir)

      assert length(Snapshot.facts(Snapshot.open([reopened]))) == 1

      World.close(ctx.name)
    end
  end

  describe "what each store gives you, stated rather than implied" do
    test "memory forgets on close, and that is the whole difference", ctx do
      {:ok, world} = World.open(ctx.name)
      {:ok, _} = World.append(world, [{42, "height", 180}])
      :ok = World.close(ctx.name)

      {:ok, reopened} = World.open(ctx.name)
      assert World.tx(reopened) == 0

      World.close(ctx.name)
    end

    test "fsync is opt-in, and opting in still works", ctx do
      world = on_disk(ctx.name, ctx.dir, sync: true)
      {:ok, _} = World.append(world, [{42, "height", 180}])
      :ok = World.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir, sync: true)
      assert Snapshot.value(Snapshot.open([reopened]), 42, "height") == 180

      World.close(ctx.name)
    end
  end
end
