defmodule Blazie.AtScaleTest do
  @moduledoc """
  A world large enough to be worth having, walked.

  Every one of these failed before the engine could do it, and none of them was
  visible to the rest of the suite, because every other test builds a world of
  three entities and a world of three entities has no ceiling. The console found
  it instead: the data page, the worlds page and the orbit all refused a world of
  12,400 entities with `took_too_much_memory`, which is a database declining to
  count itself.

  The numbers below are deliberately just past where it used to break rather
  than as large as it now goes. What is being defended is that the ceiling is not
  the size of the data — a test at 100,000 would say the same thing and spend a
  minute saying it.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Snapshot, Symbol, World}

  # Past 12,400, which is the size the console first refused.
  @many 15_000

  setup do
    name = "scale-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    {:ok, _tx} = World.append(world, Attribute.seed())

    on_exit(fn -> World.close(name) end)
    %{world: world, name: name}
  end

  defp fill(world, n) do
    for chunk <- Enum.chunk_every(1..n, 2_500) do
      {:ok, _tx} = World.append(world, for(i <- chunk, do: {"e#{i}", "n", i}))
    end

    Snapshot.open([world])
  end

  defp run(source, snapshot), do: Blazie.Lua.Binding.run(source, snapshot, deadline: 60_000)

  describe "a large world can be walked" do
    test "counted", %{world: world} do
      snapshot = fill(world, @many)

      assert {:ok, counted, _} =
               run("local n = 0\nfor e in each {} do n = n + 1 end\nreturn n", snapshot)

      # The seeded attributes are entities too, so this is at least what was
      # written rather than exactly it.
      assert counted >= @many
    end

    test "read a field from every one", %{world: world} do
      snapshot = fill(world, @many)

      source = """
      local total = 0
      for e in each {} do
        if e.n then total = total + 1 end
      end
      return total
      """

      assert {:ok, @many, _} = run(source, snapshot)
    end

    test "listed with every field, which is what the data page asks", %{world: world} do
      snapshot = fill(world, @many)

      # `pairs` on every entity — the most expensive shape the console has, and
      # the one that returned 422 from a page whose whole job is to show rows.
      source = """
      local rows = 0
      for e in each {} do
        for field, value in pairs(e) do rows = rows + 1 end
      end
      return rows
      """

      assert {:ok, rows, _} = run(source, snapshot)
      assert rows >= @many
    end

    test "narrowed to one entity without reading the rest", %{world: world} do
      snapshot = fill(world, @many)

      assert {:ok, ["e7777"], _} =
               run(
                 "local out = {}\nfor e in each { n = 7777 } do out[#out+1] = e.id end\nreturn out",
                 snapshot
               )
    end
  end

  describe "what the sweep may not do" do
    # Iterating collects the Lua heap as it goes, because Luerl has no collector
    # of its own and would otherwise grow by the size of the world. A collector
    # that freed something still reachable would be far worse than the ceiling it
    # replaced — it would answer wrongly rather than refuse — so what a chunk is
    # holding has to survive it.
    test "entities the chunk is still holding survive it", %{world: world} do
      snapshot = fill(world, 5_000)

      # Held across thousands of iterations, so several sweeps happen while this
      # table is reachable and only reachable from it.
      source = """
      local kept = {}
      for e in each {} do
        if e.n and e.n % 1000 == 0 then kept[#kept + 1] = e end
      end

      local total = 0
      for _, e in ipairs(kept) do total = total + e.n end
      return total
      """

      # 1000 + 2000 + 3000 + 4000 + 5000
      assert {:ok, 15_000, _} = run(source, snapshot)
    end

    test "an entity read after the loop still answers", %{world: world} do
      snapshot = fill(world, 5_000)

      source = """
      local last
      for e in each {} do last = e end
      return e4999.n
      """

      assert {:ok, 4999, _} = run(source, snapshot)
    end
  end

  describe "the read set is the size of the vocabulary, not the data" do
    test "walking every entity records one pattern, not one per entity", %{world: world} do
      snapshot = fill(world, @many)

      {:ok, _value, _wrote, read} =
        Blazie.Lua.collect(
          "local n = 0\nfor e in each {} do if e.n then n = n + e.n end end\nreturn n",
          snapshot: snapshot,
          deadline: 60_000
        )

      # It used to be one per read: 15,005 patterns naming individual facts,
      # which `Job.touched?/2` would then ask the world about one at a time on
      # every single tick.
      assert length(read) < 10
    end

    test "and is still wide enough to notice a change", %{world: world, name: name} do
      snapshot = fill(world, @many)

      {:ok, _value, _wrote, read} =
        Blazie.Lua.collect(
          "local n = 0\nfor e in each {} do if e.n then n = n + e.n end end\nreturn n",
          snapshot: snapshot,
          deadline: 60_000
        )

      # The bound generalises rather than truncates, so a fact this chunk would
      # have depended on still lands inside the set. Erring wide costs a re-run;
      # erring narrow costs a wrong answer that never expires.
      {:ok, _} = World.append(World.via(name), [{"e1", "n", 999_999}])
      landed = World.find_at(World.via(name), World.tx(World.via(name)), id: "e1", attribute: "n")

      assert Blazie.Formula.stale?(read, landed)
    end
  end

  describe "a value JSON cannot carry" do
    test "a symbol reads as its space and its size, never its bytes", %{world: world} do
      {:ok, _tx} =
        World.append(
          world,
          Symbol.seed() ++
            Attribute.define("vec", answers: "symbol", space: "potion_256") ++
            [{"doc", "vec", Symbol.new("potion_256", [0.1, 0.2, 0.3])}]
        )

      snapshot = Snapshot.open([world])

      assert {:ok, %{"space" => "potion_256", "dimensions" => 3}, _} =
               run("return doc.vec", snapshot)
    end

    test "and the same when listed rather than read", %{world: world} do
      {:ok, _tx} =
        World.append(
          world,
          Symbol.seed() ++
            Attribute.define("vec", answers: "symbol", space: "potion_256") ++
            [{"doc", "vec", Symbol.new("potion_256", [0.1, 0.2, 0.3])}]
        )

      snapshot = Snapshot.open([world])

      # Reading a field and listing an entity's fields are two translations into
      # Lua, and only the first knew what a symbol was. So `doc.vec` gave a space
      # and a size while `pairs(doc)` gave the packed float64s — which are not
      # text, do not encode, and reached the wire as a bare 500.
      source = """
      local out = {}
      for field, value in pairs(doc) do out[field] = value end
      return out
      """

      assert {:ok, %{"vec" => %{"space" => "potion_256", "dimensions" => 3}}, _} =
               run(source, snapshot)
    end

    test "everything a walk returns can be encoded", %{world: world} do
      {:ok, _tx} =
        World.append(
          world,
          Symbol.seed() ++
            Attribute.define("vec", answers: "symbol", space: "potion_256") ++
            [{"doc", "vec", Symbol.new("potion_256", [0.1, 0.2, 0.3])}]
        )

      source = """
      local rows = {}
      for e in each {} do
        local row = { id = e.id }
        for field, value in pairs(e) do row[field] = value end
        rows[#rows + 1] = row
      end
      return rows
      """

      {:ok, rows, _} = run(source, Snapshot.open([world]))

      # The whole point. This is the data page's own source, and it must survive
      # the trip to a caller.
      assert {:ok, _json} = Jason.encode(rows)
    end
  end
end
