defmodule Blazie.WorldTest do
  @moduledoc """
  Opening and closing ledgers at runtime, which is what a tenant arriving looks
  like.
  """
  use ExUnit.Case, async: true

  alias Blazie.{World, Snapshot, TestLedger}

  describe "a world is opened at runtime" do
    test "a name can be any term, not just an atom" do
      # The point of the registry: a tenant name comes from a request, and
      # atoms are never collected.
      for name <- [{:tenant, 1}, "a string name", ["a", "list"], %{tenant: 1}] do
        assert {:ok, world} = World.open(name)
        assert {:ok, _tx} = World.append(world, [{1, "x", 1}])
        assert :ok = World.close(name)
      end
    end

    test "opening the same name twice hands back the same world" do
      name = {:test, System.unique_integer([:positive])}
      {:ok, first} = World.open(name)
      {:ok, _} = World.append(first, [{1, "x", 1}])

      {:ok, again} = World.open(name)
      assert World.tx(again) == 1

      World.close(name)
    end

    test "an open world is listed" do
      name = {:test, System.unique_integer([:positive])}
      {:ok, _} = World.open(name)

      assert name in World.open_worlds()

      World.close(name)
      refute name in World.open_worlds()
    end

    test "closing something that was never open says so" do
      assert {:error, :not_found} = World.close({:never, :opened})
    end
  end

  describe "what in-memory storage costs, stated rather than implied" do
    test "a closed world forgets everything" do
      name = {:test, System.unique_integer([:positive])}
      {:ok, world} = World.open(name)
      {:ok, _} = World.append(world, [{42, "height", 180}])

      World.close(name)
      {:ok, reopened} = World.open(name)

      # Persistence goes behind this seam. Until it does, closing is erasure by
      # accident — which doctrine 16 says should only ever happen on purpose.
      assert World.tx(reopened) == 0
      assert Snapshot.value(Snapshot.open([reopened]), 42, "height") == nil

      World.close(name)
    end
  end

  describe "ledgers are independent" do
    test "one crashing does not take another with it" do
      a = TestLedger.open()
      b = TestLedger.open()
      {:ok, _} = World.append(a, [{1, "x", 1}])
      {:ok, _} = World.append(b, [{2, "y", 2}])

      pid = GenServer.whereis(a)
      Process.exit(pid, :kill)

      # b is untouched, which is what "readable, forkable and deletable on its
      # own" has to mean under a supervisor.
      assert World.tx(b) == 1
    end
  end
end
