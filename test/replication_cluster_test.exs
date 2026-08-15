defmodule Blazie.ReplicationClusterTest do
  @moduledoc """
  The cluster half of replication: hydrate, evict, and the lease fence.

  Idle eviction is the World's: `evict_after:` closes a world nobody has
  talked to, keeping the file — open is hydrate, close is evict, exactly the
  lifecycle the storage plan gave the World layer. Disk-pressure eviction is
  `Replication.evict/3`: close AND delete the local file, refused unless the
  replica actually holds the world, because "R2 is truth" is a claim to
  check, not assume.

  The lease is the fence under both: two nodes must never both replicate one
  tenant prefix silently. This litestream build exposes no leasing config
  (probed before writing), so the fence is a LEASE object at the replica —
  exclusive-create on file://, refusal with the holder named. What is not
  enforced (s3:// conditional writes) is a warning and a verdict, not a
  pretence.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Replication, Snapshot, Store, World}

  @moduletag :litestream

  setup_all do
    case System.find_executable("litestream") do
      nil -> raise "litestream is not installed — run with --exclude litestream"
      _ -> :ok
    end

    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "repl_cl_#{System.unique_integer([:positive])}")
    dbs = Path.join(base, "ledgers")
    replica = Path.join(base, "replica")
    File.mkdir_p!(dbs)
    File.mkdir_p!(replica)
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      base: base,
      dbs: dbs,
      replica: replica,
      replica_url: "file://#{replica}",
      name: {:repl_cl, System.unique_integer([:positive])}
    }
  end

  defp await(fun, tries \\ 600, sleep \\ 50) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: {:cont, Process.sleep(sleep) && false}
    end)
  end

  describe "idle eviction" do
    test "a world idle past evict_after closes itself and keeps its file", ctx do
      {:ok, world} =
        World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs}, evict_after: 150)

      {:ok, _} = World.append(world, [{42, "height", 180}])
      assert ctx.name in World.open_worlds()

      # Nobody talks to it; it goes to sleep on its own.
      assert await(fn -> ctx.name not in World.open_worlds() end, 100),
             "the idle world never evicted itself"

      # The local file stays — idle eviction is close, not deletion.
      assert File.exists?(Path.join(ctx.dbs, Store.SQLite.filename(ctx.name)))

      # And reopening answers everything, which is what makes this eviction.
      {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
      on_exit(fn -> World.close(ctx.name) end)
      assert Snapshot.value(Snapshot.open([world]), 42, "height") == 180
    end

    test "activity keeps an evictable world awake", ctx do
      {:ok, world} =
        World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs}, evict_after: 200)

      on_exit(fn -> World.close(ctx.name) end)
      {:ok, _} = World.append(world, [{1, "x", 1}])

      # Read it more often than the idle clock; it must stay open throughout.
      for _ <- 1..8 do
        Process.sleep(100)
        assert World.tx(world) == 1
      end

      assert ctx.name in World.open_worlds()
    end
  end

  describe "disk-pressure eviction" do
    test "an evicted world reopens through restore_if_missing", ctx do
      replicator =
        start_supervised!(
          {Replication, dir: ctx.dbs, pattern: "*.sqlite", replica_url: ctx.replica_url}
        )

      {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
      {:ok, _} = World.append(world, [{42, "height", 180}])

      assert await(fn -> Replication.replicated?(ctx.name, ctx.replica_url) end),
             "the replicator never shipped the world"

      :ok = Replication.drain(replicator)

      # Disk pressure: close AND delete the local copy. R2 (here, file://)
      # is the truth now.
      assert :ok = Replication.evict(ctx.name, ctx.dbs, replica_url: ctx.replica_url)
      refute File.exists?(Path.join(ctx.dbs, Store.SQLite.filename(ctx.name)))
      refute ctx.name in World.open_worlds()

      # The round trip: cold open hydrates and answers.
      assert {:ok, :restored} =
               Replication.restore_if_missing(ctx.name,
                 dir: ctx.dbs,
                 replica_url: ctx.replica_url
               )

      {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
      on_exit(fn -> World.close(ctx.name) end)
      assert Snapshot.value(Snapshot.open([world]), 42, "height") == 180
    end

    test "a world the replica has never seen refuses to be evicted", ctx do
      {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
      on_exit(fn -> World.close(ctx.name) end)
      {:ok, _} = World.append(world, [{1, "x", 1}])

      assert {:error, refusal} =
               Replication.evict(ctx.name, ctx.dbs, replica_url: ctx.replica_url)

      assert refusal.problem == :replica_does_not_hold

      # Nothing closed, nothing deleted: the refusal protected the only copy.
      assert ctx.name in World.open_worlds()
      assert File.exists?(Path.join(ctx.dbs, Store.SQLite.filename(ctx.name)))
    end
  end

  describe "the lease fence" do
    test "a second node's replicator refuses a leased prefix, and drain frees it", ctx do
      # The refusal arrives as an abnormal init exit — in the tree the
      # supervisor traps it; here the test stands where the supervisor would.
      Process.flag(:trap_exit, true)

      {:ok, first} =
        Replication.start_link(
          dir: ctx.dbs,
          replica_url: ctx.replica_url,
          node_id: "node-a"
        )

      other_dbs = Path.join(ctx.base, "other-ledgers")
      File.mkdir_p!(other_dbs)

      # Same prefix, different node: refused, holder named.
      assert {:error, refusal} =
               Replication.start_link(
                 dir: other_dbs,
                 replica_url: ctx.replica_url,
                 node_id: "node-b"
               )

      assert refusal.problem == :lease_held
      assert refusal.repair =~ "node-a"

      # A drain is the deliberate end, and it releases the prefix.
      :ok = Replication.drain(first)
      refute File.exists?(Path.join(ctx.replica, "LEASE"))

      {:ok, second} =
        Replication.start_link(
          dir: other_dbs,
          replica_url: ctx.replica_url,
          node_id: "node-b"
        )

      :ok = Replication.drain(second)
    end

    test "a node retakes its own lease after a crash", ctx do
      # The lease a crashed replicator leaves behind names this node — and a
      # node is never fenced out by its own past self.
      File.write!(Path.join(ctx.replica, "LEASE"), "node-a\n0\n")

      {:ok, replicator} =
        Replication.start_link(
          dir: ctx.dbs,
          replica_url: ctx.replica_url,
          node_id: "node-a"
        )

      :ok = Replication.drain(replicator)
    end
  end
end
