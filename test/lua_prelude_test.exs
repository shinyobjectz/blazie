defmodule Blazie.LuaPreludeTest do
  @moduledoc """
  The guest library shelf, actually on the shelf — vendored, and smoke-tested
  under Luerl before anything trusts it (the `learn` treatment, applied).

  Two libraries from the LT survey (docs/storage-plan.md), vendored whole
  into priv/lua as the MIT single-files they are, loaded into a workspace
  guest by name through the `prelude:` option — no `require`, no package
  path, no filesystem; the host reads the file and the guest gets a global.

    * `json` (rxi/json.lua) — guest-side JSON, the encode-before-`blob()` and
      structured-output need.
    * `lust` (bjornbytes/lust) — describe/it/expect in ~300 pure-Lua lines:
      the tenant-authored-test core the LT plan expected to hand-write.

  Both were checked for the known Luerl gap first (zero `string.gmatch`), and
  these tests are the ongoing tripwire: a vendored update that starts using a
  gap fails here, not in a tenant's job.
  """
  use ExUnit.Case, async: true

  alias Blazie.Lua

  describe "json" do
    test "encode/decode round trip inside the guest" do
      {:ok, answer} =
        Lua.workspace(
          """
          local encoded = json.encode({ name = "blazie", facts = {1, 2, 3} })
          local back = json.decode(encoded)
          return { name = back.name, second = back.facts[2], text = encoded }
          """,
          %{},
          prelude: [:json]
        )

      assert answer.value["name"] == "blazie"
      assert answer.value["second"] == 2
      assert answer.value["text"] =~ "\"name\""
    end

    test "a guest can persist structured state through the workspace" do
      {:ok, answer} =
        Lua.workspace(
          """
          local state = json.decode(file.read("state.json"))
          state.count = state.count + 1
          file.write("state.json", json.encode(state))
          return state.count
          """,
          %{"state.json" => ~s({"count": 41})},
          prelude: [:json]
        )

      assert answer.value == 42
      assert answer.files["state.json"] =~ "42"
    end
  end

  describe "lust" do
    test "describe/it/expect runs, counts passes and failures, prints a report" do
      {:ok, answer} =
        Lua.workspace(
          """
          lust.nocolor()
          local describe, it, expect = lust.describe, lust.it, lust.expect

          describe("arithmetic", function()
            it("adds", function() expect(1 + 1).to.equal(2) end)
            it("cannot divide by zero into an integer", function()
              expect(1 / 0).to.equal(2)  -- deliberately wrong
            end)
          end)

          return { passes = lust.passes, errors = lust.errors }
          """,
          %{},
          prelude: [:lust]
        )

      assert answer.value == %{"passes" => 1, "errors" => 1}
      # The report went through the captured print, results-as-data.
      assert answer.printed =~ "adds"
    end
  end

  test "an unknown prelude refuses with the shelf" do
    assert {:error, refusal} = Lua.workspace("return 1", %{}, prelude: [:left_pad])
    assert refusal.problem == :no_such_prelude
    assert refusal.repair =~ "json"
  end
end
