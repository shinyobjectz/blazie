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
      {:sealed, _subject, wrapped, _iv, _tag, cipher, :bound} = raw.value

      # The wrapped data key cannot open the ciphertext it travels with — that
      # takes the subject's key, which is not here and never was.
      assert :binary.match(cipher, wrapped) == :nomatch
    end
  end

  describe "ownership survives eviction, or erasure is theater" do
    # C4 in .research/failure-modes.md, reproduced: sealing looked ownership
    # up in the fact index, trim rebuilds the index from resident facts only,
    # so once an entity's subject fact was evicted everything written about it
    # after went down in PLAINTEXT — silent at write, silent at read, and
    # observable only after telling a regulator the data was deleted.
    defp bounded_world(resident) do
      name = {:test, System.unique_integer([:positive])}
      {:ok, world} = World.open(name, resident: resident)
      ExUnit.Callbacks.on_exit(fn -> World.close(name) end)
      world
    end

    defp sealed?(world, id, attribute) do
      world
      |> World.raw_at(World.tx(world))
      |> Enum.filter(&(&1.id == id and &1.attribute == attribute))
      |> Enum.all?(&match?({:sealed, _, _, _, _, _, :bound}, &1.value))
    end

    test "a fact written long after its subject was evicted is still sealed", ctx do
      # `resident:` generated across the range that used to decide the
      # outcome: below, at, and above the filler count.
      for resident <- [2, 3, 5, 8] do
        world = bounded_world(resident)
        {:ok, _} = World.append(world, Attribute.seed() ++ Erasure.seed())
        {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
        {:ok, _} = World.append(world, [{42, "subject", ctx.subject}])

        # Enough filler that the subject fact is long gone from residence.
        for i <- 1..(resident * 3) do
          {:ok, _} = World.append(world, [{"filler-#{i}", "height", i}])
        end

        {:ok, _} = World.append(world, [{42, "height", 999}])

        assert sealed?(world, 42, "height"),
               "with resident: #{resident}, a fact written after eviction went down in plaintext"
      end
    end

    test "and erasure then actually reaches it", ctx do
      world = bounded_world(3)
      {:ok, _} = World.append(world, Attribute.seed() ++ Erasure.seed())
      {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
      {:ok, _} = World.append(world, [{42, "subject", ctx.subject}])

      for i <- 1..9, do: {:ok, _} = World.append(world, [{"filler-#{i}", "height", i}])
      {:ok, _} = World.append(world, [{42, "height", 999}])

      :ok = Erasure.erase(ctx.subject)
      assert Snapshot.value(Snapshot.open([world]), 42, "height") == :erased
    end

    test "ownership is rebuilt from the whole replay, not the resident tail", ctx do
      # Close and reopen: the replay path builds the subjects map from
      # everything the store holds, and the `oldest`/`resident` interaction
      # differs there — which is why the ticket asks for this cycle.
      dir = Path.join(System.tmp_dir!(), "c4-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      name = {:test, System.unique_integer([:positive])}
      store = {Blazie.Store.File, dir: dir}

      {:ok, world} = World.open(name, store: store, resident: 3)
      {:ok, _} = World.append(world, Attribute.seed() ++ Erasure.seed())
      {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
      {:ok, _} = World.append(world, [{42, "subject", ctx.subject}])
      for i <- 1..9, do: {:ok, _} = World.append(world, [{"filler-#{i}", "height", i}])

      :ok = World.close(name)
      {:ok, world} = World.open(name, store: store, resident: 3)
      on_exit(fn -> World.close(name) end)

      {:ok, _} = World.append(world, [{42, "height", 999}])

      assert sealed?(world, 42, "height"),
             "after a reopen, a fact about an owned entity went down in plaintext"
    end
  end

  describe "corruption and lawful deletion are different answers" do
    # C5, reproduced with one flipped bit: AEAD tag failure was reported as a
    # completed GDPR erasure, whatever caused it. The claim: :erased if and
    # only if a tombstone exists. Both directions matter — a test that only
    # checks the erased side passes on the old code and proves nothing.
    test "a flipped bit with no tombstone is unreadable, never erased", ctx do
      bound = {"w", 42, "height", 7}

      {:sealed, s, w, iv, tag, cipher, :bound} =
        Erasure.protect("secret-value", ctx.subject, bound)

      <<first, rest::binary>> = cipher
      tampered = {:sealed, s, w, iv, tag, <<Bitwise.bxor(first, 1), rest::binary>>, :bound}

      assert Erasure.reveal(tampered, bound) == :unreadable
      refute Erasure.reveal(tampered, bound) == :erased
    end

    test "a destroyed key with a tombstone is erased", ctx do
      bound = {"w", 42, "height", 7}
      sealed = Erasure.protect("secret-value", ctx.subject, bound)

      :ok = Erasure.erase(ctx.subject)

      assert Erasure.reveal(sealed, bound) == :erased
    end

    test "a key that is gone with no tombstone is loss, not deletion", ctx do
      bound = {"w", 42, "height", 7}
      sealed = Erasure.protect("secret-value", ctx.subject, bound)

      # The key vanishes without anybody recording an erasure — a restore
      # under the wrong master, an eviction bug, a lost key store.
      :ok = Keyring.destroy(ctx.subject)

      assert Erasure.reveal(sealed, bound) == :unreadable
    end
  end

  describe "a sealed answer is worthless anywhere but on its own fact" do
    # C6, reproduced: empty AAD meant any sealed answer of a subject was a
    # valid sealed answer for any other fact of that subject — a writer who
    # could reach the bytes could put alice's salary on any fact about alice.
    test "every splice between two facts fails, in both directions", ctx do
      bounds = for tx <- 1..3, do: {"w", 42, "field-#{tx}", tx}
      sealed = Enum.map(bounds, &Erasure.protect("answer-at-#{elem(&1, 3)}", ctx.subject, &1))

      for {blob, i} <- Enum.with_index(sealed),
          {bound, j} <- Enum.with_index(bounds),
          i != j do
        assert Erasure.reveal(blob, bound) == :unreadable,
               "fact #{i}'s sealed answer opened on fact #{j}"
      end

      # And each still opens where it belongs.
      for {blob, bound} <- Enum.zip(sealed, bounds) do
        assert Erasure.reveal(blob, bound) =~ "answer-at-"
      end
    end

    test "a different world is a different place", ctx do
      bound = {"w", 42, "height", 7}
      sealed = Erasure.protect("secret", ctx.subject, bound)

      assert Erasure.reveal(sealed, {"other-world", 42, "height", 7}) == :unreadable
    end
  end
end
