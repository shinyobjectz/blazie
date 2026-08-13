defmodule Blazie.ErasureTest do
  @moduledoc """
  Doctrine 16: everything is additive except erasure.

  Erasure destroys a key, never a segment. The bytes stay and become noise, so
  an old name still answers — it just answers that the content is gone, which
  is a bounded and explicit break rather than an arbitrary one.

  The requirement that shapes the design is that erasure must reach what was
  *computed* from the erased facts. Making the subject a property of the entity
  rather than of each fact is what makes that automatic: a derived fact about
  someone's entity is encrypted under the same key as the fact it came from,
  so one key destroys both.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Erasure, Formula, Keyring, World, Snapshot, TestLedger}

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Erasure.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    {:ok, _} = World.append(world, Attribute.define("doubled", answers: "integer"))
    subject = "person-#{System.unique_integer([:positive])}"
    on_exit(fn -> Keyring.destroy(subject) end)
    %{world: world, subject: subject}
  end

  describe "a fact belonging to a subject is readable until it is not" do
    test "it reads normally before erasure", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])

      assert Snapshot.value(Snapshot.open([ctx.world]), 42, "height") == 180
    end

    test "after erasure the answer is gone rather than wrong", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])

      :ok = Erasure.erase(ctx.subject)

      assert Snapshot.value(Snapshot.open([ctx.world]), 42, "height") == :erased
    end

    test "the fact is still there — only its content went", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])

      :ok = Erasure.erase(ctx.subject)
      snapshot = Snapshot.open([ctx.world])

      # Nothing was rewritten: the row, its transaction and its shape survive.
      assert [fact] = Snapshot.find(snapshot, id: 42, attribute: "height")
      assert fact.tx > 0
      assert fact.value == :erased
    end

    test "an old name answers erased too, which is the bounded break", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])
      early = Snapshot.open([ctx.world])

      assert Snapshot.value(early, 42, "height") == 180
      :ok = Erasure.erase(ctx.subject)
      assert Snapshot.value(early, 42, "height") == :erased
    end
  end

  describe "erasure reaches what was computed" do
    test "a derived fact about the same entity goes with it", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])

      doubling =
        Formula.new("doubling", fn snapshot ->
          for fact <- Snapshot.find(snapshot, attribute: "height"), fact.value != :erased do
            {fact.id, "doubled", fact.value * 2}
          end
        end)

      {:ok, _, _} = Formula.materialize(doubling, Snapshot.open([ctx.world]), ctx.world)
      assert Snapshot.value(Snapshot.open([ctx.world]), 42, "doubled") == 360

      :ok = Erasure.erase(ctx.subject)

      # Nobody walked a lineage. The derived fact is about 42, so it was
      # encrypted under the same key.
      assert Snapshot.value(Snapshot.open([ctx.world]), 42, "doubled") == :erased
    end
  end

  describe "what cannot be erased, said out loud" do
    test "a fact that declares no subject can never be erased", ctx do
      {:ok, _} = World.append(ctx.world, [{99, "height", 190}])

      :ok = Erasure.erase(ctx.subject)

      assert Snapshot.value(Snapshot.open([ctx.world]), 99, "height") == 190
      refute Erasure.erasable?(Snapshot.open([ctx.world]), 99)
    end

    test "a fact written before its subject was declared is not covered", ctx do
      # Subject is decided at write time or not at all.
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])

      :ok = Erasure.erase(ctx.subject)

      assert Snapshot.value(Snapshot.open([ctx.world]), 42, "height") == 180
    end

    test "declaring the subject first covers what follows", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])

      assert Erasure.erasable?(Snapshot.open([ctx.world]), 42)
      :ok = Erasure.erase(ctx.subject)
      assert Snapshot.value(Snapshot.open([ctx.world]), 42, "height") == :erased
    end
  end

  describe "one subject's erasure is not another's" do
    test "an unrelated subject is untouched", ctx do
      other = "person-#{System.unique_integer([:positive])}"
      on_exit(fn -> Keyring.destroy(other) end)

      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, _} = World.append(ctx.world, [{43, "subject", other}])
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}, {43, "height", 190}])

      :ok = Erasure.erase(ctx.subject)
      snapshot = Snapshot.open([ctx.world])

      assert Snapshot.value(snapshot, 42, "height") == :erased
      assert Snapshot.value(snapshot, 43, "height") == 190
    end
  end

  describe "the keyring holds no facts and the world holds no keys" do
    test "erasing is idempotent", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      assert :ok = Erasure.erase(ctx.subject)
      assert :ok = Erasure.erase(ctx.subject)
    end

    test "erasing changes no bytes, and yet the answer is gone", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, tx} = World.append(ctx.world, [{42, "height", 180}])

      # Exactly what is stored, sealed answers and all.
      before = :erlang.term_to_binary(World.raw_at(ctx.world, tx))
      assert Snapshot.value(Snapshot.open([ctx.world]), 42, "height") == 180

      :ok = Erasure.erase(ctx.subject)

      # This is the whole of crypto-shredding: not one byte moved.
      assert :erlang.term_to_binary(World.raw_at(ctx.world, tx)) == before
      assert Snapshot.value(Snapshot.open([ctx.world]), 42, "height") == :erased
    end

    test "the world holds a wrapped key, never a usable one", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "subject", ctx.subject}])
      {:ok, tx} = World.append(ctx.world, [{42, "height", 180}])

      raw = World.raw_at(ctx.world, tx) |> Enum.find(&(&1.attribute == "height"))
      {:sealed, _subject, wrapped, _iv, _tag, cipher} = raw.value

      # The wrapped data key cannot open the ciphertext it travels with — that
      # takes the subject's key, which is not here and never was.
      assert :binary.match(cipher, wrapped) == :nomatch
    end
  end
end
