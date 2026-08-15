defmodule Blazie.LuaSqlTest do
  @moduledoc """
  LT4 — the sql() grant: relational reach over exactly one file, read-only.

  The payoff the Lua-only bet was priced on (docs/storage-plan.md, LT4): a
  guest gets `sql("SELECT ...")` over ITS OWN world's SQLite file — the
  fence IS the file. The connection is read-only (the engine refuses a
  write, and the refusal comes back as data), opened per query against the
  path the HOST chose; the guest never holds a handle, a connection, or a
  path of its own choosing. Blob columns (id, value — erlang terms) come
  back decoded through the same [:safe] gate every stored byte passes.

  What this is for: the SHAPE of the world — counts, attributes, tx ranges,
  grouping — the questions a workspace script asks before deciding what to
  read. Value-level queries stay with the facts binding the guest already
  has; the division is documented at the grant.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Coding, Lua, Snapshot, Store, World}

  setup do
    dir = Path.join(System.tmp_dir!(), "luasql_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    name = {:luasql, System.unique_integer([:positive])}
    {:ok, world} = World.open(name, store: {Store.SQLite, dir: dir})

    on_exit(fn ->
      World.close(name)
      File.rm_rf!(dir)
    end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Coding.seed())

    {:ok, _} =
      World.append(world, [
        {"file:notes.txt", "path", "notes.txt"},
        {"file:notes.txt", "content", "alpha"},
        {"h1", "kind", "post"},
        {"h2", "kind", "post"},
        {"h3", "kind", "comment"}
      ])

    %{world: world, name: name, path: World.store_path(world)}
  end

  test "the world exposes its store's path", ctx do
    assert is_binary(ctx.path)
    assert String.ends_with?(ctx.path, ".sqlite")
    assert File.exists?(ctx.path)
  end

  test "a guest asks the shape of its world", ctx do
    {:ok, answer} =
      Lua.workspace(
        """
        local rows = sql("SELECT attribute, count(*) AS n FROM facts GROUP BY attribute ORDER BY attribute")
        local kinds = sql("SELECT count(*) AS n FROM facts WHERE attribute = 'kind'")
        return { first = rows[1].attribute, kinds = kinds[1].n }
        """,
        %{},
        sql_path: ctx.path
      )

    assert answer.value["kinds"] == 3
    assert is_binary(answer.value["first"])
  end

  test "blob columns come back decoded", ctx do
    {:ok, answer} =
      Lua.workspace(
        """
        local rows = sql("SELECT id_blob AS id, value, tx FROM facts WHERE attribute = 'kind' ORDER BY tx, seq")
        return { id = rows[1].id, value = rows[1].value, tx = rows[1].tx }
        """,
        %{},
        sql_path: ctx.path
      )

    assert answer.value["id"] == "h1"
    assert answer.value["value"] == "post"
    assert is_integer(answer.value["tx"])
  end

  test "a write is refused by the engine, answered as data", ctx do
    {:ok, answer} =
      Lua.workspace(
        """
        local rows, err = sql("INSERT INTO facts (tx, id_blob, attribute, value) VALUES (1, x'00', 'x', x'00')")
        return { rows_nil = (rows == nil), err = err }
        """,
        %{},
        sql_path: ctx.path
      )

    assert answer.value["rows_nil"] == true
    assert answer.value["err"] =~ "read"
  end

  test "without the grant, sql is absent — not an error, an absence" do
    {:ok, answer} = Lua.workspace("return sql == nil", %{})
    assert answer.value == true
  end

  test "the coding run gets sql over its own world", ctx do
    {:ok, _} =
      World.append(ctx.world, [
        {"file:shape.lua", "path", "shape.lua"},
        {"file:shape.lua", "content",
         """
         local rows = sql("SELECT count(*) AS n FROM facts WHERE attribute = 'kind'")
         print(string.format("%d kinds", rows[1].n))
         """}
      ])

    snapshot = Snapshot.open([ctx.world])
    assert {:ok, answered} = Coding.execute(ctx.world, "run-1", "shape.lua", snapshot)
    assert answered["printed"] == "3 kinds"
  end
end
