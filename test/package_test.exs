defmodule Blazie.PackageTest do
  @moduledoc """
  A package is a fact — the library world, content-addressed and version-pinned.

  Vendored/approved Lua libraries live as facts in ONE shared library world
  (no tenant names it — like the Graph, it is everyone's read and nobody's to
  pollute). Publishing is an append: `{name@version, "source", lua}` plus a
  content hash and the provenance of who vetted it. Resolution is by name to
  the newest version, or name@version exact. Republishing the same
  name@version with different bytes is refused — a version is immutable once
  it means something.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Package, Snapshot, World}

  setup do
    # A throwaway library world per test, so the suite never fights a shared one.
    world = {:"$library", System.unique_integer([:positive])}
    on_exit(fn -> World.close(world) end)
    %{lib: world}
  end

  test "publishing a package writes it as facts, hashed and attributed", ctx do
    {:ok, id} =
      Package.publish("leftpad", "1.0.0", "return function(s, n) return s end",
        library: ctx.lib,
        by: "operator"
      )

    assert id == "leftpad@1.0.0"

    snapshot = Snapshot.open([elem(World.open(ctx.lib), 1)])
    assert Snapshot.value(snapshot, id, "is") == "package"
    assert Snapshot.value(snapshot, id, "name") == "leftpad"
    assert Snapshot.value(snapshot, id, "version") == "1.0.0"
    assert Snapshot.value(snapshot, id, "source") =~ "function"
    assert is_binary(Snapshot.value(snapshot, id, "hash"))
    # Provenance: a package names who vetted it, on the fact itself.
    [fact | _] = Snapshot.find(snapshot, id: id, attribute: "source")
    assert fact.by == "operator"
  end

  test "resolve finds the newest version by name", ctx do
    {:ok, _} = Package.publish("json", "1.0.0", "return {v=1}", library: ctx.lib)
    {:ok, _} = Package.publish("json", "1.2.0", "return {v=2}", library: ctx.lib)
    {:ok, _} = Package.publish("json", "1.10.0", "return {v=3}", library: ctx.lib)

    assert {:ok, "json@1.10.0", source} = Package.resolve("json", library: ctx.lib)
    assert source =~ "v=3"
  end

  test "resolve name@version is exact", ctx do
    {:ok, _} = Package.publish("json", "1.0.0", "return {v=1}", library: ctx.lib)
    {:ok, _} = Package.publish("json", "2.0.0", "return {v=2}", library: ctx.lib)

    assert {:ok, "json@1.0.0", source} = Package.resolve("json@1.0.0", library: ctx.lib)
    assert source =~ "v=1"
  end

  test "an unknown package refuses with the shelf of what exists", ctx do
    {:ok, _} = Package.publish("json", "1.0.0", "return {}", library: ctx.lib)
    {:ok, _} = Package.publish("lust", "1.0.0", "return {}", library: ctx.lib)

    assert {:error, refusal} = Package.resolve("nope", library: ctx.lib)
    assert refusal.problem == :no_such_package
    assert refusal.repair =~ "json"
    assert refusal.repair =~ "lust"
  end

  test "republishing a version with different bytes is refused; identical is idempotent", ctx do
    {:ok, _} = Package.publish("json", "1.0.0", "return {v=1}", library: ctx.lib)

    # Same bytes again: idempotent, no error.
    assert {:ok, "json@1.0.0"} =
             Package.publish("json", "1.0.0", "return {v=1}", library: ctx.lib)

    # Different bytes under the same version: refused — a version is immutable.
    assert {:error, refusal} =
             Package.publish("json", "1.0.0", "return {v=999}", library: ctx.lib)

    assert refusal.problem == :version_immutable
    assert refusal.repair =~ "1.0.0"
  end

  test "the catalog lists names and their versions", ctx do
    {:ok, _} = Package.publish("json", "1.0.0", "return {}", library: ctx.lib)
    {:ok, _} = Package.publish("json", "1.1.0", "return {}", library: ctx.lib)
    {:ok, _} = Package.publish("lust", "0.9.0", "return {}", library: ctx.lib)

    catalog = Package.catalog(library: ctx.lib)
    assert catalog["json"] == ["1.0.0", "1.1.0"]
    assert catalog["lust"] == ["0.9.0"]
  end
end
