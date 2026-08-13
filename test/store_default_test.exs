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

  test "a configured ledger_dir means the facts go to disk" do
    Application.put_env(:blazie, :ledger_dir, "/data/ledgers")

    assert {Store.File, opts} = World.default_store()
    assert opts[:dir] == "/data/ledgers"
  end

  test "durability settings come with it" do
    Application.put_env(:blazie, :ledger_dir, "/data/ledgers")
    Application.put_env(:blazie, :ledger_sync, true)
    on_exit(fn -> Application.delete_env(:blazie, :ledger_sync) end)

    {Store.File, opts} = World.default_store()

    assert opts[:sync] == true
    assert is_integer(opts[:checkpoint_every])
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
    # ask for persistence.
    {:ok, reopened} = World.open(name)
    assert World.tx(reopened) == 1
    World.close(name)
  end
end
