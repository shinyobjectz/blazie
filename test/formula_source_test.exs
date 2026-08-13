defmodule Blazie.FormulaSourceTest do
  @moduledoc """
  A formula written in Lua, held in the world, run by the engine.

  Phase 1's claim: a formula can be authored without touching Elixir. What has
  to be true for that to be safe is that a formula loaded from a FACT is exactly
  as unable to reach outside as one written here — the fence is the absence of
  anything to reach, not a rule applied to trusted code and skipped for the
  rest. The last describe block is that, and it is the reason the rest is
  allowed to exist.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Formula, Snapshot, World}
  alias Blazie.Formula.Engine

  setup do
    name = "fsource-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Attribute.requires_seed())
    {:ok, _} = World.append(world, Attribute.define("age", answers: "integer"))
    {:ok, _} = World.append(world, Attribute.define("adult", answers: "boolean"))

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  defp declare(world, id, source) do
    World.append(world, [{id, "is", "formula"}, {id, "source", source}])
  end

  describe "a formula held in the world" do
    test "computes what its Lua says", %{world: world} do
      {:ok, _} = World.append(world, [{"ada", "age", 41}, {"kid", "age", 9}])

      {:ok, _} =
        declare(world, "adults", "for p in each { age = true } do p.adult = p.age >= 18 end")

      formula = Formula.of_source("adults", "for p in each { age = true } do p.adult = p.age >= 18 end")
      {assertions, _read} = Formula.run(formula, snapshot(world))

      assert {"ada", "adult", true, "adults"} in assertions
      assert {"kid", "adult", false, "adults"} in assertions
    end

    test "its answers name it", %{world: world} do
      {:ok, _} = World.append(world, [{"ada", "age", 41}])
      formula = Formula.of_source("adults", "ada.adult = true")

      {assertions, _read} = Formula.run(formula, snapshot(world))
      assert Enum.all?(assertions, fn {_id, _f, _v, by} -> by == "adults" end)
    end

    test "its read set is observed, not declared", %{world: world} do
      {:ok, _} = World.append(world, [{"ada", "age", 41}])
      formula = Formula.of_source("adults", "for p in each { age = true } do p.adult = true end")

      {_assertions, read} = Formula.run(formula, snapshot(world))

      assert read != [], "a formula that read nothing can never be stale"
    end

    test "one that will not run says which formula it was", %{world: world} do
      formula = Formula.of_source("broken", "this is not lua ((")

      assert_raise RuntimeError, ~r/"broken"/, fn -> Formula.run(formula, snapshot(world)) end
    end
  end

  describe "the registry is the world" do
    test "a formula arrives by being written", %{world: world} do
      assert Formula.declared(snapshot(world)) == []

      {:ok, _} = declare(world, "adults", "return 1")
      assert [%Formula{id: "adults"}] = Formula.declared(snapshot(world))
    end

    test "one declared without source is not a formula anything can run", %{world: world} do
      {:ok, _} = World.append(world, [{"halfway", "is", "formula"}])

      # Not an error — a declaration with no body yet is exactly what Phase 2
      # generates INTO. It is simply not runnable, so it is not returned.
      assert Formula.declared(snapshot(world)) == []
    end

    test "a later source corrects an earlier one", %{world: world} do
      {:ok, _} = declare(world, "adults", "ada.adult = false")
      {:ok, _} = World.append(world, [{"adults", "source", "ada.adult = true"}])

      [formula] = Formula.declared(snapshot(world))
      {assertions, _read} = Formula.run(formula, snapshot(world))

      assert {"ada", "adult", true, "adults"} in assertions
    end
  end

  describe "the engine runs one" do
    test "and caches it by snapshot name", %{world: world} do
      {:ok, _} = World.append(world, [{"ada", "age", 41}])
      {:ok, _} = declare(world, "adults", "for p in each { age = true } do p.adult = p.age >= 18 end")

      {:ok, engine} = Engine.start_link([])
      [formula] = Formula.declared(snapshot(world))
      :ok = Engine.register(engine, formula)

      at = snapshot(world)
      assert {:ok, first} = Engine.answer(engine, "adults", at)
      assert {:ok, ^first} = Engine.answer(engine, "adults", at)

      assert {"ada", "adult", true, "adults"} in first
      GenServer.stop(engine)
    end
  end

  describe "a formula from a fact cannot reach outside" do
    test "http is nil inside one", %{world: world} do
      # The reason the whole phase is safe. Source arriving as data does not get
      # a different world from source written here — there is one formula world
      # and it has nothing in it to reach with.
      formula = Formula.of_source("reaching", "ada.adult = (http == nil)")
      {assertions, _read} = Formula.run(formula, snapshot(world))

      assert {"ada", "adult", true, "reaching"} in assertions
    end

    test "every stripped global stays stripped", %{world: world} do
      for name <- Blazie.Lua.removed() do
        formula = Formula.of_source("probe", "ada.adult = (#{name} == nil)")
        {assertions, _read} = Formula.run(formula, snapshot(world))

        assert {"ada", "adult", true, "probe"} in assertions,
               "#{name} was reachable from a formula loaded out of a fact"
      end
    end

    test "one that never finishes is stopped rather than hanging the caller", %{world: world} do
      formula = Formula.of_source("spin", "while true do end")

      assert_raise RuntimeError, ~r/"spin"/, fn -> Formula.run(formula, snapshot(world)) end
    end
  end

  describe "a job written the same way" do
    test "gets the clock and http, which is the whole difference", %{world: world} do
      # A formula and a job differ by one argument to the same runner. That the
      # difference is one line rather than two code paths is why the fence can
      # be trusted: there is no second implementation to drift.
      formula = Formula.of_source("pure", "ada.adult = (http == nil)")
      {pure, _read} = Formula.run(formula, snapshot(world))
      assert {"ada", "adult", true, "pure"} in pure

      job = Blazie.Job.of_source("reaching", "ada.adult = (http ~= nil)")
      reaching = job.work.(snapshot(world))
      assert {"ada", "adult", true} in reaching
    end

    test "the registry is the world here too", %{world: world} do
      {:ok, _} =
        World.append(world, [{"tick", "is", "job"}, {"tick", "source", "ada.adult = true"}])

      assert [%Blazie.Job{id: "tick"}] = Blazie.Job.declared(snapshot(world))
    end
  end
end
