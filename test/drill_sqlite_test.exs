defmodule Blazie.DrillSQLiteTest do
  @moduledoc """
  The drill over the replicator: a SQLite world is proven the way it is kept.

  A backup is only ever proven by the last restore, and that holds for the
  litestream era exactly as it held for segments: the drill pulls one world
  back OUT of the replica with `litestream restore`, opens the copy under
  `Store.SQLite`, and asks both worlds the same question at the same
  transaction. The pull differs by store; the comparison is the same
  `ask_both` the ledger drill runs — one comparison, so the SQLite path
  cannot be correct while the ledger path is not, or the reverse.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Drill, Replication, Snapshot, Store, World}

  @moduletag :litestream

  setup_all do
    case System.find_executable("litestream") do
      nil -> raise "litestream is not installed — run with --exclude litestream"
      _ -> :ok
    end

    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "drill_sq_#{System.unique_integer([:positive])}")
    dbs = Path.join(base, "ledgers")
    replica = Path.join(base, "replica")
    scratch = Path.join(base, "scratch")
    File.mkdir_p!(dbs)
    File.mkdir_p!(replica)
    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      dbs: dbs,
      scratch: scratch,
      replica_url: "file://#{replica}",
      name: {:drill_sq, System.unique_integer([:positive])}
    }
  end

  defp shipped?(name, replica_url) do
    Enum.reduce_while(1..600, false, fn _, _ ->
      if Replication.replicated?(name, replica_url),
        do: {:halt, true},
        else: {:cont, Process.sleep(50) && false}
    end)
  end

  test "a replicated SQLite world is restored, opened, and answers identically", ctx do
    replicator =
      start_supervised!(
        {Replication, dir: ctx.dbs, pattern: "*.sqlite", replica_url: ctx.replica_url}
      )

    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    on_exit(fn -> World.close(ctx.name) end)
    {:ok, _} = World.append(world, [{42, "height", 180}])
    {:ok, tx} = World.append(world, [{42, "height", 181}, {43, "height", 170}])

    assert shipped?(ctx.name, ctx.replica_url), "the replicator never shipped the world"
    :ok = Replication.drain(replicator)

    history = {:drill_sq_history, System.unique_integer([:positive])}
    {:ok, drills} = World.open(history)
    on_exit(fn -> World.close(history) end)

    assert {:ok, report} =
             Drill.run(Snapshot.open([drills]),
               replica_url: ctx.replica_url,
               ledger_dir: ctx.dbs,
               scratch_dir: ctx.scratch
             )

    assert report.drilled == ctx.name
    assert report.ledgers == 1
    assert report.proven_tx == tx
    assert report.compared_facts == 3
  end

  test "a SQLite world the replica has never seen is skipped, not failed", ctx do
    # No replicator ran, so nothing is held for this world — the same honest
    # skip a memory world gets: nothing was proven, and the report says so.
    {:ok, _world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    on_exit(fn -> World.close(ctx.name) end)

    history = {:drill_sq_history, System.unique_integer([:positive])}
    {:ok, drills} = World.open(history)
    on_exit(fn -> World.close(history) end)

    assert {:ok, report} =
             Drill.run(Snapshot.open([drills]),
               replica_url: ctx.replica_url,
               ledger_dir: ctx.dbs,
               scratch_dir: ctx.scratch
             )

    assert report.drilled == nil
    assert report.compared_facts == 0
  end
end
