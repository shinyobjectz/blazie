defmodule Blazie.PackageInstallTest do
  @moduledoc """
  C3 — install is a judged job, not a guest action.

  A guest cannot install: fetching an outside package is network, which a
  formula-fenced guest does not have. Installation is a :job — network-
  allowed, credentials proxied through the Secret plane — and what it fetches
  is GATED before it lands: license approved, no C-extension markers, and it
  must SMOKE-TEST under Luerl (the discipline the vendored shelf already
  uses). Only a package that passes every check becomes a fact every guest
  can then require. An unvetted package runs in the same fence as everything
  else and still cannot reach the host — which is exactly why installing is
  safe.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Package, World}

  setup do
    lib = {:"$library", System.unique_integer([:positive])}
    on_exit(fn -> World.close(lib) end)
    %{lib: lib}
  end

  test "vet passes clean pure-Lua and reports each check", ctx do
    assert {:ok, report} =
             Package.vet("good", "1.0.0", "return { add = function(a, b) return a + b end }",
               license: "MIT"
             )

    assert report.license == :ok
    assert report.no_c == :ok
    assert report.smoke == :ok
    _ = ctx
  end

  test "vet refuses an unapproved license", _ctx do
    assert {:error, report} =
             Package.vet("bad", "1.0.0", "return {}", license: "GPL-3.0")

    assert report.license == {:rejected, "GPL-3.0"}
    assert report.repair =~ "license"
  end

  test "vet refuses a C-extension marker (require of a .so shape)", _ctx do
    src = "local ffi = require('ffi') return {}"

    assert {:error, report} =
             Package.vet("ffi_pkg", "1.0.0", src, license: "MIT")

    assert report.no_c == {:rejected, "ffi"}
    assert report.repair =~ "C extension"
  end

  test "vet refuses a package that does not run under Luerl", _ctx do
    # gmatch is a known Luerl gap — a package leaning on it fails the smoke.
    src = "for w in string.gmatch('a b', '%a+') do end return {}"

    assert {:error, report} = Package.vet("gmatchy", "1.0.0", src, license: "MIT")
    assert match?({:rejected, _}, report.smoke)
    assert report.repair =~ "Luerl"
  end

  test "install fetches via an injected fetcher, vets, and lands it as a fact", ctx do
    # The fetcher is the job's network boundary — mocked here; production is
    # http.get through the Secret-plane credential proxy.
    fetcher = fn "cool" -> {:ok, "return { v = 42 }", "MIT"} end

    assert {:ok, "cool@1.0.0"} =
             Package.install("cool", "1.0.0",
               library: ctx.lib,
               fetch: fetcher,
               by: "installer-job"
             )

    # Now every guest can resolve it.
    assert {:ok, "cool@1.0.0", src} = Package.resolve("cool", library: ctx.lib)
    assert src =~ "v = 42"
  end

  test "install refuses to land a package that fails vetting", ctx do
    fetcher = fn "evil" -> {:ok, "local ffi = require('ffi') return {}", "MIT"} end

    assert {:error, report} =
             Package.install("evil", "1.0.0", library: ctx.lib, fetch: fetcher)

    assert report.no_c != :ok
    # And nothing landed.
    assert {:error, _} = Package.resolve("evil", library: ctx.lib)
  end

  test "a fetch failure is surfaced, not swallowed", ctx do
    fetcher = fn _ -> {:error, "404 from upstream"} end

    assert {:error, report} =
             Package.install("ghost", "1.0.0", library: ctx.lib, fetch: fetcher)

    assert report.fetch =~ "404"
  end
end
