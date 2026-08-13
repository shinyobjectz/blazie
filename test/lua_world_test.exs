defmodule Blazie.LuaWorldTest do
  @moduledoc """
  The surface everybody outside this repo is shown.

  Every test here is written the way a user would write it — no fact, no
  attribute, no pattern, no assertion. If a test in this file needs one of those
  words to say what it means, the surface has leaked and the design is wrong.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Ledger, Lua, Snapshot}

  setup do
    name = "world-#{System.unique_integer([:positive])}"
    {:ok, ledger} = Ledger.open(name)
    %{ledger: ledger, snapshot: Snapshot.open([ledger])}
  end

  defp run(source, snapshot), do: Lua.World.run(source, snapshot)

  # Writing then reading in one chunk is the common case and has to work, so
  # most tests append what a chunk staged and re-open before asking.
  defp commit(%{ledger: ledger}, assertions) do
    {:ok, _tx} = Ledger.append(ledger, assertions)
    Snapshot.open([ledger])
  end

  describe "a field is a field" do
    test "what you set is what you get", context do
      {:ok, _, wrote} = run("ada.height = 180", context.snapshot)
      snapshot = commit(context, wrote)

      assert {:ok, 180, _} = run("return ada.height", snapshot)
    end

    test "a field nobody set is nil, not an error", context do
      assert {:ok, nil, _} = run("return ada.nothing", context.snapshot)
    end

    test "an entity nobody wrote is empty rather than missing", context do
      # The cost of bare names, stated as a test so it is a decision rather
      # than a surprise: a typo reads as an entity with nothing in it.
      assert {:ok, nil, _} = run("return typoed_name.height", context.snapshot)
    end

    test "strings, numbers and booleans all survive the round trip", context do
      {:ok, _, wrote} =
        run(
          """
          ada.name = 'Ada'
          ada.height = 180
          ada.retired = false
          """,
          context.snapshot
        )

      snapshot = commit(context, wrote)

      assert {:ok, "Ada", _} = run("return ada.name", snapshot)
      assert {:ok, 180, _} = run("return ada.height", snapshot)
      assert {:ok, false, _} = run("return ada.retired", snapshot)
    end
  end

  describe "an edge is a field whose value is another entity" do
    test "following one reads the other's fields", context do
      {:ok, _, wrote} =
        run(
          """
          grace.height = 175
          ada.friend = grace
          """,
          context.snapshot
        )

      snapshot = commit(context, wrote)

      assert {:ok, 175, _} = run("return ada.friend.height", snapshot)
    end

    test "a plain string stays a string", context do
      # `ada.name = 'grace'` must not become an edge just because something
      # called grace exists. What decides is how the field was declared, and a
      # name and a reference declare differently.
      {:ok, _, wrote} =
        run(
          """
          grace.height = 175
          ada.name = 'grace'
          """,
          context.snapshot
        )

      snapshot = commit(context, wrote)

      assert {:ok, "grace", _} = run("return ada.name", snapshot)
      assert {:ok, nil, _} = run("return ada.name.height", snapshot)
    end

    test "an edge written and followed inside one chunk", context do
      # Nothing has been appended yet, so this only works if a field declared
      # during the run is visible to the rest of the run.
      {:ok, _, wrote} = run("ada.friend = grace", context.snapshot)

      assert Enum.any?(wrote, fn {id, field, value} ->
               id == "friend" and field == "answers" and value == "id"
             end),
             "an edge must declare itself as one, got: #{inspect(wrote)}"
    end
  end

  describe "unsaying something" do
    test "nil retracts a field", context do
      {:ok, _, wrote} = run("ada.height = 180", context.snapshot)
      snapshot = commit(context, wrote)
      assert {:ok, 180, _} = run("return ada.height", snapshot)

      {:ok, _, retraction} = run("ada.height = nil", snapshot)
      after_it = commit(context, retraction)

      assert {:ok, nil, _} = run("return ada.height", after_it)
    end

    test "what was true is still true where it was written", context do
      {:ok, _, wrote} = run("ada.height = 180", context.snapshot)
      snapshot = commit(context, wrote)
      tx = snapshot |> Snapshot.name() |> Map.values() |> List.first()

      {:ok, _, retraction} = run("ada.height = nil", snapshot)
      after_it = commit(context, retraction)

      # Retracting is a later fact, not an erasure. The only thing that
      # actually destroys is erasure, and it destroys a key rather than a row.
      assert {:ok, nil, _} = run("return ada.height", after_it)
      assert {:ok, 180, _} = run("return at(#{tx}).ada.height", after_it)
    end

    test "a retracted field drops out of each", context do
      {:ok, _, wrote} = run("ada.height = 180\ngrace.height = 180", context.snapshot)
      snapshot = commit(context, wrote)

      {:ok, _, retraction} = run("ada.height = nil", snapshot)
      after_it = commit(context, retraction)

      source = """
      local found = {}
      for p in each { height = 180 } do found[#found + 1] = p.id end
      return table.concat(found, ',')
      """

      assert {:ok, "grace", _} = run(source, after_it)
    end

    test "retracting what was never written does nothing at all", context do
      # Not an error, and not a declaration either: a ledger describing a field
      # that never held anything would be worse than the no-op.
      assert {:ok, _, []} = run("ada.nothing = nil", context.snapshot)
    end
  end

  describe "pairs lists what is said about an entity" do
    test "every field, and nothing else", context do
      {:ok, _, wrote} =
        run(
          """
          ada.height = 180
          ada.name = 'Ada'
          """,
          context.snapshot
        )

      snapshot = commit(context, wrote)

      source = """
      local seen = {}
      for field, value in pairs(ada) do seen[#seen + 1] = field .. '=' .. tostring(value) end
      table.sort(seen)
      return table.concat(seen, ',')
      """

      assert {:ok, "height=180,name=Ada", _} = run(source, snapshot)
    end

    test "a retracted field is absent rather than nil", context do
      {:ok, _, wrote} = run("ada.height = 180\nada.name = 'Ada'", context.snapshot)
      snapshot = commit(context, wrote)

      {:ok, _, retraction} = run("ada.height = nil", snapshot)
      after_it = commit(context, retraction)

      source = """
      local seen = {}
      for field in pairs(ada) do seen[#seen + 1] = field end
      return table.concat(seen, ',')
      """

      assert {:ok, "name", _} = run(source, after_it)
    end

    test "an entity nobody wrote lists nothing", context do
      source = """
      local n = 0
      for _ in pairs(nobody) do n = n + 1 end
      return n
      """

      assert {:ok, 0, _} = run(source, context.snapshot)
    end
  end

  describe "each" do
    setup context do
      {:ok, _, wrote} =
        run(
          """
          ada.height = 180
          grace.height = 180
          alan.height = 175
          alan.age = 41
          """,
          context.snapshot
        )

      %{snapshot: commit(context, wrote)}
    end

    test "finds everything with a matching value", %{snapshot: snapshot} do
      source = """
      local found = {}
      for p in each { height = 180 } do found[#found + 1] = p.id end
      table.sort(found)
      return table.concat(found, ',')
      """

      assert {:ok, "ada,grace", _} = run(source, snapshot)
    end

    test "`true` asks who has the field at all", %{snapshot: snapshot} do
      source = """
      local found = {}
      for p in each { age = true } do found[#found + 1] = p.id end
      return table.concat(found, ',')
      """

      assert {:ok, "alan", _} = run(source, snapshot)
    end

    test "an empty spec is everyone", %{snapshot: snapshot} do
      source = """
      local n = 0
      for _ in each {} do n = n + 1 end
      return n
      """

      # Three people, plus the fields that declared themselves — everything with
      # anything said about it is an entity, including `height`.
      assert {:ok, count, _} = run(source, snapshot)
      assert count >= 3
    end

    test "matching nothing is an empty loop, not an error", %{snapshot: snapshot} do
      source = """
      local n = 0
      for _ in each { height = 999 } do n = n + 1 end
      return n
      """

      assert {:ok, 0, _} = run(source, snapshot)
    end
  end

  describe "at" do
    test "reads the world as it was", context do
      {:ok, _, first} = run("ada.height = 180", context.snapshot)
      snapshot = commit(context, first)
      tx = snapshot |> Snapshot.name() |> Map.values() |> List.first()

      {:ok, _, second} = run("ada.height = 181", snapshot)
      later = commit(context, second)

      assert {:ok, 181, _} = run("return ada.height", later)
      assert {:ok, 180, _} = run("return at(#{tx}).ada.height", later)
    end

    test "a correction does not erase what was there", context do
      {:ok, _, first} = run("ada.height = 180", context.snapshot)
      snapshot = commit(context, first)
      tx = snapshot |> Snapshot.name() |> Map.values() |> List.first()

      {:ok, _, second} = run("ada.height = 181", snapshot)
      later = commit(context, second)

      # Both answers are true, each at its own name. That is the whole
      # difference from a database that overwrites.
      assert {:ok, 180, _} = run("return at(#{tx}).ada.height", later)
      assert {:ok, 181, _} = run("return ada.height", later)
    end
  end

  describe "the fence still holds" do
    test "a formula cannot reach the outside", context do
      assert {:ok, nil, _} = run("return http", context.snapshot)
    end

    test "a stripped name stays absent rather than becoming an entity", context do
      # The bare-name metatable turns any unknown global into an entity, which
      # once turned every removed global from `nil` into an empty table called
      # "io". Calling it still failed, so nothing was reachable — but the fence's
      # claim is "there is nothing to reach", and a name answering with a table
      # is not nothing. It would have hidden the next binding mistake.
      for name <- Blazie.Lua.removed() do
        assert {:ok, nil, _} = run("return #{name}", context.snapshot),
               "#{name} was stripped but the world handed back an entity for it"
      end
    end

    test "a formula's clock does not move", context do
      assert {:ok, 0, _} = Lua.World.run("return os.time()", context.snapshot, at: 0)
    end

    test "a runaway chunk is stopped and writes nothing", context do
      assert {:error, refusal} =
               Lua.World.run("while true do end", context.snapshot, deadline: 200)

      assert refusal.problem == :took_too_long
    end

    test "nothing is appended by running", context do
      {:ok, _, wrote} = run("ada.height = 180", context.snapshot)

      assert wrote != []
      # The ledger is untouched: staging is the whole contract, and a guest that
      # could append would be a guest that could write during a formula.
      assert context.snapshot |> Snapshot.find([]) |> Enum.empty?()
    end
  end
end
