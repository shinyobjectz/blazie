defmodule Blazie.SubscriptionTest do
  @moduledoc """
  A subscription is a question the evaluator keeps answering.

  The mechanism was already there — a read set, and whether a later fact falls
  inside it. This is the part that holds one and pushes.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Formula, World, Snapshot, Subscription, TestLedger}

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    {:ok, _} = World.append(world, Attribute.define("colour"))
    %{world: world}
  end

  describe "a question keeps being answered" do
    test "a matching write pushes a new answer", %{world: world} do
      {:ok, ref} = Subscription.watch([world], attribute: "height")

      {:ok, _} = World.append(world, [{42, "height", 180}])

      assert_receive {:blazie, ^ref, answer}
      assert [%{attribute: "height", value: 180}] = answer.facts
    end

    test "the answer carries the name it was answered at", %{world: world} do
      {:ok, ref} = Subscription.watch([world], attribute: "height")
      {:ok, tx} = World.append(world, [{42, "height", 180}])

      assert_receive {:blazie, ^ref, answer}

      # Keyed by what the world is called, not by where it is. That is what
      # makes a name something JSON can carry and something a caller can send
      # straight back — and it is why nothing between here and the socket has
      # to translate it any more.
      assert answer.name == %{World.name_of(world) => tx}

      # And that name still answers the same forever.
      assert Snapshot.reopen(answer.name) |> Snapshot.find(attribute: "height") == answer.facts
    end

    test "each matching write pushes again", %{world: world} do
      {:ok, ref} = Subscription.watch([world], attribute: "height")

      {:ok, _} = World.append(world, [{42, "height", 180}])
      assert_receive {:blazie, ^ref, first}

      {:ok, _} = World.append(world, [{43, "height", 190}])
      assert_receive {:blazie, ^ref, second}

      assert length(first.facts) == 1
      assert length(second.facts) == 2
    end
  end

  describe "a write outside the read set pushes nothing" do
    test "an unrelated attribute is silent", %{world: world} do
      {:ok, ref} = Subscription.watch([world], attribute: "height")

      {:ok, _} = World.append(world, [{42, "colour", "blue"}])

      refute_receive {:blazie, ^ref, _}, 50
    end

    test "another world is silent", %{world: watched} do
      other = TestLedger.open()
      {:ok, _} = World.append(other, Attribute.seed())

      {:ok, ref} = Subscription.watch([watched], attribute: "height")
      {:ok, _} = World.append(other, [{42, "height", 180}])

      refute_receive {:blazie, ^ref, _}, 50
    end
  end

  describe "composing ledgers" do
    test "a write to any watched world pushes", %{world: a} do
      b = TestLedger.open()
      {:ok, _} = World.append(b, Attribute.seed())
      {:ok, _} = World.append(b, Attribute.define("height", answers: "integer"))

      {:ok, ref} = Subscription.watch([a, b], attribute: "height")

      {:ok, _} = World.append(a, [{1, "height", 1}])
      assert_receive {:blazie, ^ref, first}
      assert length(first.facts) == 1

      {:ok, _} = World.append(b, [{2, "height", 2}])
      assert_receive {:blazie, ^ref, second}
      assert length(second.facts) == 2
    end
  end

  describe "a formula is watched by what it read" do
    test "it re-answers when its read set is touched", %{world: world} do
      doubled =
        Formula.new("doubled", fn snapshot ->
          for fact <- Snapshot.find(snapshot, attribute: "height") do
            {fact.id, "doubled", fact.value * 2}
          end
        end)

      {:ok, ref} = Subscription.watch([world], doubled)

      {:ok, _} = World.append(world, [{42, "height", 180}])
      assert_receive {:blazie, ^ref, answer}
      assert [{42, "doubled", 360, "doubled"}] = answer.facts
    end

    test "and stays quiet when it is not", %{world: world} do
      doubled =
        Formula.new("doubled", fn snapshot ->
          for fact <- Snapshot.find(snapshot, attribute: "height") do
            {fact.id, "doubled", fact.value * 2}
          end
        end)

      {:ok, ref} = Subscription.watch([world], doubled)
      {:ok, _} = World.append(world, [{42, "colour", "blue"}])

      refute_receive {:blazie, ^ref, _}, 50
    end
  end

  describe "a world that goes away" do
    test "takes its subscriptions quietly, without crashing" do
      name = {:closing, System.unique_integer([:positive])}
      {:ok, world} = World.open(name)
      {:ok, _} = World.append(world, Attribute.seed())
      {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))

      {:ok, _ref} = Subscription.watch([world], attribute: "height")
      before = Subscription.count()

      :ok = World.close(name)

      # No crash report, and the subscription is gone rather than waiting to
      # fail on the next announcement.
      Enum.reduce_while(1..100, nil, fn _, _ ->
        if Subscription.count() < before, do: {:halt, :ok}, else: {:cont, Process.sleep(10)}
      end)

      assert Subscription.count() < before
    end
  end

  describe "letting go" do
    test "unwatching stops the pushes", %{world: world} do
      {:ok, ref} = Subscription.watch([world], attribute: "height")
      :ok = Subscription.unwatch(ref)

      {:ok, _} = World.append(world, [{42, "height", 180}])

      refute_receive {:blazie, ^ref, _}, 50
    end

    test "a subscription dies with whoever asked for it", %{world: world} do
      test_process = self()

      watcher =
        spawn(fn ->
          {:ok, ref} = Subscription.watch([world], attribute: "height")
          send(test_process, {:watching, ref})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:watching, _ref}
      assert Subscription.count() >= 1

      send(watcher, :stop)
      ref_monitor = Process.monitor(watcher)
      assert_receive {:DOWN, ^ref_monitor, :process, _, _}

      # The subscription goes with it rather than pushing into the void.
      Process.sleep(30)
      {:ok, _} = World.append(world, [{42, "height", 180}])
      refute_receive {:blazie, _, _}, 50
    end
  end
end
