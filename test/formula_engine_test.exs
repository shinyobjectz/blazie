defmodule LazyRiver.Formula.EngineTest do
  @moduledoc """
  The engine decides whether to keep an answer. Nobody declares it.

  The property that makes this easy: an answer at a named snapshot never
  changes, so a cache keyed by that name can never be stale. It needs eviction,
  not invalidation — there is no cache-coherence problem here because there is
  nothing to cohere.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Formula, Ledger, Snapshot, TestLedger}
  alias LazyRiver.Formula.Engine

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
    {:ok, _} = Ledger.append(ledger, Attribute.define("colour"))
    %{ledger: ledger}
  end

  defp counting_formula(agent) do
    Formula.new("doubled", fn snapshot ->
      Agent.update(agent, &(&1 + 1))

      for fact <- Snapshot.find(snapshot, attribute: "height") do
        {fact.id, "doubled", fact.answer * 2}
      end
    end)
  end

  defp start_engine(ledger, formulas, opts \\ []) do
    start_supervised!(
      {Engine,
       [ledger: ledger, formulas: formulas, name: :"engine_#{System.unique_integer([:positive])}"] ++
         opts}
    )
  end

  describe "a formula is registered, then asked by name" do
    test "an unregistered formula is refused, with how to fix it", %{ledger: ledger} do
      engine = start_engine(ledger, [])

      assert {:error, refusal} =
               Engine.answer(engine, "nobody_declared_this", Snapshot.open([ledger]))

      assert refusal.problem == :unregistered_formula
      assert refusal.repair =~ "register"
    end

    test "a registered one answers", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

      engine = start_engine(ledger, [counting_formula(agent)])

      assert {:ok, [{42, "doubled", 360, "doubled"}]} =
               Engine.answer(engine, "doubled", Snapshot.open([ledger]))
    end

    test "one can be registered while the engine runs", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      engine = start_engine(ledger, [])

      assert :ok = Engine.register(engine, counting_formula(agent))
      assert {:ok, _} = Engine.answer(engine, "doubled", Snapshot.open([ledger]))
    end
  end

  describe "the same question at the same name is computed once" do
    test "asking twice computes once", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

      engine = start_engine(ledger, [counting_formula(agent)])
      snapshot = Snapshot.open([ledger])

      {:ok, first} = Engine.answer(engine, "doubled", snapshot)
      {:ok, second} = Engine.answer(engine, "doubled", snapshot)

      assert first == second
      assert Agent.get(agent, & &1) == 1
    end

    test "a new name is a new question", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

      engine = start_engine(ledger, [counting_formula(agent)])

      {:ok, _} = Engine.answer(engine, "doubled", Snapshot.open([ledger]))
      {:ok, _} = Ledger.append(ledger, [{43, "height", 190}])
      {:ok, later} = Engine.answer(engine, "doubled", Snapshot.open([ledger]))

      assert Agent.get(agent, & &1) == 2
      assert length(later) == 2
    end
  end

  describe "a cache keyed by a name is never stale" do
    test "the old name still answers what it always answered", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

      engine = start_engine(ledger, [counting_formula(agent)])
      early = Snapshot.open([ledger])
      {:ok, answered_early} = Engine.answer(engine, "doubled", early)

      {:ok, _} = Ledger.append(ledger, [{43, "height", 190}])
      {:ok, _} = Engine.answer(engine, "doubled", Snapshot.open([ledger]))

      # Nothing was invalidated, because nothing could have gone stale.
      assert {:ok, ^answered_early} = Engine.answer(engine, "doubled", early)
    end
  end

  describe "the engine decides what to keep" do
    test "the cache is bounded, and the oldest goes first", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      engine = start_engine(ledger, [counting_formula(agent)], cache: 2)

      names =
        for n <- 1..3 do
          {:ok, _} = Ledger.append(ledger, [{n, "height", n}])
          snapshot = Snapshot.open([ledger])
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

    test "it counts what it was asked and what it had to compute", %{ledger: ledger} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, _} = Ledger.append(ledger, [{42, "height", 180}])

      engine = start_engine(ledger, [counting_formula(agent)])
      snapshot = Snapshot.open([ledger])

      Engine.answer(engine, "doubled", snapshot)
      Engine.answer(engine, "doubled", snapshot)
      Engine.answer(engine, "doubled", snapshot)

      assert %{"doubled" => %{asked: 3, computed: 1}} = Engine.stats(engine)
    end
  end
end
