defmodule Blazie.Drill do
  @moduledoc """
  Giving the facts back, on a cadence — which makes a restore a **job** too.

  `Blazie.Backup` proves that bytes leave. Nothing it does proves they can
  come back, and that difference is the whole of it: a backup is only ever
  proven by the last restore. This deployment's last restore was done by a
  human, by hand, once. That is a rumour with a timestamp on it, and the answer
  to a rumour here is the same as the answer to everything else — make it a job,
  and let the ledger hold what it proved.

  So every cadence this pulls one ledger back out of the backup, opens it, asks
  it for every fact it holds, and asks the live ledger the same question. If the
  two answers differ the run fails, and the failure is a fact.

  ## Bytes matching is not proof; answering the same is

  `Backup.verify/1` already compares byte counts, and a byte count is exactly
  what a broken restore has plenty of. The question here is asked *of an opened
  ledger*: the copy is renamed, opened through `Store.File` like any other
  ledger, and read back through `Ledger.find_at/3` with an empty pattern, which
  is every fact it holds.

  The comparison is made **at the restored ledger's transaction**, not at the
  live one's. A backup is always a prefix — a run copies, and the live ledger
  goes on being written to — so the honest question is whether the copy answers,
  at transaction *n*, exactly what the original answers at *n*. That is a
  snapshot, and an answer at a snapshot is the same answer forever, which is why
  this can be an equality rather than a tolerance.

  ## One ledger per run, chosen by what has waited longest

  A full drill every cadence would restore the entire backup every cadence, and
  the property that makes the backup affordable is precisely that it never moves
  what it has already moved. A drill that pulled everything down every fifteen
  minutes would cost more than the thing it checks, every time, forever — and a
  check nobody can afford is a check somebody turns off.

  So a run drills exactly one ledger, and the one it picks is the one drilled
  longest ago, read out of this job's own past facts. No state is kept in this
  process, so a redeploy picks the rotation up where it left off: the ledger is
  the state, the same way it is already the scheduler. With *n* ledgers every one
  of them is proven inside *n* cadences, and a run costs one ledger rather than
  all of them. The default cadence is six hours for the same reason — a drill is
  a real download and a real replay, and what it checks changes on the scale of
  days.

  Only that ledger's segments cross the wire. `Blazie.Drill.Sample` is a
  `Backup.Target` that wraps the configured one and hides every key but the
  chosen ledger's, so this runs `Backup.restore/1` itself rather than a second
  restore path that could be correct while the real one is not. It also refuses
  to put, so a drill cannot write to the backup it is checking.

  ## Limits, stated rather than hidden

  **Only ledgers that are open are drilled.** Comparing means asking the live
  ledger the same question, and a ledger nobody has opened would have to be
  opened to ask — which would mean the drill starting live ledgers on the node.
  It will not. A cold tenant ledger is backed up and not drilled, and the
  `drilled` facts are how you see which ones were.

  **A ledger larger than `max_bytes` is skipped**, and named in a `too_big` fact
  every run rather than passed over quietly. The default ceiling is 512 MB,
  because the scratch disk under a release is not the data volume, and a drill
  that fills it takes the node with it.

  **Keys are not restored.** A drill restores `only: :ledgers`. Reading a sealed
  value needs the keyring, and the keyring is one process pointed at one
  directory — pointing it at a restored key store would mean swapping a live
  global for the length of a drill, which is a worse risk than the one this
  covers. Both sides of the comparison reveal through the same live keyring, so
  sealed values still have to match. What is not proven here is that the keys
  themselves come back; that round trip is byte-for-byte and covered in
  `backup_test`.

  **A run that finds nothing to drill is not a failure.** It records
  `restored_ledgers` of zero and writes no `proven_at`, which is the honest
  answer: nothing was proven. "When did we last prove we could restore" is
  `proven_at`, and an operator watching for it to stop advancing sees a backup
  that has quietly become undrillable — which a failure fact every cadence would
  have buried rather than shown.
  """

  alias Blazie.{Attribute, Backup, Job, Ledger, Snapshot, Store}

  @id "drill"
  @ledger "$drill"

  # Six hours. A drill is a real download and a real replay of one ledger, and
  # what it is checking — can this backup be given back — changes on the scale of
  # days. The backup's own cadence is minutes because its cost is only what
  # changed; this one's cost is not.
  @default_every 21_600

  # The scratch disk under a release is not the data volume. A drill that fills
  # it takes the node down with it, which would make the check worse than the
  # risk it covers.
  @default_max_bytes 512 * 1024 * 1024

  @type report :: %{
          ledgers: non_neg_integer(),
          drilled: term(),
          compared_facts: non_neg_integer(),
          proven_tx: non_neg_integer(),
          took_ms: non_neg_integer(),
          too_big: [term()]
        }

  @doc "The attributes a run describes itself with."
  #
  # `proven_at` is the only one with cardinality one, and the question it answers
  # is why: "when did we last prove we could restore" wants the latest and only
  # the latest. Every earlier one is still in the ledger — nothing is rewritten,
  # so a later fact simply corrects it.
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Attribute.define("drilled", answers: "name", cardinality: "many") ++
      Attribute.define("restored_ledgers", answers: "integer", cardinality: "many") ++
      Attribute.define("compared_facts", answers: "integer", cardinality: "many") ++
      Attribute.define("took_ms", answers: "integer", cardinality: "many") ++
      Attribute.define("proven_tx", answers: "integer", cardinality: "many") ++
      Attribute.define("too_big", answers: "name", cardinality: "many") ++
      Attribute.define("proven_at", answers: "integer")
  end

  @doc "The ledger a drill's own history is written to."
  @spec ledger() :: String.t()
  def ledger, do: @ledger

  @doc "Declare the drill as a job, with how often to run."
  @spec declare(keyword()) :: [tuple()]
  def declare(opts \\ []), do: Job.declare(@id, opts)

  @doc """
  The job. Its answer is what this run proved, which is why it is one.

  A restore that cannot be given back is raised rather than returned, because
  `Job.run/4` turns a raise into a `failed` fact — so a backup that has stopped
  being restorable becomes a question the ledger answers rather than a silence.

  The cost of that choice, said out loud: a failed run keeps its numbers in the
  failure's message and not in `compared_facts`, because `Job.run/4` records the
  reason and drops whatever the work had computed. Only a run that proved
  something records what it proved.
  """
  @spec job(keyword()) :: Job.t()
  def job(opts \\ []) do
    Job.new(@id, fn snapshot ->
      case run(snapshot, opts) do
        {:ok, report} -> facts(report)
        {:error, refusal} -> raise "drill could not give the facts back: #{inspect(refusal)}"
      end
    end)
  end

  @doc """
  Restore one ledger into a scratch directory, open it, and ask it everything.

  `history` is a snapshot of this job's own ledger. Which ledgers have been
  drilled, and in what order, is read out of it — that is the whole of the
  rotation. A snapshot with none of those facts in it picks whatever is first.

      run(Snapshot.open([drill_ledger]),
          target: {Backup.Target.S3, bucket: "blazie", ...},
          scratch_dir: "/tmp",
          max_bytes: 512 * 1024 * 1024)
  """
  @spec run(Snapshot.t(), keyword()) :: {:ok, report()} | {:error, map()}
  def run(%Snapshot{} = history, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    target = target(opts)
    ceiling = ceiling(opts)

    case choose(history, target, ceiling) do
      {nil, too_big} ->
        {:ok,
         %{
           ledgers: 0,
           drilled: nil,
           compared_facts: 0,
           proven_tx: 0,
           took_ms: since(started),
           too_big: too_big
         }}

      {name, too_big} ->
        drill(name, target, opts, started, too_big)
    end
  end

  # ── started, not merely built ──────────────────────────────────────────────
  #
  # The same lesson `Backup` carries, and this deployment proved it four separate
  # times: a component written, tested, configured and never started is the same
  # as one that does not exist. A restore drill is the worst possible member of
  # that set, because it exists entirely to catch the case where something else
  # is silently not working.

  @doc "Start the drill job under a runner, seeding its ledger if it is new."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_runner, [opts]}, type: :worker}
  end

  @doc false
  def start_runner(opts) do
    every = Keyword.get(opts, :every, @default_every)
    {:ok, ledger} = Ledger.open(@ledger)

    if Ledger.tx(ledger) == 0 do
      Ledger.append(ledger, Attribute.seed() ++ Job.seed() ++ seed() ++ declare(every: every))
    end

    Job.Runner.start_link(
      ledger: ledger,
      jobs: [job(opts)],
      every: :timer.seconds(every),
      name: __MODULE__.Runner
    )
  end

  # ── choosing which ledger to prove ─────────────────────────────────────────

  # Least recently drilled first, and never drilled before that. The rotation
  # lives in the drill's own past facts rather than in this process, so a
  # redeploy picks up where the last one left off.
  defp choose(history, target, ceiling) do
    order =
      history
      |> Snapshot.find(id: @id, attribute: "drilled")
      |> Enum.map(& &1.value)
      |> Enum.with_index()
      # Later entries overwrite earlier ones, so this holds the *last* time each
      # ledger was drilled rather than the first.
      |> Map.new()

    Ledger.open_ledgers()
    |> Enum.sort_by(&Map.get(order, &1, -1))
    |> Enum.reduce_while({nil, []}, fn name, {nil, too_big} ->
      case held(target, name) do
        # Nothing held under this name: a ledger kept in memory, or one opened
        # since the last backup run. Neither is a finding.
        0 -> {:cont, {nil, too_big}}
        held when held > ceiling -> {:cont, {nil, [name | too_big]}}
        _held -> {:halt, {name, too_big}}
      end
    end)
  end

  # `Backup.held/2` insists the target answered, and a target that cannot be
  # listed would otherwise reach the ledger as a match error with no repair on
  # it. Said properly, because a boundary that rejects without saying how to
  # comply produces loops rather than compliance.
  defp held(target, name) do
    Backup.held([target: target], name)
  rescue
    error ->
      reraise "the backup target could not be listed (#{Exception.message(error)}). " <>
                "A drill cannot choose what to prove without knowing what is held, so check " <>
                "the target's credentials and that it is reachable from this node.",
              __STACKTRACE__
  end

  # ── the drill itself ───────────────────────────────────────────────────────

  defp drill(name, target, opts, started, too_big) do
    scratch = Path.join(scratch_dir(opts), "drill-#{System.unique_integer([:positive])}")
    dir = Path.join(scratch, "ledgers")
    copy = copy_name()

    try do
      with :ok <- free?(copy),
           {:ok, restored} <- pull(name, target, scratch, dir),
           :ok <- whole?(restored, name),
           {:ok, compared, at} <- ask_both(name, copy, dir) do
        {:ok,
         %{
           ledgers: restored.ledgers,
           drilled: name,
           compared_facts: compared,
           proven_tx: at,
           took_ms: since(started),
           too_big: too_big
         }}
      end
    after
      # Both of these run whether the drill proved something or raised on the way
      # there. A scratch directory left behind is a disk that fills one cadence
      # at a time, and a ledger left open is a name nobody can ever take again.
      Ledger.close(copy)
      File.rm_rf(scratch)
    end
  end

  defp pull(name, target, scratch, dir) do
    Backup.restore(
      ledger_dir: dir,
      # Never the real key store, and in fact never touched at all: with
      # `only: :ledgers`, `restore/1` does not so much as create this directory.
      # It is named anyway, so that nothing can fall back to the configured one.
      key_dir: Path.join(scratch, "keys"),
      only: :ledgers,
      target: {__MODULE__.Sample, target: target, file: Store.File.filename(name)}
    )
  end

  defp whole?(%{ledgers: 0}, name) do
    {:error,
     %{
       problem: :nothing_came_back,
       ledger: name,
       repair:
         "The backup holds segments for this ledger and restoring it produced no file. " <>
           "Check the target is readable, then run Backup.verify/1 to see what it believes " <>
           "it holds."
     }}
  end

  defp whole?(%{incomplete: [_ | _] = incomplete}, name) do
    {:error,
     %{
       problem: :incomplete,
       ledger: name,
       incomplete: incomplete,
       repair:
         "A segment is missing, so the restore stopped at the hole rather than gluing across " <>
           "it. The next Backup.run/1 re-copies from the hole and heals it; if it does not, " <>
           "the target is losing or expiring segments and retention on the bucket is the fix."
     }}
  end

  defp whole?(_restored, _name), do: :ok

  # ── asking both the same question ──────────────────────────────────────────

  # A ledger's file is named for the ledger, so the copy is renamed before it is
  # opened. This is the one thing a drill has to get right: `Ledger.open/2` hands
  # back the ledger already open under a name, so opening the copy under its
  # original name would silently return the *live* ledger — and the drill would
  # compare it against itself and pass forever.
  defp ask_both(name, copy, dir) do
    File.rename!(
      Path.join(dir, Store.File.filename(name)),
      Path.join(dir, Store.File.filename(copy))
    )

    {:ok, restored} = Ledger.open(copy, store: {Store.File, dir: dir})
    live = Ledger.via(name)
    at = Ledger.tx(restored)

    # `find_at/3` with an empty pattern rather than `facts_at/2`. They are the
    # same answer on an unbounded ledger and not on a bounded one: only
    # `find_at/3` goes back to the store for facts that have been evicted, and a
    # drill comparing a trimmed live ledger against a whole restored one would
    # report a difference that is not there.
    theirs = Ledger.find_at(restored, at, [])
    ours = Ledger.find_at(live, at, [])

    cond do
      at == 0 and Ledger.tx(live) > 0 ->
        {:error,
         %{
           problem: :restored_nothing,
           ledger: name,
           repair:
             "The restored copy opened at transaction 0 while the live ledger is further on. " <>
               "The segments are there and unreadable — a torn first record, or bytes the " <>
               "target gave back that are not the bytes that were put."
         }}

      theirs != ours ->
        {:error,
         %{
           problem: :answers_differently,
           ledger: name,
           at: at,
           live_facts: length(ours),
           restored_facts: length(theirs),
           repair:
             "The restored ledger does not answer at transaction #{at} what the live one " <>
               "answers there, so the copy is not a prefix of the original. Do not trust this " <>
               "backup until a run of Backup.verify/1 and a re-copy make this drill pass."
         }}

      true ->
        {:ok, length(ours), at}
    end
  end

  # Belt and braces on the one mistake that would make this whole module a lie.
  # The name is minted fresh per run so it cannot already be taken, and this
  # checks anyway, because a drill quietly comparing a live ledger against itself
  # would pass forever and prove nothing.
  defp free?(copy) do
    if copy in Ledger.open_ledgers() do
      {:error,
       %{
         problem: :name_taken,
         ledger: copy,
         repair:
           "A drill's scratch ledger name is already open. Close it — the drill must never " <>
             "open the copy under a name that could resolve to a live ledger."
       }}
    else
      :ok
    end
  end

  # Distinct from anything a tenant could be called: the first element is this
  # module, which is an atom no name arriving from outside is allowed to become.
  defp copy_name, do: {__MODULE__, :restored, System.unique_integer([:positive])}

  # ── what a run writes ──────────────────────────────────────────────────────

  defp facts(%{ledgers: 0} = report) do
    [
      {@id, "restored_ledgers", 0},
      {@id, "compared_facts", 0},
      {@id, "took_ms", report.took_ms}
    ] ++ too_big_facts(report)
  end

  defp facts(report) do
    [
      {@id, "drilled", report.drilled},
      {@id, "restored_ledgers", report.ledgers},
      {@id, "compared_facts", report.compared_facts},
      {@id, "proven_tx", report.proven_tx},
      {@id, "took_ms", report.took_ms},
      # Reading the clock is reaching outside, which is what a job is for.
      # Written only by a run that proved something, so that "when did we last
      # prove we could restore" can never be answered by a run that did not.
      {@id, "proven_at", System.system_time(:second)}
    ] ++ too_big_facts(report)
  end

  defp too_big_facts(report), do: Enum.map(report.too_big, &{@id, "too_big", &1})

  defp since(started), do: System.monotonic_time(:millisecond) - started

  # ── configuration ──────────────────────────────────────────────────────────

  defp target(opts) do
    case Keyword.get(opts, :target) || Application.get_env(:blazie, :backup_target) do
      {module, topts} ->
        {module, topts}

      nil ->
        raise "No backup target configured. A drill with nothing to restore from is not a drill."
    end
  end

  defp ceiling(opts) do
    Keyword.get(opts, :max_bytes) ||
      Application.get_env(:blazie, :drill_max_bytes) ||
      @default_max_bytes
  end

  defp scratch_dir(opts) do
    dir =
      Keyword.get(opts, :scratch_dir) ||
        Application.get_env(:blazie, :drill_dir) ||
        System.tmp_dir!()

    live =
      [:ledger_dir, :key_dir]
      |> Enum.map(&Application.get_env(:blazie, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.expand/1)

    if Path.expand(dir) in live do
      raise "A drill would stage into #{dir}, which is a live directory. Set :drill_dir to " <>
              "somewhere disposable — a restore must never share a path with the facts or the " <>
              "keys it is checking."
    end

    dir
  end
end

defmodule Blazie.Drill.Sample do
  @moduledoc """
  One ledger's worth of a backup, and nothing else.

  A `Blazie.Backup.Target` that wraps the configured one and hides every key
  but the chosen ledger's segments. That is what lets a drill sample:
  `Backup.restore/1` restores everything it can see, so narrowing what it can see
  restores one ledger without a second restore path that could be correct while
  the real one is not.

  It refuses to put. A drill reads the backup, and nothing about proving a
  restore requires writing to the thing being proven — a bug here that could
  write would be a bug that could destroy the only copy.
  """

  @behaviour Blazie.Backup.Target

  @ledgers_prefix "ledgers/"

  @impl true
  def put(_opts, key, _bytes) do
    {:error,
     %{
       problem: :drill_is_read_only,
       key: key,
       repair: "A drill restores and never writes. Whatever asked for this put is the bug."
     }}
  end

  @impl true
  def get(opts, key) do
    {module, topts} = Keyword.fetch!(opts, :target)
    module.get(topts, key)
  end

  @impl true
  def list(opts, prefix) do
    {module, topts} = Keyword.fetch!(opts, :target)
    keep = @ledgers_prefix <> Keyword.fetch!(opts, :file) <> "/"

    with {:ok, keys} <- module.list(topts, prefix) do
      {:ok, Enum.filter(keys, &String.starts_with?(&1, keep))}
    end
  end
end
