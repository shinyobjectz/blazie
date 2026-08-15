defmodule Blazie.ReplicationS3Test do
  @moduledoc """
  The replicator against real object storage, over the real internet.

  Excluded by default and run with `--include object_storage`, because it
  needs a bucket and credentials — the same discipline as `backup_s3_test`.
  The `file://` half of the lifecycle is proven in `replication_test`; what
  only a real server can judge is the S3 protocol litestream speaks to R2:
  that a runtime-created world ships at all, and that a wiped node hydrates
  it back through `restore_if_missing/2`.

  litestream reads its S3 credentials from the environment
  (`LITESTREAM_ACCESS_KEY_ID` / `LITESTREAM_SECRET_ACCESS_KEY`), and a
  non-AWS endpoint rides the URL in litestream's own bucket.host form:

      REPLICA_ENDPOINT=https://<account>.r2.cloudflarestorage.com \\
      REPLICA_BUCKET=... \\
      LITESTREAM_ACCESS_KEY_ID=... LITESTREAM_SECRET_ACCESS_KEY=... \\
        mix test --include object_storage test/replication_s3_test.exs
  """
  use ExUnit.Case, async: false

  alias Blazie.{Replication, Snapshot, Store, World}

  @moduletag :object_storage

  setup_all do
    for var <-
          ~w(REPLICA_BUCKET REPLICA_ENDPOINT LITESTREAM_ACCESS_KEY_ID LITESTREAM_SECRET_ACCESS_KEY) do
      System.get_env(var) || raise "#{var} is not set, and this test talks to real storage."
    end

    case System.find_executable("litestream") do
      nil -> raise "litestream is not installed — run with --exclude object_storage"
      _ -> :ok
    end

    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "repl_s3_#{System.unique_integer([:positive])}")
    dbs = Path.join(base, "ledgers")
    File.mkdir_p!(dbs)
    on_exit(fn -> File.rm_rf!(base) end)

    # A prefix per run, so a failed run never poisons the next one and two
    # people running this at once do not collide. Not cleaned up — an R2
    # lifecycle rule on the test bucket is the janitor, the same trade the
    # backup S3 test makes.
    run = "test-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"

    # litestream's URL form for a non-AWS endpoint: s3://BUCKET.HOST/PATH.
    host =
      System.fetch_env!("REPLICA_ENDPOINT")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("http://", "")
      |> String.trim_trailing("/")

    replica_url = "s3://#{System.fetch_env!("REPLICA_BUCKET")}.#{host}/#{run}"

    %{
      dbs: dbs,
      replica_url: replica_url,
      name: {:repl_s3, System.unique_integer([:positive])}
    }
  end

  test "the same lifecycle file:// proves, against the real bucket", ctx do
    replicator =
      start_supervised!(
        {Replication, dir: ctx.dbs, pattern: "*.sqlite", replica_url: ctx.replica_url}
      )

    # The world is born AFTER the replicator started — the dynamic case.
    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    {:ok, _} = World.append(world, [{42, "height", 180}])
    :ok = World.close(ctx.name)

    # Over the internet "within seconds" is slower than over a filesystem, so
    # the wait watches the replica itself — `replicated?/2` asks litestream,
    # which is the same question the drill asks.
    assert Enum.reduce_while(1..600, false, fn _, _ ->
             if Replication.replicated?(ctx.name, ctx.replica_url),
               do: {:halt, true},
               else: {:cont, Process.sleep(200) && false}
           end),
           "the replicator never shipped the runtime-created world to the bucket"

    :ok = Replication.drain(replicator)

    # The "node dies": the local file is gone entirely.
    File.rm_rf!(ctx.dbs)
    File.mkdir_p!(ctx.dbs)

    # A cold open hydrates from the bucket first.
    assert {:ok, :restored} =
             Replication.restore_if_missing(ctx.name, dir: ctx.dbs, replica_url: ctx.replica_url)

    {:ok, world} = World.open(ctx.name, store: {Store.SQLite, dir: ctx.dbs})
    on_exit(fn -> World.close(ctx.name) end)
    assert Snapshot.value(Snapshot.open([world]), 42, "height") == 180
  end

  test "a name the bucket never saw refuses with the repair", ctx do
    assert {:error, refusal} =
             Replication.restore_if_missing({:never_shipped, 1},
               dir: ctx.dbs,
               replica_url: ctx.replica_url
             )

    assert refusal.problem == :nothing_to_restore
  end
end
