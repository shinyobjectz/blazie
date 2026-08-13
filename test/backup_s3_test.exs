defmodule Blazie.BackupS3Test do
  @moduledoc """
  The backup against real object storage, over the real internet.

  Excluded by default and run with `--include object_storage`, because it needs
  a bucket and credentials. It exists because the directory target proves the
  logic and proves nothing about the protocol: SigV4 is signed by hand here, and
  a signature that is subtly wrong fails only against a real server.

  What it checks that the directory target cannot: that a request is accepted at
  all, that a missing key is distinguishable from a failure, and that a listing
  longer than one page comes back whole. The last one matters most — a
  paginated list that stops at the first page is a restore that stops with it,
  and a bucket does not reach a thousand segments until long after anyone would
  notice this test never ran.

      BACKUP_ENDPOINT=https://storage.googleapis.com \\
      BACKUP_BUCKET=... BACKUP_ACCESS_KEY_ID=... BACKUP_SECRET_ACCESS_KEY=... \\
        mix test --include object_storage
  """
  use ExUnit.Case, async: false

  @moduletag :object_storage

  alias Blazie.{Attribute, Backup, World, Snapshot, Store}

  setup_all do
    for var <- ~w(BACKUP_ENDPOINT BACKUP_BUCKET BACKUP_ACCESS_KEY_ID BACKUP_SECRET_ACCESS_KEY) do
      System.get_env(var) || raise "#{var} is not set, and this test talks to real storage."
    end

    :inets.start()
    :ssl.start()
    :ok
  end

  setup do
    # A prefix per run, so a failed run never poisons the next one and two
    # people running this at once do not collide.
    run = "test-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"

    target =
      {Backup.Target.S3,
       endpoint: System.fetch_env!("BACKUP_ENDPOINT"),
       bucket: System.fetch_env!("BACKUP_BUCKET"),
       region: System.get_env("BACKUP_REGION") || "auto",
       access_key_id: System.fetch_env!("BACKUP_ACCESS_KEY_ID"),
       secret_access_key: System.fetch_env!("BACKUP_SECRET_ACCESS_KEY"),
       prefix: run}

    root = Path.join(System.tmp_dir!(), "lr_s3_#{System.unique_integer([:positive])}")
    ledgers = Path.join(root, "ledgers")
    keys = Path.join(root, "keys")
    File.mkdir_p!(ledgers)
    File.mkdir_p!(keys)
    on_exit(fn -> File.rm_rf!(root) end)

    name = {:s3_test, System.unique_integer([:positive])}
    {:ok, world} = World.open(name, store: {Store.File, dir: ledgers})
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    {:ok, _} = World.append(world, [{"ada", "height", 180}])

    %{
      opts: [ledger_dir: ledgers, key_dir: keys, target: target],
      target: target,
      world: world,
      name: name,
      ledgers: ledgers,
      keys: keys
    }
  end

  describe "the protocol, which only a real server can judge" do
    test "a signed put, get, and list round-trip", %{target: {module, topts}} do
      assert :ok = module.put(topts, "probe/one.segment", "the river is lazy")
      assert {:ok, "the river is lazy"} = module.get(topts, "probe/one.segment")
      assert {:ok, keys} = module.list(topts, "probe/")
      assert "probe/one.segment" in keys
    end

    test "a key that is not there is missing, not broken", %{target: {module, topts}} do
      assert {:error, :missing} = module.get(topts, "probe/never-written")
    end

    test "a listing longer than one page comes back whole", %{target: {module, topts}} do
      for n <- 1..5, do: :ok = module.put(topts, "page/#{n}.segment", "body-#{n}")

      {:ok, one_page} = module.list(topts, "page/")
      {:ok, forced} = module.list(Keyword.put(topts, :page_size, 2), "page/")

      assert length(one_page) == 5
      assert forced == one_page
    end

    test "bad credentials are refused, not silently accepted", %{target: {module, topts}} do
      wrong = Keyword.put(topts, :secret_access_key, "not-the-secret")

      assert {:error, %{problem: :target_refused, status: status}} =
               module.put(wrong, "probe/nope.segment", "x")

      assert status in [400, 401, 403]
    end
  end

  describe "the whole thing, end to end" do
    test "facts survive losing the disk, over the internet", ctx do
      File.write!(Path.join(ctx.keys, "master.wrapped"), "wrapped-master-bytes")

      {:ok, first} = Backup.run(ctx.opts)
      assert first.copied_bytes > 0
      assert first.keys == 1

      {:ok, _} = World.append(ctx.world, [{"ada", "height", 181}])
      {:ok, second} = Backup.run(ctx.opts)
      assert second.copied_segments == 1

      assert {:ok, %{divergent: []}} = Backup.verify(ctx.opts)

      :ok = World.close(ctx.name)
      File.rm_rf!(ctx.ledgers)
      File.rm_rf!(ctx.keys)

      {:ok, restored} = Backup.restore(ctx.opts)
      assert restored.incomplete == []
      assert restored.keys == 1

      {:ok, again} = World.open(ctx.name, store: {Store.File, dir: ctx.ledgers})
      assert Snapshot.value(Snapshot.open([again]), "ada", "height") == 181
      assert File.read!(Path.join(ctx.keys, "master.wrapped")) == "wrapped-master-bytes"
    end
  end
end
