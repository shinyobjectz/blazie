defmodule Blazie.LuaFenceTest do
  @moduledoc """
  The fence, asked of the one guest runtime that remains.

  `sandbox_fence_test` asked these of the wasm lane: no network, no clock, no
  reach, a guest stopped rather than waited on. The lane was retired (LT3,
  docs/storage-plan.md) and the CLAIMS survived it — they are properties of
  the fence, not of an engine — so they are asked here of Luerl guests, where
  the fence is `Lua.world/2` stripping everything that reaches and
  `Lua.capabilities/1` naming the whole difference between kinds.

  The second half is the kong-lua-sandbox checklist (the shelf survey): their
  curated list of what an untrusted-Lua environment must not expose,
  diffed against ours — every name on it asserted absent, so a Luerl upgrade
  that grows a new stdlib table fails HERE, not in production.
  """
  use ExUnit.Case, async: true

  alias Blazie.Lua

  describe "the kinds differ by exactly the named capabilities" do
    test "capabilities/1 is the whole map" do
      assert Lua.capabilities(:formula) == %{network: false, clock: :frozen}
      assert Lua.capabilities(:job) == %{network: true, clock: :real}
    end

    test "a formula has no http and no blob; a job has both" do
      {:ok, formula} = Lua.run("return http == nil and blob == nil", as: :formula)
      assert formula == true

      {:ok, job} = Lua.run("return http ~= nil and blob ~= nil", as: :job)
      assert job == true
    end

    test "a formula's clock is frozen to the snapshot; a job's is real" do
      {:ok, frozen} = Lua.run("return os.time()", as: :formula, at: 42)
      assert frozen == 42

      {:ok, real} = Lua.run("return os.time()", as: :job)
      assert_in_delta real, System.system_time(:second), 5
    end
  end

  describe "the kong checklist — what an untrusted guest must not find" do
    # kong-lua-sandbox's whitelist, inverted: everything it deliberately
    # withholds from untrusted code, asserted absent in EVERY kind — even a
    # job. A job's reach is http.get and blob, granted one binding at a time;
    # none of the machine comes with them.
    @never ~w(
      io dofile loadfile load loadstring require package
      os.execute os.exit os.getenv os.remove os.rename os.tmpname os.date
      debug collectgarbage
      string.dump
    )

    # Kept DELIBERATELY off the list: rawget/rawset. kong strips them to
    # protect metatable walls; this fence is absence, not metatables — they
    # are pure table ops, and the shelf's own lust uses them.

    for kind <- [:formula, :job] do
      test "nothing on the list exists for a #{kind}" do
        lookups =
          Enum.map(@never, fn name ->
            path = name |> String.split(".") |> Enum.map_join("", &"[\"#{&1}\"]")
            "if _G#{path} ~= nil then found[#{inspect(name)}] = true end"
          end)

        source = """
        found = {}
        #{Enum.join(lookups, "\n")}
        local names = {}
        for k in pairs(found) do table.insert(names, k) end
        table.sort(names)
        return table.concat(names, ",")
        """

        assert {:ok, present} = Lua.run(source, as: unquote(kind))

        assert present in [nil, ""],
               "a #{unquote(kind)} guest can see: #{present} — the fence has a gap"
      end
    end

    test "the workspace guest is fenced the same, plus files" do
      {:ok, answer} =
        Lua.workspace(
          """
          return {
            io_absent = (io == nil),
            load_absent = (load == nil and loadstring == nil),
            require_absent = (require == nil),
            execute_absent = (os.execute == nil),
            files_present = (file ~= nil)
          }
          """,
          %{}
        )

      assert answer.value == %{
               "io_absent" => true,
               "load_absent" => true,
               "require_absent" => true,
               "execute_absent" => true,
               "files_present" => true
             }
    end
  end

  describe "a guest is stopped, never waited on" do
    test "a runaway loop dies at the deadline" do
      assert {:error, %{problem: :took_too_long}} =
               Lua.run("while true do end", as: :job, deadline: 200)
    end

    test "a memory bomb dies at the heap cap" do
      assert {:error, %{problem: :took_too_much_memory}} =
               Lua.run(
                 "local t = {} local i = 1 while true do t[i] = string.rep('x', 1000) i = i + 1 end",
                 as: :formula,
                 deadline: 30_000,
                 heap: 200_000
               )
    end
  end
end
