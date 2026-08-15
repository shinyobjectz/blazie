defmodule Blazie.CodingRunLuaTest do
  @moduledoc """
  LT2 — the coding agent's run tool speaks Lua, over the workspace grant.

  The python path staged facts into a temp directory and preopened it to
  WASI; the Lua path needs neither directory nor wasm: workspace facts become
  the guest's map, the guest computes/prints/writes, and what changed comes
  back as facts with the run's provenance — the same harvest the python path
  promised ("a run that wrote a file and told nobody would be a run whose
  work vanished"). One fence posture: no reach, frozen clock.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Coding, Snapshot, World, TestLedger}

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Coding.seed())

    {:ok, _} =
      World.append(world, [
        {"file:report.lua", "path", "report.lua"},
        {"file:report.lua", "content",
         """
         -- string.gmatch is a known Luerl gap (LT verdict); gsub walks instead.
         local data = file.read("numbers.txt")
         local total = 0
         string.gsub(data, "%d+", function(n) total = total + tonumber(n) end)
         print("total: " .. string.format("%d", total))
         file.write("total.txt", string.format("%d", total))
         """},
        {"file:numbers.txt", "path", "numbers.txt"},
        {"file:numbers.txt", "content", "3 4 5"}
      ])

    %{world: world}
  end

  test "a .lua file runs over the workspace and its writes land as facts", %{world: world} do
    snapshot = Snapshot.open([world])

    assert {:ok, answered} = Coding.execute(world, "run-1", "report.lua", snapshot)

    assert answered["printed"] =~ "total: 12"
    assert answered["changed"] == ["total.txt"]

    # The write is a FACT now, carrying the run's provenance.
    after_run = Snapshot.open([world])
    assert Snapshot.value(after_run, "file:total.txt", "content") == "12"

    [fact | _] = Snapshot.find(after_run, id: "file:total.txt", attribute: "content")
    assert fact.by == "run-1"
  end

  test "a missing path refuses with the repair", %{world: world} do
    snapshot = Snapshot.open([world])

    assert {:ok, answered} = Coding.execute(world, "run-1", "nope.lua", snapshot)
    assert answered["failed"] =~ "nope.lua"
  end

  test "a broken script answers its error rather than raising", %{world: world} do
    {:ok, _} =
      World.append(world, [
        {"file:bad.lua", "path", "bad.lua"},
        {"file:bad.lua", "content", "this is not lua at all ("}
      ])

    snapshot = Snapshot.open([world])
    assert {:ok, answered} = Coding.execute(world, "run-1", "bad.lua", snapshot)
    assert is_binary(answered["failed"])
  end
end
