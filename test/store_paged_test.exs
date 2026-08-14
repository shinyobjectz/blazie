defmodule Blazie.StorePagedTest do
  @moduledoc """
  The store that seeks, behind the same seam and over the same bytes.

  What must hold: a paged world answers exactly what a resident world
  answers — history, patterns, erasure, old names — while holding only its
  tail; the same file opens under either store because the format lives in
  one place; and the tear rule survives the change of strategy.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Erasure, Keyring, Snapshot, Store, World}

  setup do
    dir = Path.join(System.tmp_dir!(), "paged-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp opened(dir, resident) do
    name = {:paged, System.unique_integer([:positive])}
    {:ok, world} = World.open(name, store: {Store.Paged, dir: dir}, resident: resident)
    ExUnit.Callbacks.on_exit(fn -> World.close(name) end)
    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    {name, world}
  end

  test "an evicted fact answers by pattern, off the index", %{dir: dir} do
    {_name, world} = opened(dir, 5)

    {:ok, _} = World.append(world, [{"ada", "height", 180}])
    for i <- 1..30, do: {:ok, _} = World.append(world, [{"filler-#{i}", "height", i}])

    # Ada's fact left residence long ago; the answer comes from a seek.
    assert World.resident(world) < 31
    assert Snapshot.value(Snapshot.open([world]), "ada", "height") == 180

    # And whole-history reads still see everything, in order.
    facts = Snapshot.facts(Snapshot.open([world]))
    assert length(Enum.filter(facts, &(&1.attribute == "height"))) == 31
  end

  test "a reopened paged world holds its tail and answers its history", %{dir: dir} do
    {name, world} = opened(dir, 5)

    {:ok, _} = World.append(world, [{"ada", "height", 180}])
    for i <- 1..20, do: {:ok, _} = World.append(world, [{"filler-#{i}", "height", i}])
    before = Snapshot.facts(Snapshot.open([world]))

    :ok = World.close(name)
    {:ok, world} = World.open(name, store: {Store.Paged, dir: dir}, resident: 5)
    on_exit(fn -> World.close(name) end)

    # Bounded residence, unbounded answers.
    assert World.resident(world) <= 10
    assert Snapshot.value(Snapshot.open([world]), "ada", "height") == 180
    assert Snapshot.facts(Snapshot.open([world])) == before
  end

  test "the same file opens under either store", %{dir: dir} do
    {name, world} = opened(dir, 5)
    {:ok, _} = World.append(world, [{"ada", "height", 180}])
    :ok = World.close(name)

    # The resident store reads what the paged store wrote — one format,
    # one module, no second copy to drift.
    {:ok, world} = World.open(name, store: {Store.File, dir: dir})
    assert Snapshot.value(Snapshot.open([world]), "ada", "height") == 180
    :ok = World.close(name)

    {:ok, world} = World.open(name, store: {Store.Paged, dir: dir}, resident: 5)
    on_exit(fn -> World.close(name) end)
    assert Snapshot.value(Snapshot.open([world]), "ada", "height") == 180
  end

  test "erasure reaches a fact that was never resident in this life", %{dir: dir} do
    {name, world} = opened(dir, 3)
    subject = "person-#{System.unique_integer([:positive])}"
    on_exit(fn -> Keyring.destroy(subject) end)

    {:ok, _} = World.append(world, Erasure.seed())
    {:ok, _} = World.append(world, [{42, "subject", subject}])
    {:ok, _} = World.append(world, [{42, "height", 180}])
    for i <- 1..10, do: {:ok, _} = World.append(world, [{"filler-#{i}", "height", i}])

    # Reopen: the subject fact is deep in the evicted past, and the subjects
    # map must find it anyway — C4's rule, asked of the store's index now.
    :ok = World.close(name)
    {:ok, world} = World.open(name, store: {Store.Paged, dir: dir}, resident: 3)
    on_exit(fn -> World.close(name) end)

    # A fresh write about the owned entity is still sealed.
    {:ok, tx} = World.append(world, [{42, "height", 999}])

    sealed =
      world
      |> World.raw_at(tx)
      |> Enum.filter(&(&1.id == 42 and &1.attribute == "height"))
      |> Enum.all?(&match?({:sealed, _, _, _, _, _, :bound}, &1.value))

    assert sealed, "a paged reopen forgot who the entity belongs to"

    :ok = Erasure.erase(subject)
    assert Snapshot.value(Snapshot.open([world]), 42, "height") == :erased
  end

  test "a zero-filled tail is cut, and the world opens whole", %{dir: dir} do
    {name, world} = opened(dir, 5)
    {:ok, _} = World.append(world, [{"ada", "height", 180}])
    :ok = World.close(name)

    path = Path.join(dir, Store.File.filename(name))
    File.write!(path, File.read!(path) <> :binary.copy(<<0>>, 64))

    {:ok, world} = World.open(name, store: {Store.Paged, dir: dir}, resident: 5)
    on_exit(fn -> World.close(name) end)

    assert Snapshot.value(Snapshot.open([world]), "ada", "height") == 180

    # And an append after the cut is not lost beyond a tear.
    {:ok, _} = World.append(world, [{"grace", "height", 170}])
    :ok = World.close(name)

    {:ok, world} = World.open(name, store: {Store.Paged, dir: dir}, resident: 5)
    on_exit(fn -> World.close(name) end)
    assert Snapshot.value(Snapshot.open([world]), "grace", "height") == 170
  end

  @tag :load
  @tag timeout: 600_000
  test "the gate: a million facts, bounded residence, interactive reads", %{dir: dir} do
    name = {:paged_gate, System.unique_integer([:positive])}
    {:ok, world} = World.open(name, store: {Store.Paged, dir: dir}, resident: 1_000)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("n", answers: "integer"))

    t0 = System.monotonic_time(:millisecond)

    for batch <- 0..199 do
      facts = for i <- 1..5_000, do: {"e-#{batch * 5_000 + i}", "n", i}
      {:ok, _} = World.append(world, facts, timeout: 60_000)
    end

    wrote_ms = System.monotonic_time(:millisecond) - t0
    memory_mb = div(:erlang.memory(:total), 1024 * 1024)

    # The interactive read: one entity by id, deep in the evicted past.
    r0 = System.monotonic_time(:microsecond)
    assert Snapshot.value(Snapshot.open([world]), "e-3", "n") == 3
    read_us = System.monotonic_time(:microsecond) - r0

    IO.puts(
      "\npaged gate: 1_000_000 facts written in #{wrote_ms}ms, node memory #{memory_mb}MB, " <>
        "evicted point-read #{read_us}us, resident #{World.resident(world)}"
    )

    # A transaction is evicted whole or not at all, so the floor is one
    # batch: five thousand facts resident out of a million.
    assert World.resident(world) <= 10_000
    # Interactive means milliseconds, not the measured thousand-x rescan.
    assert read_us < 50_000
  end
end
