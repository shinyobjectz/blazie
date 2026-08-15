defmodule Blazie.StoreMigrateTest do
  @moduledoc """
  The one-way door: a `.ledger` becomes a `.sqlite`, byte-for-byte in meaning.

  Real disks hold facts in every shape this database ever wrote — the
  `answer` slot, the `LazyRiver.Fact` struct tag — and an append-only store
  must read them forever. So the migrator does not parse bytes itself: it
  reads through `Store.File`'s own replay (which normalizes every old shape
  via `Fact.from_stored/1`, the path `old_shapes_test` pins) and writes
  today's facts into `Store.SQLite`, preserving tx numbering and within-tx
  position. The proof is equality: the migrated world answers exactly what
  the ledger answered.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Fact, Snapshot, Store, World}
  alias Blazie.Store.Migrate

  setup do
    dir = Path.join(System.tmp_dir!(), "migrate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: {:migrate, System.unique_integer([:positive])}}
  end

  # The old-shape fixture writers, verbatim from old_shapes_test — bytes a
  # previous version wrote, never constructed with today's struct.
  defp older_fact(id, attribute, value, tx) do
    %{__struct__: Fact, id: id, attribute: attribute, answer: value, tx: tx, by: nil}
  end

  defp renamed_fact(id, attribute, value, tx) do
    %{
      __struct__: :"Elixir.LazyRiver.Fact",
      id: id,
      attribute: attribute,
      value: value,
      tx: tx,
      by: nil
    }
  end

  defp record(facts) do
    payload = :erlang.term_to_binary(facts)
    <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  defp write_older_log(ctx, transactions) do
    path = Path.join(ctx.dir, Store.File.filename(ctx.name))
    bytes = transactions |> Enum.map(&record/1) |> IO.iodata_to_binary()
    File.write!(path, bytes)
    path
  end

  test "an old-shape ledger migrates and answers identically", ctx do
    write_older_log(ctx, [
      [older_fact(42, "height", 180, 1)],
      [renamed_fact(42, "height", 181, 2), renamed_fact(43, "height", 170, 2)]
    ])

    assert {:ok, %{facts: 3, transactions: 2}} = Migrate.ledger_to_sqlite(ctx.name, dir: ctx.dir)

    # The migrated store answers what the ledger answers — same facts, same
    # order, same tx, today's shape.
    {:ok, ledger} = Store.File.open(ctx.name, dir: ctx.dir)
    from_ledger = Store.File.replay(ledger)
    Store.File.close(ledger)

    {:ok, sqlite} = Store.SQLite.open(ctx.name, dir: ctx.dir)
    from_sqlite = Store.SQLite.replay(sqlite)
    Store.SQLite.close(sqlite)

    assert from_sqlite == from_ledger
    assert Enum.map(from_sqlite, & &1.value) == [180, 181, 170]
  end

  test "within-tx position survives the migration", ctx do
    # Two facts for one {id, attribute} in ONE old transaction — the landmine,
    # asked across the migration boundary.
    write_older_log(ctx, [
      [older_fact(1, "n", "first", 1), older_fact(1, "n", "second", 1)]
    ])

    assert {:ok, _} = Migrate.ledger_to_sqlite(ctx.name, dir: ctx.dir)

    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dir})
    on_exit(fn -> World.close(ctx.name) end)
    assert Snapshot.value(Snapshot.open([world]), 1, "n") == "second"
  end

  test "the migrated world resumes its tx counter", ctx do
    write_older_log(ctx, [
      [older_fact(1, "n", 1, 1)],
      [older_fact(2, "n", 2, 2)],
      [older_fact(3, "n", 3, 3)]
    ])

    assert {:ok, _} = Migrate.ledger_to_sqlite(ctx.name, dir: ctx.dir)

    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dir})
    on_exit(fn -> World.close(ctx.name) end)

    assert World.tx(world) == 3
    assert {:ok, 4} = World.append(world, [{4, "n", 4}])
  end

  test "a second migration refuses rather than doubling the world", ctx do
    write_older_log(ctx, [[older_fact(1, "n", 1, 1)]])

    assert {:ok, _} = Migrate.ledger_to_sqlite(ctx.name, dir: ctx.dir)
    assert {:error, refusal} = Migrate.ledger_to_sqlite(ctx.name, dir: ctx.dir)
    assert refusal.problem == :already_migrated
    assert refusal.repair =~ "sqlite"
  end

  test "a name with no ledger refuses with the repair", ctx do
    assert {:error, refusal} = Migrate.ledger_to_sqlite({:nothing_here, 1}, dir: ctx.dir)
    assert refusal.problem == :no_ledger
  end
end
