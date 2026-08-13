defmodule LazyRiver.BackupTest do
  @moduledoc """
  A backup is a job, and a backup nobody has restored is a rumour.

  Copying bytes somewhere is the easy half and the half that proves nothing, so
  most of what is here is the other half: delete the originals, pull them back,
  and ask the ledger the same questions. If that does not hold, the rest is
  theatre.

  Two properties do the work. A ledger is append-only, so a backup only ever
  copies bytes it has not copied — the cost is what changed, not what exists.
  And a copy stops at the last complete record, because the tail of a live log
  may be half-written and half a record is not a fact.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Backup, Ledger, Snapshot, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "lr_backup_#{System.unique_integer([:positive])}")
    ledgers = Path.join(root, "ledgers")
    keys = Path.join(root, "keys")
    remote = Path.join(root, "remote")

    File.mkdir_p!(ledgers)
    File.mkdir_p!(keys)
    on_exit(fn -> File.rm_rf!(root) end)

    name = {:backup_test, System.unique_integer([:positive])}
    {:ok, ledger} = Ledger.open(name, store: {Store.File, dir: ledgers})
    on_exit(fn -> Ledger.close(name) end)

    {:ok, _} = Ledger.append(ledger, Attribute.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
    {:ok, _} = Ledger.append(ledger, [{"ada", "height", 180}])

    opts = [
      ledger_dir: ledgers,
      key_dir: keys,
      target: {Backup.Target.Directory, root: remote}
    ]

    %{opts: opts, ledger: ledger, name: name, ledgers: ledgers, keys: keys, remote: remote}
  end

  describe "the round trip, which is the only thing that matters" do
    test "facts survive losing the disk they lived on", ctx do
      {:ok, _report} = Backup.run(ctx.opts)

      # The disk is gone. Not the process — the bytes.
      :ok = Ledger.close(ctx.name)
      File.rm_rf!(ctx.ledgers)

      {:ok, restored} = Backup.restore(ctx.opts)
      assert restored.ledgers == 1

      {:ok, again} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.ledgers})
      assert Snapshot.value(Snapshot.open([again]), "ada", "height") == 180
    end

    test "a restore brings back every ledger, not the one you thought of", ctx do
      second = {:backup_test_b, System.unique_integer([:positive])}
      {:ok, other} = Ledger.open(second, store: {Store.File, dir: ctx.ledgers})
      on_exit(fn -> Ledger.close(second) end)
      {:ok, _} = Ledger.append(other, Attribute.seed())
      {:ok, _} = Ledger.append(other, Attribute.define("depth", answers: "integer"))
      {:ok, _} = Ledger.append(other, [{"trench", "depth", 10_994}])

      {:ok, report} = Backup.run(ctx.opts)
      assert report.ledgers == 2

      :ok = Ledger.close(ctx.name)
      :ok = Ledger.close(second)
      File.rm_rf!(ctx.ledgers)

      {:ok, _} = Backup.restore(ctx.opts)

      {:ok, a} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.ledgers})
      {:ok, b} = Ledger.open(second, store: {Store.File, dir: ctx.ledgers})

      assert Snapshot.value(Snapshot.open([a]), "ada", "height") == 180
      assert Snapshot.value(Snapshot.open([b]), "trench", "depth") == 10_994
    end

    test "a restore refuses to overwrite facts that are already there", ctx do
      {:ok, _} = Backup.run(ctx.opts)

      assert {:error, refusal} = Backup.restore(ctx.opts)
      assert refusal.problem == :would_overwrite
      assert refusal.repair =~ "empty"
    end
  end

  describe "only what changed crosses the wire" do
    test "a second run with nothing new copies nothing", ctx do
      {:ok, first} = Backup.run(ctx.opts)
      assert first.copied_bytes > 0

      {:ok, second} = Backup.run(ctx.opts)
      assert second.copied_bytes == 0
      assert second.copied_segments == 0
    end

    test "a run after an append copies only the append", ctx do
      {:ok, _} = Backup.run(ctx.opts)
      {:ok, _} = Ledger.append(ctx.ledger, [{"ada", "height", 181}])

      {:ok, second} = Backup.run(ctx.opts)

      assert second.copied_segments == 1
      # One transaction's record, not the whole log.
      assert second.copied_bytes < File.stat!(ledger_path(ctx)).size
    end

    test "the segments concatenate back to the file they came from", ctx do
      {:ok, _} = Backup.run(ctx.opts)
      {:ok, _} = Ledger.append(ctx.ledger, [{"ada", "height", 181}])
      {:ok, _} = Ledger.append(ctx.ledger, [{"ada", "height", 182}])
      {:ok, _} = Backup.run(ctx.opts)

      original = File.read!(ledger_path(ctx))

      :ok = Ledger.close(ctx.name)
      File.rm_rf!(ctx.ledgers)
      {:ok, _} = Backup.restore(ctx.opts)

      assert File.read!(ledger_path(ctx)) == original
    end
  end

  describe "half a record is not a fact" do
    test "a torn tail is not copied", ctx do
      {:ok, first} = Backup.run(ctx.opts)

      # A record header promising far more than follows: what a process killed
      # mid-write leaves behind.
      File.write!(ledger_path(ctx), <<9999::32, 0::32, "not all here">>, [:append])

      {:ok, second} = Backup.run(ctx.opts)

      assert second.copied_bytes == 0
      assert Backup.held(ctx.opts, ctx.name) == first.copied_bytes
    end

    test "what was copied is what a restore could have used anyway", ctx do
      File.write!(ledger_path(ctx), <<9999::32, 0::32, "not all here">>, [:append])
      {:ok, _} = Backup.run(ctx.opts)

      # The local log is already unreadable past the tear — a scan stops there.
      # So the restored copy answers exactly what the original answers.
      before = Snapshot.value(Snapshot.open([ctx.ledger]), "ada", "height")

      :ok = Ledger.close(ctx.name)
      File.rm_rf!(ctx.ledgers)
      {:ok, _} = Backup.restore(ctx.opts)

      {:ok, again} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.ledgers})
      assert Snapshot.value(Snapshot.open([again]), "ada", "height") == before
    end
  end

  describe "what is not copied, and why" do
    test "checkpoints stay behind, because they can be rebuilt", ctx do
      checkpoint = ledger_path(ctx) <> ".checkpoint"
      File.write!(checkpoint, "pretend this is a checkpoint")

      {:ok, _} = Backup.run(ctx.opts)
      {:ok, held} = Backup.Target.Directory.list([root: ctx.remote], "")

      refute Enum.any?(held, &String.contains?(&1, "checkpoint"))
    end

    test "a ledger restored without its checkpoint still answers", ctx do
      {:ok, _} = Backup.run(ctx.opts)
      :ok = Ledger.close(ctx.name)
      File.rm_rf!(ctx.ledgers)
      {:ok, _} = Backup.restore(ctx.opts)

      {:ok, again} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.ledgers})
      assert Snapshot.value(Snapshot.open([again]), "ada", "height") == 180
    end
  end

  describe "keys travel too, because facts without them are noise" do
    setup ctx do
      File.write!(Path.join(ctx.keys, "master.wrapped"), "wrapped-master-bytes")
      File.write!(Path.join(ctx.keys, "subjects.keys"), "sealed-subject-keys")
      :ok
    end

    test "the key store is copied whole", ctx do
      {:ok, report} = Backup.run(ctx.opts)

      assert report.keys == 2
    end

    test "and comes back byte for byte", ctx do
      {:ok, _} = Backup.run(ctx.opts)
      File.rm_rf!(ctx.keys)

      # Only the keys: the facts are fine, and restoring a lost key store is a
      # different operation from restoring a machine.
      {:ok, _} = Backup.restore(Keyword.put(ctx.opts, :only, :keys))

      assert File.read!(Path.join(ctx.keys, "master.wrapped")) == "wrapped-master-bytes"
      assert File.read!(Path.join(ctx.keys, "subjects.keys")) == "sealed-subject-keys"
    end

    test "a rewritten key store replaces its copy rather than accumulating", ctx do
      {:ok, _} = Backup.run(ctx.opts)
      File.write!(Path.join(ctx.keys, "subjects.keys"), "after-an-erasure")
      {:ok, _} = Backup.run(ctx.opts)

      File.rm_rf!(ctx.keys)
      {:ok, _} = Backup.restore(Keyword.put(ctx.opts, :only, :keys))

      assert File.read!(Path.join(ctx.keys, "subjects.keys")) == "after-an-erasure"
    end
  end

  describe "it is a job, with everything that follows" do
    setup ctx do
      journal = {:backup_journal, System.unique_integer([:positive])}
      {:ok, ledger} = Ledger.open(journal)
      on_exit(fn -> Ledger.close(journal) end)

      {:ok, _} =
        Ledger.append(ledger, Attribute.seed() ++ LazyRiver.Job.seed() ++ Backup.seed())

      %{journal: ledger, opts: ctx.opts}
    end

    test "running it writes what it copied, naming itself", ctx do
      {:ok, tx} =
        LazyRiver.Job.run(
          Backup.job(ctx.opts),
          ctx.journal,
          Snapshot.open([ctx.journal]),
          1000
        )

      written = Ledger.facts_at(ctx.journal, tx) |> Enum.filter(&(&1.tx == tx))

      assert written != []
      assert Enum.all?(written, &(&1.by == "backup"))

      snapshot = Snapshot.open([ctx.journal])
      assert Snapshot.value(snapshot, "backup", "copied_bytes") > 0
      assert Snapshot.value(snapshot, "backup", "held_ledgers") == 1
    end

    test "it has a cadence and the runner picks it up", ctx do
      {:ok, _} = Ledger.append(ctx.journal, Backup.declare(every: 900))

      assert LazyRiver.Job.due?(Snapshot.open([ctx.journal]), "backup", 0)

      runner =
        start_supervised!(
          {LazyRiver.Job.Runner,
           ledger: ctx.journal,
           jobs: [Backup.job(ctx.opts)],
           name: :"backup_#{System.unique_integer([:positive])}"}
        )

      assert {:ok, ["backup"]} = LazyRiver.Job.Runner.tick(runner, 1000)
    end

    test "a target that refuses is recorded, not raised", ctx do
      # A regular file where a directory has to go: the same refusal on every
      # platform, unlike a path that happens to need root.
      wall = Path.join(System.tmp_dir!(), "lr_wall_#{System.unique_integer([:positive])}")
      File.write!(wall, "not a directory")
      on_exit(fn -> File.rm_rf!(wall) end)

      broken = Keyword.put(ctx.opts, :target, {Backup.Target.Directory, root: wall})

      assert {:failed, _tx, reason} =
               LazyRiver.Job.run(
                 Backup.job(broken),
                 ctx.journal,
                 Snapshot.open([ctx.journal]),
                 1000
               )

      assert reason =~ "backup"
      assert LazyRiver.Job.failures(Snapshot.open([ctx.journal]), "backup") != []
      # A job that failed still ran, and the ledger says so.
      assert LazyRiver.Job.last_run(Snapshot.open([ctx.journal]), "backup") == 1000
    end
  end

  describe "copying a ledger that is being written to" do
    # The only condition production ever runs in. A run reads a file another
    # process is appending to, so the boundary it copies up to is a moving
    # target — and the thing that must hold is that every boundary it picks is
    # a record boundary, whatever landed while it was reading.
    test "a restore answers everything the original does", ctx do
      writer =
        Task.async(fn ->
          Enum.each(1..200, fn n ->
            {:ok, _} = Ledger.append(ctx.ledger, [{"ada", "height", n}])
          end)
        end)

      backups =
        Task.async(fn ->
          Enum.map(1..40, fn _ ->
            {:ok, report} = Backup.run(ctx.opts)
            report.copied_bytes
          end)
        end)

      Task.await(writer, 30_000)
      copied = Task.await(backups, 30_000)

      # A final run to catch whatever landed after the last one.
      {:ok, _} = Backup.run(ctx.opts)

      assert Enum.sum(copied) > 0
      assert {:ok, %{divergent: []}} = Backup.verify(ctx.opts)

      before = Snapshot.find(Snapshot.open([ctx.ledger]), id: "ada", attribute: "height")

      :ok = Ledger.close(ctx.name)
      File.rm_rf!(ctx.ledgers)
      {:ok, restored} = Backup.restore(ctx.opts)
      assert restored.incomplete == []

      {:ok, again} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.ledgers})
      after_ = Snapshot.find(Snapshot.open([again]), id: "ada", attribute: "height")

      assert length(after_) == length(before)
      assert Enum.map(after_, & &1.value) == Enum.map(before, & &1.value)
    end

    test "no segment ever starts anywhere but where the last one stopped", ctx do
      writer =
        Task.async(fn ->
          Enum.each(1..100, fn n ->
            {:ok, _} = Ledger.append(ctx.ledger, [{"ada", "height", n}])
          end)
        end)

      Enum.each(1..30, fn _ -> {:ok, _} = Backup.run(ctx.opts) end)
      Task.await(writer, 30_000)
      {:ok, _} = Backup.run(ctx.opts)

      {:ok, keys} = Backup.Target.Directory.list([root: ctx.remote], "ledgers/")

      ranges =
        keys
        |> Enum.map(fn key ->
          [from, to] =
            key
            |> Path.basename(".segment")
            |> String.split("-")
            |> Enum.map(&String.to_integer/1)

          {from, to}
        end)
        |> Enum.sort()

      # More than one, or the writer finished before a single copy started and
      # this proved nothing about interleaving.
      assert length(ranges) > 1

      Enum.reduce(ranges, 0, fn {from, to}, at ->
        assert from == at,
               "segment #{from}-#{to} does not start where the last one stopped (#{at})"

        to
      end)
    end
  end

  describe "a hole in the segments" do
    # A put that failed after a later one succeeded, or a lifecycle rule that
    # expired an old segment. Either way the bytes after the hole cannot be
    # read — a scan stops at the garbage where the missing segment should be —
    # so the only safe answers are to stop there, say so, and re-copy.
    setup ctx do
      {:ok, _} = Backup.run(ctx.opts)
      {:ok, _} = Ledger.append(ctx.ledger, [{"ada", "height", 181}])
      {:ok, _} = Backup.run(ctx.opts)
      {:ok, _} = Ledger.append(ctx.ledger, [{"ada", "height", 182}])
      {:ok, _} = Backup.run(ctx.opts)

      {:ok, segments} = Backup.Target.Directory.list([root: ctx.remote], "ledgers/")
      assert length(segments) == 3

      # Punch out the middle one.
      middle = Enum.sort_by(segments, &segment_from/1) |> Enum.at(1)
      File.rm!(Path.join(ctx.remote, middle))

      %{gone: middle}
    end

    test "is not reported as bytes we can give back", ctx do
      first_segment_end = Backup.held(ctx.opts, ctx.name)

      # Not the highest boundary of the three: the contiguous run from zero.
      assert first_segment_end > 0
      assert first_segment_end < File.stat!(ledger_path(ctx)).size
    end

    test "makes the next run re-copy from the hole, healing it", ctx do
      {:ok, report} = Backup.run(ctx.opts)
      assert report.copied_bytes > 0

      assert {:ok, verified} = Backup.verify(ctx.opts)
      assert verified.divergent == []
    end

    test "a restore stops at it rather than gluing across it", ctx do
      :ok = Ledger.close(ctx.name)
      File.rm_rf!(ctx.ledgers)

      {:ok, restored} = Backup.restore(ctx.opts)

      assert restored.incomplete != []
      # What did come back is whole records, so it still opens and answers.
      {:ok, again} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.ledgers})
      assert Snapshot.value(Snapshot.open([again]), "ada", "height") == 180
    end

    test "and a whole restore says nothing was incomplete", ctx do
      {:ok, _} = Backup.run(ctx.opts)
      :ok = Ledger.close(ctx.name)
      File.rm_rf!(ctx.ledgers)

      {:ok, restored} = Backup.restore(ctx.opts)

      assert restored.incomplete == []
      {:ok, again} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.ledgers})
      assert Snapshot.value(Snapshot.open([again]), "ada", "height") == 182
    end
  end

  describe "verifying, because a copy nobody checked is a hope" do
    test "it agrees when the copy is whole", ctx do
      {:ok, _} = Backup.run(ctx.opts)

      assert {:ok, report} = Backup.verify(ctx.opts)
      assert report.divergent == []
      assert report.ledgers == 1
    end

    test "it names a ledger the copy is behind on", ctx do
      {:ok, _} = Backup.run(ctx.opts)
      {:ok, _} = Ledger.append(ctx.ledger, [{"ada", "height", 181}])

      assert {:ok, report} = Backup.verify(ctx.opts)
      assert [%{ledger: _, local: local, held: held}] = report.divergent
      assert local > held
    end

    test "it names a ledger with no copy at all", ctx do
      {:ok, _} = Backup.run(ctx.opts)

      later = {:backup_test_c, System.unique_integer([:positive])}
      {:ok, fresh} = Ledger.open(later, store: {Store.File, dir: ctx.ledgers})
      on_exit(fn -> Ledger.close(later) end)
      {:ok, _} = Ledger.append(fresh, Attribute.seed())

      assert {:ok, report} = Backup.verify(ctx.opts)
      assert [%{held: 0}] = report.divergent
    end
  end

  defp ledger_path(ctx), do: Path.join(ctx.ledgers, Store.File.filename(ctx.name))

  defp segment_from(key) do
    key |> Path.basename(".segment") |> String.split("-") |> hd() |> String.to_integer()
  end
end
