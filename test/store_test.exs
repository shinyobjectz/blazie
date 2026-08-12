defmodule LazyRiver.StoreTest do
  @moduledoc """
  Persistence behind the ledger seam, and what each store honestly gives you.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Ledger, Snapshot, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "lazyriver_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: {:tenant, System.unique_integer([:positive])}}
  end

  defp on_disk(name, dir, opts \\ []) do
    {:ok, ledger} = Ledger.open(name, store: {Store.File, [dir: dir] ++ opts})
    ledger
  end

  describe "a ledger survives a restart" do
    test "facts are still there after closing and reopening", ctx do
      ledger = on_disk(ctx.name, ctx.dir)
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      {:ok, _} = Ledger.append(ledger, [{42, "height", 181}])
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir)
      snapshot = Snapshot.open([reopened])

      assert Snapshot.answer(snapshot, 42, "height") == 181
      assert length(Snapshot.find(snapshot, id: 42, attribute: "height")) == 2

      Ledger.close(ctx.name)
    end

    test "the transaction counter resumes rather than restarting", ctx do
      ledger = on_disk(ctx.name, ctx.dir)
      {:ok, _} = Ledger.append(ledger, [{1, "x", 1}])
      {:ok, two} = Ledger.append(ledger, [{2, "x", 2}])
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir)

      assert Ledger.tx(reopened) == two
      assert {:ok, three} = Ledger.append(reopened, [{3, "x", 3}])
      assert three == two + 1

      Ledger.close(ctx.name)
    end

    test "a name that is any term still gets a file", ctx do
      for name <- [{:tenant, 1}, "a string", %{tenant: 1}, ["nested", ["list"]]] do
        ledger = on_disk(name, ctx.dir)
        {:ok, _} = Ledger.append(ledger, [{1, "x", 1}])
        :ok = Ledger.close(name)

        assert File.exists?(Path.join(ctx.dir, Store.File.filename(name)))
      end
    end

    test "reopening a name nothing was ever written under is empty", ctx do
      ledger = on_disk(ctx.name, ctx.dir)

      assert Ledger.tx(ledger) == 0
      assert Snapshot.facts(Snapshot.open([ledger])) == []

      Ledger.close(ctx.name)
    end
  end

  describe "a torn tail loses only the transaction that never finished" do
    test "everything before the tear survives", ctx do
      ledger = on_disk(ctx.name, ctx.dir)
      {:ok, _} = Ledger.append(ledger, [{1, "x", 1}])
      {:ok, _} = Ledger.append(ledger, [{2, "x", 2}])
      :ok = Ledger.close(ctx.name)

      # A process killed mid-write leaves a record that claims more bytes than
      # it wrote.
      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      File.write!(path, <<999_999::32, 0::32, "half a record">>, [:append])

      reopened = on_disk(ctx.name, ctx.dir)

      assert Ledger.tx(reopened) == 2
      assert length(Snapshot.facts(Snapshot.open([reopened]))) == 2

      Ledger.close(ctx.name)
    end

    test "a corrupted record stops the read rather than being trusted", ctx do
      ledger = on_disk(ctx.name, ctx.dir)
      {:ok, _} = Ledger.append(ledger, [{1, "x", 1}])
      :ok = Ledger.close(ctx.name)

      # Right length, wrong checksum.
      payload = :erlang.term_to_binary([:garbage])
      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      File.write!(path, <<byte_size(payload)::32, 0::32, payload::binary>>, [:append])

      reopened = on_disk(ctx.name, ctx.dir)

      assert length(Snapshot.facts(Snapshot.open([reopened]))) == 1

      Ledger.close(ctx.name)
    end
  end

  describe "what each store gives you, stated rather than implied" do
    test "memory forgets on close, and that is the whole difference", ctx do
      {:ok, ledger} = Ledger.open(ctx.name)
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      :ok = Ledger.close(ctx.name)

      {:ok, reopened} = Ledger.open(ctx.name)
      assert Ledger.tx(reopened) == 0

      Ledger.close(ctx.name)
    end

    test "fsync is opt-in, and opting in still works", ctx do
      ledger = on_disk(ctx.name, ctx.dir, sync: true)
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir, sync: true)
      assert Snapshot.answer(Snapshot.open([reopened]), 42, "height") == 180

      Ledger.close(ctx.name)
    end
  end
end
