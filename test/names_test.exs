defmodule Blazie.NamesTest do
  @moduledoc """
  A name is what a thing is called. An address is where it currently is.

  Those were both called "name" and they were different values — `World.open/2`
  took a term, `Snapshot.name/1` handed back a map keyed by process addresses.
  Not interchangeable, one noun, which is the divergence the vocabulary exists
  to catch and the one montology refuses to grant an exception for.

  It was not academic. A snapshot named by addresses is not something JSON can
  carry, not something a caller can send back, and not the same map after a
  restart — so every layer that handed one outward translated it first, and
  `watch` crashed on **every real push** because the channel had no translation
  and the test that covered it compared terms without ever serialising one.

  A second translation lived in the controller and zipped a map's values against
  the caller's list, trusting the two to line up. A map does not promise the
  order anybody put things in. That one had not been caught at all.

  Both translations are gone, because there is nothing left to translate.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, World, Snapshot, TestLedger}

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    %{world: world}
  end

  describe "an address and a name are different things" do
    test "and one can be recovered from the other", %{world: world} do
      name = World.name_of(world)

      assert World.via(name) == world
      assert World.name_of(World.via(name)) == name
    end

    test "a bare pid has no name, and says so rather than inventing one" do
      assert_raise ArgumentError, ~r/cannot be recovered from a bare pid/, fn ->
        World.name_of(self())
      end
    end

    test "a name handed in where a name belongs is left alone" do
      assert World.name_of({:tenant, 7}) == {:tenant, 7}
      assert World.name_of("$vitals") == "$vitals"
    end
  end

  describe "a snapshot's name is made of world names" do
    test "never of addresses", %{world: world} do
      name = Snapshot.name(Snapshot.open([world]))

      assert [key] = Map.keys(name)
      assert key == World.name_of(world)
      refute match?({:via, _, _}, key)
    end

    test "so it survives a round trip through reopen", %{world: world} do
      {:ok, tx} = World.append(world, [{"ada", "height", 180}])
      name = Snapshot.name(Snapshot.open([world]))

      assert Snapshot.name(Snapshot.reopen(name)) == name
      assert Snapshot.value(Snapshot.reopen(name), "ada", "height") == 180
      assert name[World.name_of(world)] == tx
    end

    test "and an address handed to reopen is normalised, not stored", %{world: world} do
      # Nothing in lib/ does this any more, but a name arrives from outside and
      # the shape a snapshot promises must not depend on who built it.
      snapshot = Snapshot.reopen(%{world => World.tx(world)})

      assert [key] = Map.keys(Snapshot.name(snapshot))
      refute match?({:via, _, _}, key)
      assert key == World.name_of(world)
    end

    test "a name over several ledgers keys each by its own name", %{world: one} do
      two = TestLedger.open()
      {:ok, _} = World.append(two, Attribute.seed())

      name = Snapshot.name(Snapshot.open([one, two]))

      assert Map.keys(name) |> Enum.sort() ==
               Enum.sort([World.name_of(one), World.name_of(two)])
    end
  end

  describe "a name with ordinary world names is something a wire can carry" do
    test "which is what the crash was about", _ctx do
      # The names a caller actually uses are strings, because they arrived as
      # JSON. A tuple name is a test's way of proving atoms never leak, and is
      # deliberately not JSON-carryable — so this asserts the real case.
      name = %{"tenant-7" => 42, "$vitals" => 9}

      assert {:ok, encoded} = Jason.encode(name)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded == name

      # And the decoded thing is a name again, with no translation in between.
      assert Snapshot.name(Snapshot.reopen(decoded)) == name
    end
  end

  describe "a read can never take the world down with it" do
    # Found by measurement, not by a test: `Fact.matches?/2` used `Map.fetch!`,
    # so a pattern naming a field a fact does not have raised inside the
    # world's own process. The world died, and with a memory store every fact
    # in it died too — a read destroying what a writer put there.
    #
    # `subject` is the example worth naming: it is a real attribute in
    # `Erasure`, and it is not a field of a fact. The mistake is one letter
    # from a legitimate query.
    test "a pattern naming something that is not a field is refused", %{world: world} do
      {:ok, _} = World.append(world, [{"ada", "height", 180}])
      tx = World.tx(world)

      assert_raise ArgumentError, ~r/is not one/, fn ->
        World.find_at(world, tx, subject: "person-x")
      end

      # Still alive, still holding everything.
      assert World.tx(world) == tx
      assert [%{value: 180}] = World.find_at(world, tx, attribute: "height")
    end

    test "and the refusal says what to write instead", %{world: world} do
      error =
        assert_raise ArgumentError, fn ->
          Snapshot.find(Snapshot.open([world]), subject: "person-x")
        end

      assert error.message =~ "id, attribute, value, tx, by"
      assert error.message =~ ~s(attribute: "subject")
    end

    test "a snapshot read is checked the same way", %{world: world} do
      snapshot = Snapshot.open([world])

      assert_raise ArgumentError, fn -> Snapshot.find(snapshot, nonsense: 1) end
      assert Snapshot.find(snapshot, attribute: "height") == []
    end

    test "every field a fact really has is accepted", %{world: world} do
      {:ok, tx} = World.append(world, [{"ada", "height", 180}])

      for pattern <- [[id: "ada"], [attribute: "height"], [value: 180], [tx: tx], [by: nil]] do
        assert is_list(World.find_at(world, tx, pattern)), "#{inspect(pattern)} was refused"
      end
    end
  end
end
