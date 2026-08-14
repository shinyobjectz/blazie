defmodule Blazie.SandboxFenceTest do
  @moduledoc """
  Doctrine 14 as one mechanism: a formula and a job run in the same sandbox
  and differ only in the network, and the difference is decided in exactly
  one function — `Blazie.Lua.capabilities/1` — not inferred from two fences
  that must agree.

  The wasm side is asserted the same way it is enforced: by absence. A
  formula-shaped and a job-shaped wasm guest are the same fenced thing,
  because WASI preview 1 has no sockets to hand either one.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Lua, Snapshot, World}

  test "the capability map is the single source of the network decision" do
    assert Lua.capabilities(:formula) == %{network: false, clock: :frozen}
    assert Lua.capabilities(:job) == %{network: true, clock: :real}
  end

  test "a formula's world holds nothing that reaches; a job's holds http and blob" do
    # Asserted on the built world, not on a chunk's behaviour — the fence is
    # the absence of anything to reach, so absence is what a test checks.
    formula = Lua.world(:formula, 0)
    job = Lua.world(:job, 0)

    assert reach(formula, "http") == nil
    assert reach(formula, "blob") == nil
    # The reaching globals are stripped for both; the kind only decides what
    # is handed BACK.
    for stripped <- ~w(io require load) do
      assert reach(formula, stripped) == nil
      assert reach(job, stripped) == nil
    end

    refute reach(job, "http") == nil
    refute reach(job, "blob") == nil
  end

  test "a formula that reaches for the network gets nothing, end to end" do
    world = Blazie.TestLedger.open()
    {:ok, _} = World.append(world, Blazie.Attribute.seed())
    {:ok, _} = World.append(world, Blazie.Attribute.define("out", answers: "any"))

    # `http` is not a table in a formula's world, so indexing it is nil — the
    # chunk cannot call a function that is not there.
    {:ok, value, _staged} =
      Lua.Binding.run("return http == nil", Snapshot.open([world]), as: :formula, at: 0)

    assert value == true
  end

  defp reach(state, name) do
    {:ok, value, _state} = :luerl.get_table_keys([name], state)
    value
  end
end
