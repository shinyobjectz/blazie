defmodule Blazie.Formula.EngineTest do
  @moduledoc """
  The engine decides whether to keep an answer. Nobody declares it.

  The property that makes this easy: an answer at a named snapshot never
  changes, so a cache keyed by the name AND the body can only go stale one
  way — erasure, the single event that changes what an old name answers.
  The cache watches the erasure epoch and drops everything when it moves;
  everything else is eviction, which is a size problem.
  """
  # Serial: the caching assertions count computations, and any concurrent
  # test that erases moves the global epoch and flushes every engine.
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Erasure, Formula, Keyring, World, Snapshot, TestLedger}
  alias Blazie.Formula.Engine

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    {:ok, _} = World.append(world, Attribute.define("colour"))
    %{world: world}
  end

  defp counting_formula(agent) do
    Formula.new("doubled", fn snapshot ->
      Agent.update(agent, &(&1 + 1))

      for fact <- Snapshot.find(snapshot, attribute: "height") do
        {fact.id, "doubled", fact.value * 2}
      end
    end)
  end

  defp start_engine(world, formulas, opts \\ []) do
    start_supervised!(
      {Engine,
       [world: world, formulas: formulas, name: :"engine_#{System.unique_integer([:positive])}"] ++
         opts}
    )
  end

  describe "a formula is registered, then asked by name" do
    test "an unregistered formula is refused, with how to fix it", %{world: world} do
      engine = start_engine(world, [])

      assert {:error, refusal} =
               Engine.answer(engine, "nobody_declared_this", Snapshot.open([world]))

      assert refusal.problem == :unregistered_formula
      assert refusal.repair =~ "register"
    end

    test "a registered one answers", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, [{42, "height", 180}])

      engine = start_engine(world, [counting_formula(agent)])

      assert {:ok, [{42, "doubled", 360, "doubled"}]} =
               Engine.answer(engine, "doubled", Snapshot.open([world]))
    end

    test "one can be registered while the engine runs", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      engine = start_engine(world, [])

      assert :ok = Engine.register(engine, counting_formula(agent))
      assert {:ok, _} = Engine.answer(engine, "doubled", Snapshot.open([world]))
    end
  end

  describe "the same question at the same name is computed once" do
    test "asking twice computes once", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, [{42, "height", 180}])

      engine = start_engine(world, [counting_formula(agent)])
      snapshot = Snapshot.open([world])

      {:ok, first} = Engine.answer(engine, "doubled", snapshot)
      {:ok, second} = Engine.answer(engine, "doubled", snapshot)

      assert first == second
      assert Agent.get(agent, & &1) == 1
    end

    test "a new name is a new question", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, [{42, "height", 180}])

      engine = start_engine(world, [counting_formula(agent)])

      {:ok, _} = Engine.answer(engine, "doubled", Snapshot.open([world]))
      {:ok, _} = World.append(world, [{43, "height", 190}])
      {:ok, later} = Engine.answer(engine, "doubled", Snapshot.open([world]))

      assert Agent.get(agent, & &1) == 2
      assert length(later) == 2
    end
  end

  describe "a cache keyed by a name is never stale" do
    test "the old name still answers what it always answered", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, [{42, "height", 180}])

      engine = start_engine(world, [counting_formula(agent)])
      early = Snapshot.open([world])
      {:ok, answered_early} = Engine.answer(engine, "doubled", early)

      {:ok, _} = World.append(world, [{43, "height", 190}])
      {:ok, _} = Engine.answer(engine, "doubled", Snapshot.open([world]))

      # Nothing was invalidated, because nothing could have gone stale.
      assert {:ok, ^answered_early} = Engine.answer(engine, "doubled", early)
    end
  end

  describe "the engine decides what to keep" do
    test "the cache is bounded, and the oldest goes first", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      engine = start_engine(world, [counting_formula(agent)], cache: 2)

      names =
        for n <- 1..3 do
          {:ok, _} = World.append(world, [{n, "height", n}])
          snapshot = Snapshot.open([world])
          {:ok, _} = Engine.answer(engine, "doubled", snapshot)
          snapshot
        end

      assert Agent.get(agent, & &1) == 3
      assert Engine.cached(engine) == 2

      # The first was evicted, so asking it again recomputes — and returns
      # exactly what it did the first time.
      {:ok, _} = Engine.answer(engine, "doubled", hd(names))
      assert Agent.get(agent, & &1) == 4
    end

    test "it counts what it was asked and what it had to compute", %{world: world} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, [{42, "height", 180}])

      engine = start_engine(world, [counting_formula(agent)])
      snapshot = Snapshot.open([world])

      Engine.answer(engine, "doubled", snapshot)
      Engine.answer(engine, "doubled", snapshot)
      Engine.answer(engine, "doubled", snapshot)

      assert %{"doubled" => %{asked: 3, computed: 1}} = Engine.stats(engine)
    end
  end

  describe "the code is part of the question" do
    # C11, reproduced: the cache was keyed on {id, name}, register/2 replaces
    # in place, so a formula multiplying by 100 returned the old doubling's
    # 20 at every name already asked — the build cache that omitted the
    # compiler version.
    defp times(factor) do
      Formula.new("f", fn snapshot ->
        for fact <- Snapshot.find(snapshot, attribute: "height") do
          {fact.id, "doubled", fact.value * factor}
        end
      end)
    end

    test "changing a formula's body changes its answers at an already-asked name",
         %{world: world} do
      {:ok, _} = World.append(world, [{1, "height", 10}])
      engine = start_engine(world, [times(2)])
      snapshot = Snapshot.open([world])

      assert {:ok, [{1, "doubled", 20, "f"}]} = Engine.answer(engine, "f", snapshot)

      # The same id, new code — and the same closure SITE with a different
      # capture, which is the subtler half: the stamp covers the environment,
      # because two closures from one site over different values are two
      # formulas.
      :ok = Engine.register(engine, times(100))

      assert {:ok, [{1, "doubled", 1000, "f"}]} = Engine.answer(engine, "f", snapshot)
    end

    test "the same body asked twice is still one computation", %{world: world} do
      # The stamp must not break what the cache is for.
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = World.append(world, [{1, "height", 10}])
      engine = start_engine(world, [counting_formula(agent)])
      snapshot = Snapshot.open([world])

      Engine.answer(engine, "doubled", snapshot)
      Engine.answer(engine, "doubled", snapshot)
      assert Agent.get(agent, & &1) == 1
    end
  end

  describe "erasure reaches the cache" do
    # C10, reproduced: the key was destroyed and the SAME name at the SAME
    # engine kept serving the plaintext, because "a cache keyed by a name
    # cannot go stale" and "an old name answers :erased" were both in the
    # repository and the cache implemented the wrong one.
    test "a cached answer derived from a sealed fact dies with the key", %{world: world} do
      {:ok, _} = World.append(world, Erasure.seed())
      subject = "person-#{System.unique_integer([:positive])}"
      on_exit(fn -> Keyring.destroy(subject) end)

      {:ok, _} = World.append(world, [{7, "subject", subject}])
      {:ok, _} = World.append(world, [{7, "height", 180}])

      echo =
        Formula.new("echo", fn snapshot ->
          for fact <- Snapshot.find(snapshot, id: 7, attribute: "height") do
            {fact.id, "echoed", fact.value}
          end
        end)

      engine = start_engine(world, [echo])
      snapshot = Snapshot.open([world])

      assert {:ok, [{7, "echoed", 180, "echo"}]} = Engine.answer(engine, "echo", snapshot)

      :ok = Erasure.erase(subject)

      # Same engine, same name: the destroyed plaintext is not served.
      assert {:ok, [{7, "echoed", :erased, "echo"}]} = Engine.answer(engine, "echo", snapshot)
    end
  end
end
