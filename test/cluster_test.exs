defmodule Blazie.ClusterTest do
  @moduledoc """
  One ledger, one owner.

  Full distribution is not here and is deliberately not here — a substrate on
  one node is the right shape for now. What is here is the failure that would
  make adding nodes catastrophic rather than merely incomplete: two nodes both
  opening the same ledger, each appending, each certain it has the history.
  That forks a ledger silently, and "an answer at a name never changes" is the
  guarantee everything else rests on.

  So opening claims the name across the cluster, and a claim someone else holds
  is refused with its repair.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Cluster, Ledger}

  setup do
    %{name: "cluster-ledger-#{System.unique_integer([:positive])}"}
  end

  describe "opening claims the ledger" do
    test "the owner is this node", ctx do
      {:ok, _} = Ledger.open(ctx.name)

      assert Cluster.owner(ctx.name) == node()
      assert Cluster.owned_here?(ctx.name)

      Ledger.close(ctx.name)
    end

    test "an unopened ledger has no owner", ctx do
      assert Cluster.owner(ctx.name) == nil
      refute Cluster.owned_here?(ctx.name)
    end

    test "closing releases the claim", ctx do
      {:ok, _} = Ledger.open(ctx.name)
      :ok = Ledger.close(ctx.name)

      assert Cluster.owner(ctx.name) == nil
    end

    test "reopening on the owning node is fine, not a conflict", ctx do
      {:ok, first} = Ledger.open(ctx.name)
      {:ok, _} = Ledger.append(first, [{1, "x", 1}])

      assert {:ok, again} = Ledger.open(ctx.name)
      assert Ledger.tx(again) == 1

      Ledger.close(ctx.name)
    end
  end

  describe "a ledger somebody else holds is refused" do
    test "opening it does not fork the history", ctx do
      # Stand in for another node's ledger process by claiming the name.
      elsewhere = spawn(fn -> receive do: (:release -> :ok) end)
      :yes = Cluster.claim_as(ctx.name, elsewhere)

      assert {:error, refusal} = Ledger.open(ctx.name)
      assert refusal.problem == :owned_elsewhere
      assert refusal.repair =~ "one owner"

      send(elsewhere, :release)
    end

    test "and nothing was started locally", ctx do
      elsewhere = spawn(fn -> receive do: (:release -> :ok) end)
      :yes = Cluster.claim_as(ctx.name, elsewhere)

      {:error, _} = Ledger.open(ctx.name)

      refute ctx.name in Ledger.open_ledgers()

      send(elsewhere, :release)
    end

    test "when the holder goes, the name frees itself", ctx do
      elsewhere = spawn(fn -> receive do: (:release -> :ok) end)
      :yes = Cluster.claim_as(ctx.name, elsewhere)

      ref = Process.monitor(elsewhere)
      send(elsewhere, :release)
      assert_receive {:DOWN, ^ref, :process, _, _}

      # global drops a claim when its holder dies, so recovery needs no sweep.
      Enum.reduce_while(1..100, nil, fn _, _ ->
        if Cluster.owner(ctx.name) == nil, do: {:halt, :ok}, else: {:cont, Process.sleep(10)}
      end)

      assert {:ok, _} = Ledger.open(ctx.name)
      Ledger.close(ctx.name)
    end
  end

  describe "what is honestly not covered" do
    test "this is one node, and says so" do
      assert Cluster.nodes() == [node()]
      refute Cluster.distributed?()
    end
  end
end
