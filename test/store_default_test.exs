defmodule Blazie.StoreDefaultTest do
  @moduledoc """
  Where a world keeps its facts when nobody said.

  This exists because of a bug a deployment found and no unit test could have:
  `ledger_dir` was configured, documented, and never read, so every world in
  production was in memory and every restart lost everything — including the
  grants that say who may name what.
  """
  use ExUnit.Case, async: false

  alias Blazie.{World, Store}

  setup do
    was = Application.get_env(:blazie, :ledger_dir)
    on_exit(fn -> Application.put_env(:blazie, :ledger_dir, was) end)
    :ok
  end

  test "no ledger_dir means memory, which is right for a test and nothing else" do
    Application.delete_env(:blazie, :ledger_dir)

    assert {Store.Memory, []} = World.default_store()
  end

  test "a configured ledger_dir means the facts go to disk — as SQLite, since P5" do
    Application.put_env(:blazie, :ledger_dir, "/data/ledgers")

    assert {Store.SQLite, opts} = World.default_store()
    assert opts[:dir] == "/data/ledgers"
  end

  test "durability settings come with it, and checkpoints do not" do
    Application.put_env(:blazie, :ledger_dir, "/data/ledgers")
    Application.put_env(:blazie, :ledger_sync, true)
    on_exit(fn -> Application.delete_env(:blazie, :ledger_sync) end)

    {Store.SQLite, opts} = World.default_store()

    assert opts[:sync] == true
    # Deliberately absent: a checkpoint was the file store's cure for
    # replaying everything at open, and SQLite opens by reading nothing.
    refute Keyword.has_key?(opts, :checkpoint_every)
  end

  test "a world opened with no store follows the configuration" do
    dir = Path.join(System.tmp_dir!(), "lr_default_#{System.unique_integer([:positive])}")
    Application.put_env(:blazie, :ledger_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    name = "defaulted-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    {:ok, _} = World.append(world, [{1, "x", 1}])
    :ok = World.close(name)

    # The whole point: reopening finds it, because nobody had to remember to
    # ask for persistence. And since P5, what it wrote is a SQLite file.
    assert File.exists?(Path.join(dir, Store.SQLite.filename(name)))
    {:ok, reopened} = World.open(name)
    assert World.tx(reopened) == 1
    World.close(name)
  end

  test "exists? answers for either layout" do
    dir = Path.join(System.tmp_dir!(), "lr_default_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:blazie, :ledger_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # A pre-flip world is a `.ledger` on disk that nobody has opened since;
    # a post-flip world is a `.sqlite`. Both are worlds that exist, and the
    # door (`exists?/1`) must not tell a caller a taken name is free just
    # because the engine under it changed.
    File.write!(Path.join(dir, Store.File.filename("legacy-world")), "")
    File.write!(Path.join(dir, Store.SQLite.filename("current-world")), "")

    assert World.exists?("legacy-world")
    assert World.exists?("current-world")
    refute World.exists?("never-written")
  end

  # The old-shape fixture writers, borrowed from store_migrate_test — bytes
  # a previous version wrote, never constructed with today's struct.
  defp older_fact(id, attribute, value, tx) do
    %{__struct__: Blazie.Fact, id: id, attribute: attribute, answer: value, tx: tx, by: nil}
  end

  defp record(facts) do
    payload = :erlang.term_to_binary(facts)
    <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  describe "the boot-time migration" do
    test "an unopened .ledger migrates the first time its world opens by default" do
      dir = Path.join(System.tmp_dir!(), "lr_default_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:blazie, :ledger_dir, dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      name = "pre-flip-#{System.unique_integer([:positive])}"

      # A world written before the flip: an old-shape ledger, no sqlite.
      bytes =
        [
          [older_fact(42, "height", 180, 1)],
          [older_fact(42, "height", 181, 2), older_fact(43, "height", 170, 2)]
        ]
        |> Enum.map(&record/1)
        |> IO.iodata_to_binary()

      File.write!(Path.join(dir, Store.File.filename(name)), bytes)

      # Opening with NO store option crosses the one-way door.
      {:ok, world} = World.open(name)
      on_exit(fn -> World.close(name) end)

      assert World.tx(world) == 2
      assert Blazie.Snapshot.value(Blazie.Snapshot.open([world]), 42, "height") == 181

      # The sqlite file exists now; the ledger stays, the read-only record.
      assert File.exists?(Path.join(dir, Store.SQLite.filename(name)))
      assert File.exists?(Path.join(dir, Store.File.filename(name)))

      # And the counter resumes rather than restarting.
      assert {:ok, 3} = World.append(world, [{44, "height", 160}])
    end

    test "a world that already migrated opens its sqlite and never migrates again" do
      dir = Path.join(System.tmp_dir!(), "lr_default_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:blazie, :ledger_dir, dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      name = "migrated-#{System.unique_integer([:positive])}"
      File.write!(Path.join(dir, Store.File.filename(name)), record([older_fact(1, "n", 1, 1)]))

      {:ok, _} = World.open(name)
      :ok = World.close(name)

      # Reopen: the sqlite file is present, so the door does not open twice —
      # a double migration would write the world twice.
      {:ok, world} = World.open(name)
      on_exit(fn -> World.close(name) end)
      assert World.tx(world) == 1
      assert length(Blazie.Snapshot.facts(Blazie.Snapshot.open([world]))) == 1
    end
  end
end
