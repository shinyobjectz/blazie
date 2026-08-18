defmodule Blazie.LuaRequireTest do
  @moduledoc """
  C2 — require() as a capability: the host resolves, the guest never reaches.

  The guest names a package; the host resolves it against the library world
  (Blazie.Package) and injects the source, executed once and cached per run
  (require semantics). No filesystem, no network, no package.path — an
  unknown name comes back as data (the catalog), never a stack unwind, so
  authored code can handle a missing dependency. Passed to a workspace guest
  via `library:`.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Lua, Package}

  setup do
    lib = {:"$library", System.unique_integer([:positive])}
    on_exit(fn -> Blazie.World.close(lib) end)

    {:ok, _} =
      Package.publish(
        "leftpad",
        "1.0.0",
        "return function(s, n) while #s < n do s = ' ' .. s end return s end",
        library: lib
      )

    {:ok, _} =
      Package.publish("greet", "2.0.0", "return { hello = function(x) return 'hi ' .. x end }",
        library: lib
      )

    %{lib: lib}
  end

  test "a guest requires a package and uses it", ctx do
    {:ok, answer} =
      Lua.workspace(
        """
        local pad = require("leftpad")
        local greet = require("greet")
        return pad("7", 4) .. "|" .. greet.hello("ada")
        """,
        %{},
        library: ctx.lib
      )

    assert answer.value == "   7|hi ada"
  end

  test "require caches: the module runs once per guest", ctx do
    {:ok, _} =
      Package.publish("counter", "1.0.0", "count = (count or 0) + 1 return count",
        library: ctx.lib
      )

    {:ok, answer} =
      Lua.workspace(
        """
        local a = require("counter")
        local b = require("counter")
        return a .. "," .. b
        """,
        %{},
        library: ctx.lib
      )

    # Ran once (1), the second require returns the cached value, not 2.
    assert answer.value == "1,1"
  end

  test "require name@version is exact", ctx do
    {:ok, _} =
      Package.publish("greet", "3.0.0", "return { hello = function(x) return 'YO ' .. x end }",
        library: ctx.lib
      )

    {:ok, answer} =
      Lua.workspace(
        """
        local old = require("greet@2.0.0")
        return old.hello("x")
        """,
        %{},
        library: ctx.lib
      )

    assert answer.value == "hi x"
  end

  test "an unknown require returns nil + the catalog, never a crash", ctx do
    {:ok, answer} =
      Lua.workspace(
        """
        local mod, err = require("nope")
        return { got = mod, has_err = (err ~= nil) }
        """,
        %{},
        library: ctx.lib
      )

    assert answer.value["got"] == nil
    assert answer.value["has_err"] == true
  end

  test "without the library grant, require is absent", _ctx do
    {:ok, answer} = Lua.workspace("return require == nil", %{})
    assert answer.value == true
  end

  test "a required package cannot reach the host — it runs under the same fence", ctx do
    {:ok, _} =
      Package.publish(
        "hostile",
        "1.0.0",
        "return { probe = function() return (io == nil) and (os.execute == nil) end }",
        library: ctx.lib
      )

    {:ok, answer} =
      Lua.workspace(
        """
        local h = require("hostile")
        return h.probe()
        """,
        %{},
        library: ctx.lib
      )

    assert answer.value == true
  end

  test "a guest cannot install — there is no install() in the guest, only require()" do
    {:ok, answer} =
      Lua.workspace(
        "return { install = (install == nil), require_present = (require ~= nil) }",
        %{},
        library: {:"$library", System.unique_integer([:positive])}
      )

    assert answer.value == %{"install" => true, "require_present" => true}
  end
end
