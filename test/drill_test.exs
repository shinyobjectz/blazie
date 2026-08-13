defmodule LazyRiver.DrillTest.Unreachable do
  @moduledoc "A target that answers nothing, which is what a wrong credential looks like."

  @behaviour LazyRiver.Backup.Target

  @impl true
  def put(_opts, _key, _bytes), do: {:error, :unreachable}

  @impl true
  def get(_opts, _key), do: {:error, :unreachable}

  @impl true
  def list(_opts, _prefix), do: {:error, :unreachable}
end

defmodule LazyRiver.DrillTest do
  @moduledoc """
  A backup is only ever proven by the last restore, so the restore is a job.

  Most of what is here is about the two ways a drill lies. It lies if it opens
  the copy under the live ledger's name, because `Ledger.open/2` hands back the
  ledger already open under a name — the drill would then compare the live
  ledger against itself and pass forever. And it lies if it compares byte counts
  rather than answers, because a broken restore has byte counts.

  So the assertions that matter are: that the copy is opened under a name of its
  own, that the question is asked of both and the answers are equal *at the
  restored transaction*, and that a copy which cannot answer becomes a fact
  rather than a crash.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Backup, Drill, Fact, Job, Ledger, Snapshot, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "lr_drill_#{System.unique_integer([:positive])}")
    ledgers = Path.join(root, "ledgers")
    keys = Path.join(root, "keys")
    remote = Path.join(root, "remote")
    scratch = Path.join(root, "scratch")

    Enum.each([ledgers, keys, remote, scratch], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(root) end)

    name = {:drill_test, System.unique_integer([:positive])}
    {:ok, live} = Ledger.open(name, store: {Store.File, dir: ledgers})
    on_exit(fn -> Ledger.close(name) end)

    {:ok, _} = Ledger.append(live, Attribute.seed())
    {:ok, _} = Ledger.append(live, Attribute.define("height", answers: "integer"))
    {:ok, _} = Ledger.append(live, [{"ada", "height", 180}])

    backup = [ledger_dir: ledgers, key_dir: keys, target: {Backup.Target.Directory, root: remote}]
    {:ok, _} = Backup.run(backup)

    # The drill is told the target and somewhere disposable to stage into, and
    # nothing else. It is never told where the live ledgers are, because it must
    # never go there.
    opts = [target: {Backup.Target.Directory, root: remote}, scratch_dir: scratch]

    journal = {:drill_journal, System.unique_integer([:positive])}
    {:ok, journal_ref} = Ledger.open(journal)
    on_exit(fn -> Ledger.close(journal) end)
    {:ok, _} = Ledger.append(journal_ref, Attribute.seed() ++ Job.seed() ++ Drill.seed())

    %{
      opts: opts,
      backup: backup,
      live: live,
      name: name,
      journal: journal_ref,
      ledgers: ledgers,
      keys: keys,
      remote: remote,
      scratch: scratch
    }
  end

  describe "the drill, which is the only thing that proves a backup" do
    test "it restores, opens what it came back with, and gets the same answers", ctx do
      {:ok, report} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)

      assert report.ledgers == 1
      assert report.drilled == ctx.name
      assert report.proven_tx == Ledger.tx(ctx.live)
      assert report.compared_facts == length(Ledger.find_at(ctx.live, Ledger.tx(ctx.live), []))
      assert report.took_ms >= 0
    end

    test "it compares at the restored transaction, so ordinary lag is not a failure", ctx do
      # The live ledger moves on after the copy was taken, which is the only
      # state production is ever in. What must hold is that the copy answers at
      # its own transaction what the original answers at that transaction.
      {:ok, _} = Ledger.append(ctx.live, [{"ada", "height", 181}])
      {:ok, _} = Ledger.append(ctx.live, [{"ada", "height", 182}])

      {:ok, report} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)

      assert report.proven_tx == 3
      assert report.proven_tx < Ledger.tx(ctx.live)
    end

    test "the copy is opened under a name of its own, never the live one", ctx do
      live_pid = GenServer.whereis(Ledger.via(ctx.name))

      {:ok, report} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)
      assert report.drilled == ctx.name

      # The bug this whole module has to avoid: `Ledger.open/2` hands back the
      # ledger already open under a name, so a drill that opened the copy as
      # `ctx.name` would have compared the live ledger against itself.
      assert GenServer.whereis(Ledger.via(ctx.name)) == live_pid
      assert Snapshot.value(Snapshot.open([ctx.live]), "ada", "height") == 180
    end

    test "it leaves the live ledgers and the live keys alone", ctx do
      before = File.ls!(ctx.ledgers)

      {:ok, _} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)

      assert File.ls!(ctx.ledgers) == before
      # `only: :ledgers` means restore does not so much as create a key
      # directory, let alone write one.
      assert File.ls!(ctx.keys) == []
    end

    test "it clears up after itself", ctx do
      {:ok, _} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)

      assert File.ls!(ctx.scratch) == []
    end
  end

  describe "a backup that cannot be given back" do
    test "a copy that opens at nothing is a refusal, not an answer", ctx do
      corrupt(ctx.remote)

      assert {:error, refusal} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)
      assert refusal.problem == :restored_nothing
      assert refusal.repair =~ "transaction 0"
    end

    test "a copy that answers something else is a refusal", ctx do
      substitute(ctx.remote, [%Fact{id: "ada", attribute: "height", value: 999, tx: 1}])

      assert {:error, refusal} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)
      assert refusal.problem == :answers_differently
      assert refusal.live_facts != refusal.restored_facts
      assert refusal.repair =~ "Do not trust this backup"
    end

    test "a hole in the segments is a refusal, because a prefix is not the ledger", ctx do
      {:ok, _} = Ledger.append(ctx.live, [{"ada", "height", 181}])
      {:ok, _} = Backup.run(ctx.backup)
      {:ok, _} = Ledger.append(ctx.live, [{"ada", "height", 182}])
      {:ok, _} = Backup.run(ctx.backup)

      # Punch out the middle one: a put that failed after a later one succeeded,
      # or a lifecycle rule that expired a segment.
      {:ok, segments} = Backup.Target.Directory.list([root: ctx.remote], "ledgers/")
      assert length(segments) == 3
      middle = segments |> Enum.sort_by(&segment_from/1) |> Enum.at(1)
      File.rm!(Path.join(ctx.remote, middle))

      assert {:error, refusal} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)
      assert refusal.problem == :incomplete
      assert refusal.repair =~ "re-copies from the hole"
    end

    test "a target nobody can list fails with a repair, not a match error", ctx do
      opts = Keyword.put(ctx.opts, :target, {LazyRiver.DrillTest.Unreachable, []})

      assert {:failed, _tx, reason} =
               Job.run(Drill.job(opts), ctx.journal, Snapshot.open([ctx.journal]), 1000)

      assert reason =~ "could not be listed"
      assert reason =~ "reachable from this node"
    end

    test "and it clears up after a failure too", ctx do
      corrupt(ctx.remote)

      assert {:error, _} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)

      assert File.ls!(ctx.scratch) == []
    end
  end

  describe "it is a job, with everything that follows" do
    test "running it writes what it proved, naming itself", ctx do
      {:ok, tx} = Job.run(Drill.job(ctx.opts), ctx.journal, Snapshot.open([ctx.journal]), 1000)

      written = Ledger.facts_at(ctx.journal, tx) |> Enum.filter(&(&1.tx == tx))
      assert written != []
      assert Enum.all?(written, &(&1.by == "drill"))

      snapshot = Snapshot.open([ctx.journal])
      assert Snapshot.value(snapshot, "drill", "drilled") == ctx.name
      assert Snapshot.value(snapshot, "drill", "restored_ledgers") == 1
      assert Snapshot.value(snapshot, "drill", "compared_facts") > 0
      assert Snapshot.value(snapshot, "drill", "proven_tx") == 3
      assert is_integer(Snapshot.value(snapshot, "drill", "took_ms"))
    end

    test "when we last proved we could restore is a question the ledger answers", ctx do
      assert Snapshot.value(Snapshot.open([ctx.journal]), "drill", "proven_at") == nil

      {:ok, _} = Job.run(Drill.job(ctx.opts), ctx.journal, Snapshot.open([ctx.journal]), 1000)

      proven = Snapshot.value(Snapshot.open([ctx.journal]), "drill", "proven_at")
      assert is_integer(proven)
      assert proven > 0
    end

    test "a drill that cannot restore records that rather than crashing", ctx do
      corrupt(ctx.remote)

      assert {:failed, _tx, reason} =
               Job.run(Drill.job(ctx.opts), ctx.journal, Snapshot.open([ctx.journal]), 1000)

      assert reason =~ "drill could not give the facts back"

      snapshot = Snapshot.open([ctx.journal])
      assert Job.failures(snapshot, "drill") != []
      # A job that failed still ran, and the ledger says so.
      assert Job.last_run(snapshot, "drill") == 1000
      # And nothing was proven, so nothing claims to have been.
      assert Snapshot.value(snapshot, "drill", "proven_at") == nil
    end

    test "a failure leaves the last successful drill standing", ctx do
      {:ok, _} = Job.run(Drill.job(ctx.opts), ctx.journal, Snapshot.open([ctx.journal]), 1000)
      proven = Snapshot.value(Snapshot.open([ctx.journal]), "drill", "proven_at")

      corrupt(ctx.remote)

      assert {:failed, _, _} =
               Job.run(Drill.job(ctx.opts), ctx.journal, Snapshot.open([ctx.journal]), 2000)

      # Still the earlier one: a run that proved nothing must not be able to
      # answer "when did we last prove we could restore".
      assert Snapshot.value(Snapshot.open([ctx.journal]), "drill", "proven_at") == proven
      assert Job.failures(Snapshot.open([ctx.journal]), "drill") != []
    end

    test "it has a cadence and the runner picks it up", ctx do
      {:ok, _} = Ledger.append(ctx.journal, Drill.declare(every: 21_600))

      assert Job.due?(Snapshot.open([ctx.journal]), "drill", 0)

      runner =
        start_supervised!(
          {Job.Runner,
           ledger: ctx.journal,
           jobs: [Drill.job(ctx.opts)],
           name: :"drill_#{System.unique_integer([:positive])}"}
        )

      assert {:ok, ["drill"]} = Job.Runner.tick(runner, 1000)
    end
  end

  describe "one ledger per run, chosen by what has waited longest" do
    setup ctx do
      second = {:drill_test_b, System.unique_integer([:positive])}
      {:ok, other} = Ledger.open(second, store: {Store.File, dir: ctx.ledgers})
      on_exit(fn -> Ledger.close(second) end)

      {:ok, _} = Ledger.append(other, Attribute.seed())
      {:ok, _} = Ledger.append(other, Attribute.define("depth", answers: "integer"))
      {:ok, _} = Ledger.append(other, [{"trench", "depth", 10_994}])

      {:ok, report} = Backup.run(ctx.backup)
      assert report.ledgers == 2

      %{second: second}
    end

    test "a run drills exactly one of them", ctx do
      {:ok, report} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)

      assert report.ledgers == 1
      assert report.drilled in [ctx.name, ctx.second]
    end

    test "and the next run drills the other, so every ledger comes round", ctx do
      {:ok, _} = Job.run(Drill.job(ctx.opts), ctx.journal, Snapshot.open([ctx.journal]), 1000)
      {:ok, _} = Job.run(Drill.job(ctx.opts), ctx.journal, Snapshot.open([ctx.journal]), 2000)

      drilled =
        Snapshot.open([ctx.journal])
        |> Snapshot.find(id: "drill", attribute: "drilled")
        |> Enum.map(& &1.value)

      assert Enum.sort(drilled) == Enum.sort([ctx.name, ctx.second])
    end

    test "only the sampled ledger's segments are ever fetched", ctx do
      # The narrowed target is what makes sampling real rather than cosmetic: a
      # drill that restored everything and compared one would cost the whole
      # backup every cadence.
      {:ok, report} = Drill.run(Snapshot.open([ctx.journal]), ctx.opts)

      {:ok, keys} =
        Drill.Sample.list(
          [target: {Backup.Target.Directory, root: ctx.remote}, file: filename(report.drilled)],
          "ledgers/"
        )

      assert keys != []
      assert Enum.all?(keys, &String.contains?(&1, filename(report.drilled)))
    end
  end

  describe "limits, stated rather than hidden" do
    test "a ledger over the ceiling is skipped and named, not passed over quietly", ctx do
      {:ok, report} =
        Drill.run(Snapshot.open([ctx.journal]), Keyword.put(ctx.opts, :max_bytes, 1))

      assert report.ledgers == 0
      assert report.drilled == nil
      assert ctx.name in report.too_big
    end

    test "and a run with nothing to drill is not a failure", ctx do
      empty = Path.join(ctx.scratch, "nothing-here")

      opts = Keyword.put(ctx.opts, :target, {Backup.Target.Directory, root: empty})

      {:ok, tx} = Job.run(Drill.job(opts), ctx.journal, Snapshot.open([ctx.journal]), 1000)

      snapshot = Snapshot.open([ctx.journal])
      written = Enum.filter(Ledger.facts_at(ctx.journal, tx), &(&1.tx == tx))

      assert written != []
      assert Snapshot.value(snapshot, "drill", "restored_ledgers") == 0
      assert Snapshot.value(snapshot, "drill", "proven_at") == nil
      assert Job.failures(snapshot, "drill") == []
    end

    test "a drill refuses to stage on top of a live directory", ctx do
      # The configured key directory, asked for as somewhere to stage into. A
      # restore must never share a path with the facts or the keys it checks,
      # and this is the one mistake an operator makes by typing the wrong
      # environment variable.
      live = Application.fetch_env!(:lazy_river, :key_dir)

      assert_raise RuntimeError, ~r/live directory/, fn ->
        Drill.run(Snapshot.open([ctx.journal]), Keyword.put(ctx.opts, :scratch_dir, live))
      end
    end

    test "and refuses to run with no target at all", ctx do
      # Nothing configures `:backup_target` in test, so this is what a drill on a
      # node with no backup would meet.
      assert_raise RuntimeError, ~r/No backup target/, fn ->
        Drill.run(Snapshot.open([ctx.journal]), scratch_dir: ctx.scratch)
      end
    end
  end

  describe "the narrowed target" do
    test "shows one ledger's segments and hides the rest", ctx do
      second = {:drill_test_c, System.unique_integer([:positive])}
      {:ok, other} = Ledger.open(second, store: {Store.File, dir: ctx.ledgers})
      on_exit(fn -> Ledger.close(second) end)
      {:ok, _} = Ledger.append(other, Attribute.seed())
      {:ok, _} = Backup.run(ctx.backup)

      opts = [target: {Backup.Target.Directory, root: ctx.remote}, file: filename(ctx.name)]

      {:ok, keys} = Drill.Sample.list(opts, "ledgers/")

      assert keys != []
      refute Enum.any?(keys, &String.contains?(&1, filename(second)))
    end

    test "refuses to put, because a drill reads the backup and never writes it", ctx do
      opts = [target: {Backup.Target.Directory, root: ctx.remote}, file: filename(ctx.name)]

      assert {:error, refusal} = Drill.Sample.put(opts, "ledgers/anything", "bytes")
      assert refusal.problem == :drill_is_read_only
    end
  end

  # ── making a backup that cannot be given back ──────────────────────────────

  # Bytes that are not records. `0xFF` rather than zeros on purpose: a run of
  # zeros decodes as a valid empty record and this has to be unreadable.
  defp corrupt(remote) do
    {:ok, [segment]} = Backup.Target.Directory.list([root: remote], "ledgers/")
    path = Path.join(remote, segment)
    File.write!(path, :binary.copy(<<255>>, byte_size(File.read!(path))))
  end

  # A whole, checksummed record holding facts that were never written. The
  # segment is renamed to the range it now covers, so the restore sees no hole —
  # only a copy that answers something else.
  defp substitute(remote, facts) do
    {:ok, [segment]} = Backup.Target.Directory.list([root: remote], "ledgers/")
    File.rm!(Path.join(remote, segment))

    payload = :erlang.term_to_binary(facts)
    record = <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>

    File.write!(
      Path.join([remote, Path.dirname(segment), "0-#{byte_size(record)}.segment"]),
      record
    )
  end

  defp filename(name), do: Store.File.filename(name)

  defp segment_from(key) do
    key |> Path.basename(".segment") |> String.split("-") |> hd() |> String.to_integer()
  end
end
