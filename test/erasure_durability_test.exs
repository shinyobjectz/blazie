defmodule LazyRiver.ErasureDurabilityTest do
  @moduledoc """
  Erasure has to survive the things that happen to running systems: a
  redeployment, and a restore of the key store from a backup.

  A tombstone is what makes the second one self-healing. Erasing writes a fact,
  and the keyring reconciles against those facts every time it opens — so a key
  store rolled back to before an erasure is corrected on the next boot rather
  than quietly resurrecting somebody.
  """
  use ExUnit.Case, async: false

  alias LazyRiver.{Attribute, Erasure, Keyring, Ledger, Snapshot, TestLedger}

  setup do
    subject = "person-#{System.unique_integer([:positive])}"
    on_exit(fn -> Keyring.destroy(subject) end)

    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed() ++ Erasure.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
    {:ok, _} = Ledger.append(ledger, [{42, "subject", subject}])
    {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

    %{ledger: ledger, subject: subject}
  end

  describe "erasure leaves a tombstone" do
    test "erasing records that it happened", ctx do
      refute Erasure.erased?(ctx.subject)

      :ok = Erasure.erase(ctx.subject)

      assert Erasure.erased?(ctx.subject)
      assert ctx.subject in Erasure.erased()
    end

    test "the tombstone is a fact like any other", ctx do
      :ok = Erasure.erase(ctx.subject)

      {:ok, tombstones} = Ledger.open(Erasure.ledger())
      found = Snapshot.find(Snapshot.open([tombstones]), id: ctx.subject)

      assert [%{attribute: "erased_at"}] = found
    end

    test "erasing twice is still one erasure", ctx do
      :ok = Erasure.erase(ctx.subject)
      :ok = Erasure.erase(ctx.subject)

      assert Erasure.erased() |> Enum.count(&(&1 == ctx.subject)) == 1
    end
  end

  describe "a restored key store does not resurrect anybody" do
    test "reconciling on open re-destroys what was erased", ctx do
      :ok = Erasure.erase(ctx.subject)
      assert Snapshot.value(Snapshot.open([ctx.ledger]), 42, "height") == :erased

      # Stand in for a backup restore: the key is back, as it would be if the
      # key store were rolled back to before the erasure.
      {:ok, _} = Keyring.wrap(:crypto.strong_rand_bytes(32), ctx.subject)

      # The next boot reconciles against the tombstones.
      :ok = Keyring.reconcile()

      assert Keyring.unwrap(<<0::96, 0::128, 0>>, ctx.subject) == :forgotten
      assert Snapshot.value(Snapshot.open([ctx.ledger]), 42, "height") == :erased
    end

    test "a subject nobody erased is untouched by reconciling", ctx do
      :ok = Keyring.reconcile()

      assert Snapshot.value(Snapshot.open([ctx.ledger]), 42, "height") == 180
    end

    test "reconciling is idempotent", ctx do
      :ok = Erasure.erase(ctx.subject)

      assert :ok = Keyring.reconcile()
      assert :ok = Keyring.reconcile()
      assert Snapshot.value(Snapshot.open([ctx.ledger]), 42, "height") == :erased
    end
  end

  describe "erasure survives a restart" do
    test "a restarted keyring reconciles rather than forgetting", ctx do
      :ok = Erasure.erase(ctx.subject)

      :ok = Keyring.restart()

      # Erased before, erased after — and for the right reason: the tombstone
      # said so, not because a restart loses everything.
      assert Snapshot.value(Snapshot.open([ctx.ledger]), 42, "height") == :erased
      assert Erasure.erased?(ctx.subject)
    end

    test "and an unerased subject still reads after a restart", ctx do
      :ok = Keyring.restart()

      assert Snapshot.value(Snapshot.open([ctx.ledger]), 42, "height") == 180
    end
  end
end
