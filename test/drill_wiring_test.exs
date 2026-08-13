defmodule Blazie.DrillWiringTest do
  @moduledoc """
  That the drill is actually *started*, and configured from the environment.

  The same test the deployment taught us to write for the backup, for the same
  reason and with one turn of the screw. Four components were built, tested,
  documented and never wired into the supervision tree, and every one of them
  looked finished. A restore drill is the worst possible fifth: it exists
  entirely to catch the case where something else is quietly not working, so a
  drill that never runs removes the only warning that a backup has stopped being
  restorable — while looking, from the outside, exactly like one that is passing.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Backup, Drill, Job, Ledger, Snapshot, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "lr_drill_wiring_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> Ledger.close(Drill.ledger()) end)

    %{
      root: root,
      ledgers: Path.join(root, "ledgers"),
      keys: Path.join(root, "keys"),
      remote: Path.join(root, "remote"),
      scratch: Path.join(root, "scratch")
    }
  end

  describe "the runner is a child, not a module somebody must remember" do
    test "starting it seeds its ledger and declares the job with a cadence", ctx do
      start_drill(ctx)

      assert Process.alive?(Process.whereis(Drill.Runner))

      {:ok, ledger} = Ledger.open(Drill.ledger())
      snapshot = Snapshot.open([ledger])

      assert Snapshot.value(snapshot, "drill", "is") == "job"
      assert Snapshot.value(snapshot, "drill", "every") == 21_600
      assert Job.due?(snapshot, "drill", 0)
    end

    test "and the runner has claimed the work, so it is not merely declared", ctx do
      start_drill(ctx)

      # Declared-but-unclaimed is how a job silently never runs. The runner
      # reports that gap rather than hiding it, and there must be no gap here.
      assert Job.Runner.unclaimed(Drill.Runner) == []
      assert {:ok, ["drill"]} = Job.Runner.tick(Drill.Runner, 1000)
    end

    test "a tick actually restores and proves, which is the only proof that counts", ctx do
      # Something file-backed for the backup to copy and the drill to give back.
      name = {:drill_wiring, System.unique_integer([:positive])}
      {:ok, ledger} = Ledger.open(name, store: {Store.File, dir: ctx.ledgers})
      on_exit(fn -> Ledger.close(name) end)
      {:ok, _} = Ledger.append(ledger, Attribute.seed())

      {:ok, _} =
        Backup.run(
          ledger_dir: ctx.ledgers,
          key_dir: ctx.keys,
          target: {Backup.Target.Directory, root: ctx.remote}
        )

      start_drill(ctx)
      {:ok, _} = Job.Runner.tick(Drill.Runner, 1000)

      # The tick starts a task; wait for the fact that says it finished.
      assert eventually(fn ->
               Snapshot.value(Snapshot.open([Ledger.via(Drill.ledger())]), "drill", "proven_at")
             end) > 0

      snapshot = Snapshot.open([Ledger.via(Drill.ledger())])
      assert Snapshot.value(snapshot, "drill", "drilled") == name
      assert Snapshot.value(snapshot, "drill", "restored_ledgers") == 1
      assert Snapshot.value(snapshot, "drill", "compared_facts") > 0

      # And it left nothing behind on the way: no scratch directory, and no
      # ledger name still held. Asserted here rather than beside the drill's own
      # tests because the registry is VM-wide and this file is the one that runs
      # on its own.
      assert File.ls!(ctx.scratch) == []
      refute Enum.any?(Ledger.open_ledgers(), &match?({Drill, :restored, _}, &1))
    end

    test "a drill that fails still leaves nothing open and nothing behind", ctx do
      name = {:drill_wiring_broken, System.unique_integer([:positive])}
      {:ok, ledger} = Ledger.open(name, store: {Store.File, dir: ctx.ledgers})
      on_exit(fn -> Ledger.close(name) end)
      {:ok, _} = Ledger.append(ledger, Attribute.seed())

      {:ok, _} =
        Backup.run(
          ledger_dir: ctx.ledgers,
          key_dir: ctx.keys,
          target: {Backup.Target.Directory, root: ctx.remote}
        )

      # Bytes that are not records. `0xFF` rather than zeros on purpose: a run of
      # zeros decodes as a valid empty record, and this has to be unreadable.
      {:ok, [segment]} = Backup.Target.Directory.list([root: ctx.remote], "ledgers/")
      path = Path.join(ctx.remote, segment)
      File.write!(path, :binary.copy(<<255>>, byte_size(File.read!(path))))

      start_drill(ctx)
      {:ok, _} = Job.Runner.tick(Drill.Runner, 1000)

      # The failure is a fact, not a crash and not a silence.
      assert eventually(fn ->
               case Job.failures(Snapshot.open([Ledger.via(Drill.ledger())]), "drill") do
                 [] -> nil
                 failures -> failures
               end
             end) != []

      assert Process.alive?(Process.whereis(Drill.Runner))
      assert File.ls!(ctx.scratch) == []
      refute Enum.any?(Ledger.open_ledgers(), &match?({Drill, :restored, _}, &1))
    end
  end

  describe "the tree starts it only when it is configured" do
    test "no target and no cadence means no drill, which is why test is quiet" do
      # Both conditions the tree checks, neither of them true here. This is the
      # running application's own answer, not a re-implementation of the guard.
      assert Application.get_env(:blazie, :backup_target) == nil
      assert Application.get_env(:blazie, :drill_every) == nil
      assert Process.whereis(Drill.Runner) == nil
    end
  end

  defp start_drill(ctx) do
    File.mkdir_p!(ctx.ledgers)
    File.mkdir_p!(ctx.scratch)

    start_supervised!(
      {Drill,
       every: 21_600,
       scratch_dir: ctx.scratch,
       target: {Backup.Target.Directory, root: ctx.remote}}
    )
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        eventually(fun, tries - 1)

      answer ->
        answer
    end
  end
end
