defmodule Blazie.StorageEventsTest do
  @moduledoc """
  Doctrine 20: a storage event is not a fact.

  Checkpoints, segment rotation and a backup run change bytes and change nothing
  anybody asked about. Nothing below the world may announce, and the world
  announces only what it appended.

  This is asserted rather than assumed because the failure is catastrophic and
  invisible until it is not. A search-index compaction at Convex — no logical
  data changed — took their largest customer from fifty to twenty thousand
  queries per second, and the clients reconnecting afterwards finished the job.
  A watcher that maintenance can wake is a system whose cost grows with its own
  housekeeping, and it grows fastest exactly when it is busiest.

  The structure makes this true today: checkpointing happens inside `Store.File`,
  which is below the world and holds no reference to the watcher registry, and
  the backup reads files without going through a world at all. That is an
  argument, not a proof — and it would survive exactly until somebody added a
  convenience announcement.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Backup, World, Store, Subscription}

  setup do
    root = Path.join(System.tmp_dir!(), "lr_events_#{System.unique_integer([:positive])}")
    ledgers = Path.join(root, "ledgers")
    keys = Path.join(root, "keys")
    File.mkdir_p!(ledgers)
    File.mkdir_p!(keys)
    on_exit(fn -> File.rm_rf!(root) end)

    name = {:events, System.unique_integer([:positive])}

    # A checkpoint every other transaction, so the run below crosses several.
    {:ok, world} =
      World.open(name, store: {Store.File, dir: ledgers, checkpoint_every: 2})

    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))

    %{
      world: world,
      name: name,
      ledgers: ledgers,
      opts: [
        ledger_dir: ledgers,
        key_dir: keys,
        target: {Backup.Target.Directory, root: Path.join(root, "remote")}
      ]
    }
  end

  defp drain(acc \\ 0) do
    receive do
      {:blazie, _ref, _answer} -> drain(acc + 1)
    after
      150 -> acc
    end
  end

  describe "a watcher wakes for appends and for nothing else" do
    test "a checkpoint is not an announcement", ctx do
      {:ok, _ref} = Subscription.watch([ctx.world], attribute: "height")
      drain()

      # Ten appends at checkpoint_every: 2 means several checkpoints are written
      # underneath. If one of them announced, the count would exceed the writes.
      for n <- 1..10, do: {:ok, _} = World.append(ctx.world, [{"ada", "height", n}])

      assert drain() == 10, "a watcher was woken more times than there were writes"

      # And the checkpoints really were written — otherwise this proves nothing.
      assert File.exists?(Path.join(ctx.ledgers, Store.File.filename(ctx.name)) <> ".checkpoint")
    end

    test "a backup run is not an announcement", ctx do
      for n <- 1..6, do: {:ok, _} = World.append(ctx.world, [{"ada", "height", n}])

      {:ok, _ref} = Subscription.watch([ctx.world], attribute: "height")
      drain()

      {:ok, report} = Backup.run(ctx.opts)
      assert report.copied_bytes > 0, "the backup copied nothing, so this proves nothing"

      assert drain() == 0, "a backup woke a watcher"
    end

    test "a second backup run, and a verify, are not announcements either", ctx do
      for n <- 1..6, do: {:ok, _} = World.append(ctx.world, [{"ada", "height", n}])
      {:ok, _} = Backup.run(ctx.opts)

      {:ok, _ref} = Subscription.watch([ctx.world], attribute: "height")
      drain()

      {:ok, _} = Backup.run(ctx.opts)
      {:ok, _} = Backup.verify(ctx.opts)
      {:ok, _} = World.append(ctx.world, [{"ada", "height", 99}])

      # Exactly one: the write. Not the backup, not the verify.
      assert drain() == 1
    end

    test "reading does not announce, however much of it there is", ctx do
      for n <- 1..6, do: {:ok, _} = World.append(ctx.world, [{"ada", "height", n}])

      {:ok, _ref} = Subscription.watch([ctx.world], attribute: "height")
      drain()

      tx = World.tx(ctx.world)
      for _ <- 1..50, do: World.find_at(ctx.world, tx, attribute: "height")
      for _ <- 1..50, do: World.facts_at(ctx.world, tx)

      assert drain() == 0, "a read woke a watcher"
    end
  end

  describe "the registry itself" do
    test "nothing below the world holds the watcher registry", _ctx do
      # The structural argument, made checkable. If a storage module ever learns
      # the name of the registry, this fails before the behaviour does.
      below = [
        "lib/blazie/store.ex",
        "lib/blazie/backup.ex",
        "lib/blazie/backup/target.ex",
        "lib/blazie/backup/target/s3.ex"
      ]

      for path <- below do
        refute File.read!(path) =~ "Watchers",
               "#{path} names the watcher registry, and nothing below the world may announce"
      end
    end
  end
end
