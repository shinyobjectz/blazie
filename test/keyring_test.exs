defmodule LazyRiver.KeyringTest do
  @moduledoc """
  Envelope encryption: a key per fact, wrapped by a key per subject.

  The point of the second tier is where the wrapped key can live. It is noise
  without the KEK, so it goes in the ledger with everything else — which means
  nothing durable is held in memory, and the defect this replaces (a restart
  erasing every subject by accident) cannot happen.

  What still has to live somewhere deletion is real is one KEK per subject, and
  that is the whole of what a keyring is now.
  """
  use ExUnit.Case, async: false

  alias LazyRiver.{Attribute, Erasure, Keyring, Ledger, Snapshot, TestLedger}

  setup do
    dir = Path.join(System.tmp_dir!(), "lazyriver_keys_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    subject = "person-#{System.unique_integer([:positive])}"
    %{dir: dir, subject: subject}
  end

  describe "a key wraps a key" do
    test "a wrapped key is not the key", ctx do
      {:ok, ring} = Keyring.Local.open(dir: ctx.dir)
      dek = :crypto.strong_rand_bytes(32)

      {:ok, wrapped} = Keyring.Local.wrap(ring, dek, ctx.subject)

      refute wrapped == dek
      assert :binary.match(wrapped, dek) == :nomatch
    end

    test "unwrapping gives it back", ctx do
      {:ok, ring} = Keyring.Local.open(dir: ctx.dir)
      dek = :crypto.strong_rand_bytes(32)

      {:ok, wrapped} = Keyring.Local.wrap(ring, dek, ctx.subject)

      assert {:ok, ^dek} = Keyring.Local.unwrap(ring, wrapped, ctx.subject)
    end

    test "another subject's key does not open it", ctx do
      {:ok, ring} = Keyring.Local.open(dir: ctx.dir)
      dek = :crypto.strong_rand_bytes(32)
      {:ok, wrapped} = Keyring.Local.wrap(ring, dek, ctx.subject)

      assert Keyring.Local.unwrap(ring, wrapped, "somebody-else") == :forgotten
    end

    test "destroying makes it unopenable", ctx do
      {:ok, ring} = Keyring.Local.open(dir: ctx.dir)
      dek = :crypto.strong_rand_bytes(32)
      {:ok, wrapped} = Keyring.Local.wrap(ring, dek, ctx.subject)

      :ok = Keyring.Local.destroy(ring, ctx.subject)

      assert Keyring.Local.unwrap(ring, wrapped, ctx.subject) == :forgotten
    end
  end

  describe "the keys outlive the process" do
    test "a reopened keyring still unwraps", ctx do
      {:ok, ring} = Keyring.Local.open(dir: ctx.dir)
      dek = :crypto.strong_rand_bytes(32)
      {:ok, wrapped} = Keyring.Local.wrap(ring, dek, ctx.subject)

      {:ok, reopened} = Keyring.Local.open(dir: ctx.dir)

      assert {:ok, ^dek} = Keyring.Local.unwrap(reopened, wrapped, ctx.subject)
    end

    test "a destroyed key stays destroyed across a reopen", ctx do
      {:ok, ring} = Keyring.Local.open(dir: ctx.dir)
      dek = :crypto.strong_rand_bytes(32)
      {:ok, wrapped} = Keyring.Local.wrap(ring, dek, ctx.subject)
      :ok = Keyring.Local.destroy(ring, ctx.subject)

      {:ok, reopened} = Keyring.Local.open(dir: ctx.dir)

      assert Keyring.Local.unwrap(reopened, wrapped, ctx.subject) == :forgotten
    end
  end

  describe "the defect this replaces" do
    test "facts survive a keyring restart", ctx do
      ledger = TestLedger.open()
      {:ok, _} = Ledger.append(ledger, Attribute.seed() ++ Erasure.seed())
      {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
      {:ok, _} = Ledger.append(ledger, [{42, "subject", ctx.subject}])
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

      assert Snapshot.value(Snapshot.open([ledger]), 42, "height") == 180

      # The old keyring held the only copy of every key in memory. Restarting
      # it used to erase everyone by accident.
      :ok = Keyring.restart()

      assert Snapshot.value(Snapshot.open([ledger]), 42, "height") == 180

      Keyring.destroy(ctx.subject)
    end

    test "and erasure still works afterwards", ctx do
      ledger = TestLedger.open()
      {:ok, _} = Ledger.append(ledger, Attribute.seed() ++ Erasure.seed())
      {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
      {:ok, _} = Ledger.append(ledger, [{42, "subject", ctx.subject}])
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

      :ok = Keyring.restart()
      :ok = Erasure.erase(ctx.subject)

      assert Snapshot.value(Snapshot.open([ledger]), 42, "height") == :erased
    end
  end

  describe "the wrapped key rides in the fact" do
    test "the ledger holds it, so nothing durable is in memory", ctx do
      ledger = TestLedger.open()
      {:ok, _} = Ledger.append(ledger, Attribute.seed() ++ Erasure.seed())
      {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
      {:ok, _} = Ledger.append(ledger, [{42, "subject", ctx.subject}])
      {:ok, tx} = Ledger.append(ledger, [{42, "height", 180}])

      # Read the raw row rather than the revealed one.
      raw = Ledger.raw_at(ledger, tx) |> Enum.find(&(&1.attribute == "height"))

      assert {:sealed, subject, wrapped, _iv, _tag, _cipher} = raw.value
      assert subject == ctx.subject
      assert byte_size(wrapped) > 0

      Keyring.destroy(ctx.subject)
    end
  end
end
