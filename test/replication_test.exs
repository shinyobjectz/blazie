defmodule Blazie.ReplicationTest do
  @moduledoc """
  The replicator: every tenant file streamed out, any tenant file restored in.

  Litestream in dir mode watches the ledger directory — a tenant file that
  APPEARS while the daemon runs starts replicating within seconds (probed on
  this binary before this test was written), which is the property the whole
  per-tenant-SQLite architecture rests on: worlds are created at runtime, and
  a replicator that needed a config rewrite per tenant would be an operational
  fight. The replica is the truth a node hydrates from: `restore_if_missing/2`
  is what `World.open` calls on a cold node.

  A local `file://` replica proves the lifecycle without a bucket, the same
  discipline `backup_s3_test` draws — the S3/R2 half is the same URL scheme
  swapped, tagged `:object_storage` when it needs real credentials. Skipped
  honestly when the binary is absent.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Job, Replication, Snapshot, Store, World}

  @moduletag :litestream

  setup_all do
    case System.find_executable("litestream") do
      nil -> raise "litestream is not installed — run with --exclude litestream"
      _ -> :ok
    end

    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "repl_#{System.unique_integer([:positive])}")
    dbs = Path.join(base, "ledgers")
    replica = Path.join(base, "replica")
    File.mkdir_p!(dbs)
    File.mkdir_p!(replica)
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      dbs: dbs,
      replica_url: "file://#{replica}",
      name: {:repl, System.unique_integer([:positive])}
    }
  end

  test "a world created at runtime replicates, and a cold node hydrates it", ctx do
    replicator =
      start_supervised!(
        {Replication, dir: ctx.dbs, pattern: "*.sqlite", replica_url: ctx.replica_url}
      )

    # The world is born AFTER the replicator started — the dynamic case.
    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    {:ok, _} = World.append(world, [{42, "height", 180}])
    :ok = World.close(ctx.name)

    # "Within seconds" is the claim — wait for the watch to discover the new
    # file and ship it, then drain. A daemon that never ships fails here with
    # a clear name, not downstream.
    replica_path = ctx.replica_url |> String.replace_prefix("file://", "")
    shipped = Path.join(replica_path, Store.SQLite.filename(ctx.name))

    assert Enum.reduce_while(1..600, false, fn _, _ ->
             if File.exists?(shipped),
               do: {:halt, true},
               else: {:cont, Process.sleep(50) && false}
           end),
           "the replicator never shipped the runtime-created world"

    # Drain: a deliberate stop flushes what is in flight (deploys reset
    # in-flight work — our own ground rule, wired in rather than remembered).
    :ok = Replication.drain(replicator)

    # The "node dies": the local file is gone entirely.
    File.rm_rf!(ctx.dbs)
    File.mkdir_p!(ctx.dbs)

    # A cold open hydrates from the replica first.
    assert {:ok, :restored} =
             Replication.restore_if_missing(ctx.name, dir: ctx.dbs, replica_url: ctx.replica_url)

    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    on_exit(fn -> World.close(ctx.name) end)
    assert Snapshot.value(Snapshot.open([world]), 42, "height") == 180
  end

  test "restore_if_missing is a no-op when the file is already here", ctx do
    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    {:ok, _} = World.append(world, [{1, "x", 1}])
    :ok = World.close(ctx.name)

    assert {:ok, :present} =
             Replication.restore_if_missing(ctx.name, dir: ctx.dbs, replica_url: ctx.replica_url)
  end

  test "the reading job reports replication state as facts", ctx do
    replicator =
      start_supervised!(
        {Replication, dir: ctx.dbs, pattern: "*.sqlite", replica_url: ctx.replica_url}
      )

    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    {:ok, local_tx} = World.append(world, [{42, "height", 180}, {42, "height", 181}])

    # Wait until the replica holds LTX for the world, then drain.
    assert Enum.reduce_while(1..600, false, fn _, _ ->
             if Replication.replicated?(ctx.name, ctx.replica_url),
               do: {:halt, true},
               else: {:cont, Process.sleep(50) && false}
           end),
           "the replicator never shipped the world"

    :ok = Replication.drain(replicator)
    :ok = World.close(ctx.name)

    # The job writes into whatever world its runner holds — the $backup world
    # in the tree, a scratch one here. Same shape either way.
    report = {:repl_report, System.unique_integer([:positive])}
    {:ok, reports} = World.open(report)
    on_exit(fn -> World.close(report) end)

    job = Replication.reading(dir: ctx.dbs, replica_url: ctx.replica_url)
    {:ok, _tx} = Job.run(job, reports, Snapshot.open([reports]), System.system_time(:second))

    snapshot = Snapshot.open([reports])

    # The fact's id is the world's NAME, decoded from the filename; local_tx
    # is the blazie transaction; replicated_ltx is litestream's own counter —
    # nonzero means shipped, and only replicated_at says how fresh.
    assert Snapshot.value(snapshot, ctx.name, "local_tx") == local_tx
    assert Snapshot.value(snapshot, ctx.name, "replicated_ltx") > 0

    assert_in_delta Snapshot.value(snapshot, ctx.name, "replicated_at"),
                    System.system_time(:second),
                    120
  end

  test "the reading is honest about a world the replica has never seen", ctx do
    # No replicator running at all: the local file exists, nothing shipped.
    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    {:ok, _} = World.append(world, [{1, "x", 1}])
    :ok = World.close(ctx.name)

    report = {:repl_report, System.unique_integer([:positive])}
    {:ok, reports} = World.open(report)
    on_exit(fn -> World.close(report) end)

    job = Replication.reading(dir: ctx.dbs, replica_url: ctx.replica_url)
    {:ok, _tx} = Job.run(job, reports, Snapshot.open([reports]), System.system_time(:second))

    snapshot = Snapshot.open([reports])
    assert Snapshot.value(snapshot, ctx.name, "local_tx") == 1
    assert Snapshot.value(snapshot, ctx.name, "replicated_ltx") == 0
    assert Snapshot.value(snapshot, ctx.name, "replicated_at") == nil
  end

  test "a name with neither file nor replica refuses with the repair", ctx do
    assert {:error, refusal} =
             Replication.restore_if_missing({:never, 1},
               dir: ctx.dbs,
               replica_url: ctx.replica_url
             )

    assert refusal.problem == :nothing_to_restore
    assert refusal.repair =~ "replica"
  end
end
