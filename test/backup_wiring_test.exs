defmodule Blazie.BackupWiringTest do
  @moduledoc """
  That the backup is actually *started*, and configured from the environment.

  This is the test the deployment taught us to write. Four separate components
  were built, tested, documented and never wired into the supervision tree, and
  every one of them looked finished — the ledger store, the formula engine, the
  job runner, and vitals. A backup is the worst possible member of that set: it
  is invisible when it does nothing, and the day you find out is the day the
  disk is already gone.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Backup, Job, Ledger, Snapshot}

  describe "the runner is a child, not a module somebody must remember" do
    setup do
      root = Path.join(System.tmp_dir!(), "lr_wiring_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      on_exit(fn -> Ledger.close(Backup.ledger()) end)

      %{root: root}
    end

    test "starting it seeds its ledger and declares the job with a cadence", ctx do
      start_supervised!(
        {Backup,
         every: 900,
         ledger_dir: Path.join(ctx.root, "ledgers"),
         key_dir: Path.join(ctx.root, "keys"),
         target: {Backup.Target.Directory, root: Path.join(ctx.root, "remote")}}
      )

      assert Process.alive?(Process.whereis(Backup.Runner))

      {:ok, ledger} = Ledger.open(Backup.ledger())
      snapshot = Snapshot.open([ledger])

      assert Snapshot.value(snapshot, "backup", "is") == "job"
      assert Snapshot.value(snapshot, "backup", "every") == 900
      assert Job.due?(snapshot, "backup", 0)
    end

    test "and the runner has claimed the work, so it is not merely declared", ctx do
      start_supervised!(
        {Backup,
         every: 900,
         ledger_dir: Path.join(ctx.root, "ledgers"),
         key_dir: Path.join(ctx.root, "keys"),
         target: {Backup.Target.Directory, root: Path.join(ctx.root, "remote")}}
      )

      # Declared-but-unclaimed is how a job silently never runs. The runner
      # reports that gap rather than hiding it, and there must be no gap here.
      assert Job.Runner.unclaimed(Backup.Runner) == []
      assert {:ok, ["backup"]} = Job.Runner.tick(Backup.Runner, 1000)
    end

    test "a tick actually copies, which is the only proof that counts", ctx do
      ledgers = Path.join(ctx.root, "ledgers")
      remote = Path.join(ctx.root, "remote")

      start_supervised!(
        {Backup,
         every: 900,
         ledger_dir: ledgers,
         key_dir: Path.join(ctx.root, "keys"),
         target: {Backup.Target.Directory, root: remote}}
      )

      # The backup's own ledger is in memory here, so give it a file-backed one
      # to find.
      name = {:wiring, System.unique_integer([:positive])}
      {:ok, ledger} = Ledger.open(name, store: {Blazie.Store.File, dir: ledgers})
      on_exit(fn -> Ledger.close(name) end)
      {:ok, _} = Ledger.append(ledger, Blazie.Attribute.seed())

      {:ok, _} = Job.Runner.tick(Backup.Runner, 1000)

      # The tick starts a task; wait for the fact that says it finished.
      assert eventually(fn ->
               Snapshot.value(
                 Snapshot.open([Ledger.via(Backup.ledger())]),
                 "backup",
                 "copied_bytes"
               )
             end) > 0

      assert Backup.held(
               [ledger_dir: ledgers, target: {Backup.Target.Directory, root: remote}],
               name
             ) > 0
    end
  end

  describe "the target comes from the environment" do
    setup do
      was = Application.get_env(:blazie, :backup_target)

      on_exit(fn ->
        if was,
          do: Application.put_env(:blazie, :backup_target, was),
          else: Application.delete_env(:blazie, :backup_target)
      end)
    end

    test "run refuses rather than guessing when nothing is configured" do
      Application.delete_env(:blazie, :backup_target)

      assert_raise RuntimeError, ~r/No backup target/, fn -> Backup.run(ledger_dir: "/tmp") end
    end

    test "a configured target is used without being passed" do
      root = Path.join(System.tmp_dir!(), "lr_env_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)

      Application.put_env(
        :blazie,
        :backup_target,
        {Backup.Target.Directory, root: Path.join(root, "remote")}
      )

      ledgers = Path.join(root, "ledgers")
      File.mkdir_p!(ledgers)

      assert {:ok, report} = Backup.run(ledger_dir: ledgers, key_dir: Path.join(root, "keys"))
      assert report.ledgers == 0
    end
  end

  defp eventually(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        eventually(fun, tries - 1)

      answer ->
        answer
    end
  end
end
