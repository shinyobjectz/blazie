defmodule LazyRiver.LedgerTest do
  @moduledoc """
  Opening and closing ledgers at runtime, which is what a tenant arriving looks
  like.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Ledger, Snapshot, TestLedger}

  describe "a ledger is opened at runtime" do
    test "a name can be any term, not just an atom" do
      # The point of the registry: a tenant name comes from a request, and
      # atoms are never collected.
      for name <- [{:tenant, 1}, "a string name", ["a", "list"], %{tenant: 1}] do
        assert {:ok, ledger} = Ledger.open(name)
        assert {:ok, _tx} = Ledger.append(ledger, [{1, :x, 1}])
        assert :ok = Ledger.close(name)
      end
    end

    test "opening the same name twice hands back the same ledger" do
      name = {:test, System.unique_integer([:positive])}
      {:ok, first} = Ledger.open(name)
      {:ok, _} = Ledger.append(first, [{1, :x, 1}])

      {:ok, again} = Ledger.open(name)
      assert Ledger.tx(again) == 1

      Ledger.close(name)
    end

    test "an open ledger is listed" do
      name = {:test, System.unique_integer([:positive])}
      {:ok, _} = Ledger.open(name)

      assert name in Ledger.open_ledgers()

      Ledger.close(name)
      refute name in Ledger.open_ledgers()
    end

    test "closing something that was never open says so" do
      assert {:error, :not_found} = Ledger.close({:never, :opened})
    end
  end

  describe "what in-memory storage costs, stated rather than implied" do
    test "a closed ledger forgets everything" do
      name = {:test, System.unique_integer([:positive])}
      {:ok, ledger} = Ledger.open(name)
      {:ok, _} = Ledger.append(ledger, [{42, :height, 180}])

      Ledger.close(name)
      {:ok, reopened} = Ledger.open(name)

      # Persistence goes behind this seam. Until it does, closing is erasure by
      # accident — which doctrine 16 says should only ever happen on purpose.
      assert Ledger.tx(reopened) == 0
      assert Snapshot.answer(Snapshot.open([reopened]), 42, :height) == nil

      Ledger.close(name)
    end
  end

  describe "ledgers are independent" do
    test "one crashing does not take another with it" do
      a = TestLedger.open()
      b = TestLedger.open()
      {:ok, _} = Ledger.append(a, [{1, :x, 1}])
      {:ok, _} = Ledger.append(b, [{2, :y, 2}])

      pid = GenServer.whereis(a)
      Process.exit(pid, :kill)

      # b is untouched, which is what "readable, forkable and deletable on its
      # own" has to mean under a supervisor.
      assert Ledger.tx(b) == 1
    end
  end
end
