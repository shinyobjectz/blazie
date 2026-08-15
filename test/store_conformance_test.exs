defmodule Blazie.StoreConformance do
  @moduledoc """
  What EVERY store must honor, stated once and asked of each.

  The seam (`Blazie.Store`) is four required callbacks and three optional
  ones, but the contract is bigger than the typespecs: ordering, resumption,
  bounded residency never changing answers, old names answering forever,
  erasure reaching evicted facts. Those held for Memory, File and Paged by
  three separate test files repeating themselves; a fourth store (SQLite is
  coming) would have made it four. This macro is the one statement.

  Format-level properties — torn tails, corrupted records, checkpoints, the
  same-file-under-either-store guarantee — stay in the per-store files, where
  they belong: they are claims about bytes, not about the seam.

  Use: `use Blazie.StoreConformance, store_module: module | nil, durable?: bool`.
  `nil` means the default (memory) store; `durable?: false`
  skips the close-and-reopen family a memory store honestly cannot pass.
  `world_opts:` rides along on every open — how the `resident: :none`
  consumer asks the same questions of a world that keeps nothing warm.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [conf: opts] do
      use ExUnit.Case, async: false

      alias Blazie.{Attribute, Erasure, Keyring, Snapshot, World}

      @store_module conf[:store_module]
      @durable conf[:durable?]
      @world_opts conf[:world_opts] || []

      setup do
        dir = Path.join(System.tmp_dir!(), "conform-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf!(dir) end)
        %{dir: dir, name: {:conform, System.unique_integer([:positive])}}
      end

      defp store_opts(dir) do
        case @store_module do
          nil -> []
          module -> [store: {module, dir: dir}]
        end
      end

      # `extra` first: a test that names its own residency wins over the
      # consumer's default (Keyword.get takes the first occurrence).
      defp opened(name, dir, extra \\ []) do
        {:ok, world} = World.open(name, store_opts(dir) ++ extra ++ @world_opts)
        world
      end

      defp reopened(name, dir, extra \\ []) do
        :ok = World.close(name)
        opened(name, dir, extra)
      end

      test "appends answer back, latest value winning", ctx do
        world = opened(ctx.name, ctx.dir)
        {:ok, _} = World.append(world, [{42, "height", 180}])
        {:ok, _} = World.append(world, [{42, "height", 181}])

        snapshot = Snapshot.open([world])
        assert Snapshot.value(snapshot, 42, "height") == 181
        assert length(Snapshot.find(snapshot, id: 42, attribute: "height")) == 2
        World.close(ctx.name)
      end

      test "within ONE transaction, the later fact wins", ctx do
        # The landmine no per-store file ever asked about: two facts for the
        # same {id, attribute} in one append resolve by POSITION, and every
        # store must hand them back in the order they went down. A store that
        # sorts by tx alone answers this wrong intermittently.
        world = opened(ctx.name, ctx.dir)
        {:ok, _} = World.append(world, [{42, "height", 180}, {42, "height", 181}])

        assert Snapshot.value(Snapshot.open([world]), 42, "height") == 181
        World.close(ctx.name)
      end

      test "replay order is write order, oldest first", ctx do
        world = opened(ctx.name, ctx.dir)
        {:ok, _} = World.append(world, [{1, "x", "a"}, {2, "x", "b"}])
        {:ok, _} = World.append(world, [{3, "x", "c"}])

        values = Snapshot.facts(Snapshot.open([world])) |> Enum.map(& &1.value)
        assert values == ["a", "b", "c"]
        World.close(ctx.name)
      end

      test "a never-written name is empty, not an error", ctx do
        world = opened(ctx.name, ctx.dir)
        assert World.tx(world) == 0
        assert Snapshot.facts(Snapshot.open([world])) == []
        World.close(ctx.name)
      end

      test "an old snapshot name answers what it always answered", ctx do
        world = opened(ctx.name, ctx.dir)
        {:ok, _} = World.append(world, [{1, "n", 1}])
        early = Snapshot.open([world])

        for i <- 2..50, do: {:ok, _} = World.append(world, [{i, "n", i}])

        assert length(Snapshot.find(early, attribute: "n")) == 1
        World.close(ctx.name)
      end

      test "bounded residency changes what is kept, never what is answered", ctx do
        world = opened(ctx.name, ctx.dir, resident: 20)

        for chunk <- Enum.chunk_every(1..300, 10) do
          {:ok, _} = World.append(world, Enum.map(chunk, &{&1, "n", &1}))
        end

        snapshot = Snapshot.open([world])
        # Deep past, recent, and the whole — all whole.
        assert [%{value: 1}] = Snapshot.find(snapshot, id: 1)
        assert [%{value: 300}] = Snapshot.find(snapshot, id: 300)
        assert length(Snapshot.find(snapshot, attribute: "n")) == 300
        World.close(ctx.name)
      end

      test "a name that is any term opens", ctx do
        n = System.unique_integer([:positive])

        for name <- [{:conform_t, n}, "conform #{n}", %{conform: n}, ["conform", n]] do
          world = opened(name, ctx.dir)
          {:ok, _} = World.append(world, [{1, "x", 1}])
          assert Snapshot.value(Snapshot.open([world]), 1, "x") == 1
          World.close(name)
        end
      end

      if conf[:durable?] do
        test "facts and the tx counter survive a reopen", ctx do
          world = opened(ctx.name, ctx.dir)
          {:ok, _} = World.append(world, [{42, "height", 180}])
          {:ok, two} = World.append(world, [{42, "height", 181}])

          world = reopened(ctx.name, ctx.dir)
          assert World.tx(world) == two
          assert Snapshot.value(Snapshot.open([world]), 42, "height") == 181

          # And the counter resumes rather than restarting.
          {:ok, three} = World.append(world, [{43, "height", 170}])
          assert three == two + 1
          World.close(ctx.name)
        end

        test "within-tx order survives a reopen too", ctx do
          # The other half of the landmine: position must be durable, not an
          # accident of what was resident.
          world = opened(ctx.name, ctx.dir)
          {:ok, _} = World.append(world, [{42, "height", 180}, {42, "height", 181}])

          world = reopened(ctx.name, ctx.dir)
          assert Snapshot.value(Snapshot.open([world]), 42, "height") == 181
          World.close(ctx.name)
        end

        test "a bounded reopen still answers its whole history", ctx do
          world = opened(ctx.name, ctx.dir, resident: 5)
          {:ok, _} = World.append(world, Attribute.seed())
          {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
          {:ok, _} = World.append(world, [{"ada", "height", 180}])
          for i <- 1..20, do: {:ok, _} = World.append(world, [{"filler-#{i}", "height", i}])
          before = Snapshot.facts(Snapshot.open([world]))

          world = reopened(ctx.name, ctx.dir, resident: 5)
          assert Snapshot.value(Snapshot.open([world]), "ada", "height") == 180
          assert Snapshot.facts(Snapshot.open([world])) == before
          World.close(ctx.name)
        end

        test "erasure reaches a fact that was never resident in this life", ctx do
          world = opened(ctx.name, ctx.dir, resident: 3)
          subject = "person-#{System.unique_integer([:positive])}"
          on_exit(fn -> Keyring.destroy(subject) end)

          {:ok, _} = World.append(world, Attribute.seed())
          {:ok, _} = World.append(world, Erasure.seed())
          {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
          {:ok, _} = World.append(world, [{42, "subject", subject}])
          {:ok, _} = World.append(world, [{42, "height", 180}])
          for i <- 1..10, do: {:ok, _} = World.append(world, [{"filler-#{i}", "height", i}])

          # Reopen: the subject fact is deep in the past, and the subjects map
          # must find it anyway — C4's rule, asked of every store.
          world = reopened(ctx.name, ctx.dir, resident: 3)
          {:ok, tx} = World.append(world, [{42, "height", 999}])

          sealed =
            world
            |> World.raw_at(tx)
            |> Enum.filter(&(&1.id == 42 and &1.attribute == "height"))
            |> Enum.all?(&match?({:sealed, _, _, _, _, _, :bound}, &1.value))

          assert sealed, "a reopen forgot who the entity belongs to"

          :ok = Erasure.erase(subject)
          assert Snapshot.value(Snapshot.open([world]), 42, "height") == :erased
          World.close(ctx.name)
        end
      end
    end
  end
end

defmodule Blazie.StoreConformance.MemoryTest do
  use Blazie.StoreConformance, store_module: nil, durable?: false
end

defmodule Blazie.StoreConformance.FileTest do
  use Blazie.StoreConformance, store_module: Blazie.Store.File, durable?: true
end

defmodule Blazie.StoreConformance.PagedTest do
  use Blazie.StoreConformance, store_module: Blazie.Store.Paged, durable?: true
end

defmodule Blazie.StoreConformance.SQLiteTest do
  use Blazie.StoreConformance, store_module: Blazie.Store.SQLite, durable?: true
end

defmodule Blazie.StoreConformance.SQLiteResidentNoneTest do
  # The far end of the residency knob: the world holds NO tail, the store
  # owns every read. Same questions, same answers — which is the whole claim.
  use Blazie.StoreConformance,
    store_module: Blazie.Store.SQLite,
    durable?: true,
    world_opts: [resident: :none]
end
