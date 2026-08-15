defmodule Blazie.Replication do
  @moduledoc """
  The replicator sidecar, supervised — every tenant file out, any file back.

  Litestream in dir mode (`dir` + `pattern` + `watch`): the daemon watches the
  ledger directory, a tenant file that appears at runtime starts replicating
  within seconds, and a deleted one is cleanly dropped — no per-tenant config,
  no restart, which is the property that makes per-tenant SQLite operable at
  all (docs/storage-plan.md, P4). The replica (R2 in production, `file://` in
  tests — the same URL scheme discipline the backup's S3 target draws) is the
  truth a cold node hydrates from: `restore_if_missing/2` is what a world's
  open path calls before the engine opens the file.

  The daemon is a Port under this GenServer, so the tree owns its lifetime.
  `drain/1` is the deliberate stop: SIGTERM, then wait for exit — litestream
  flushes in-flight LTX on terminate, which is the deploys-reset-in-flight
  ground rule wired in rather than remembered. A crash restarts it (transient
  gaps are caught up from the WAL); a config is generated per start, never
  hand-kept.

  What this module deliberately does NOT do: own WAL checkpointing (the
  daemon does), invent a wire format (LTX is the vendor's, with their test
  corpus), or let two nodes replicate one tenant to one prefix — the
  single-writer lease rides sticky routing (P4-cluster), and until that
  lands, one node runs one replicator.
  """

  use GenServer

  alias Blazie.{Attribute, Job, Store}
  alias Exqlite.Sqlite3

  @type refusal :: %{problem: atom(), repair: String.t()}

  @job_id "replication"

  # ── lifecycle ────────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Deliberate stop: SIGTERM the daemon and wait for its drain."
  @spec drain(GenServer.server()) :: :ok
  def drain(server), do: GenServer.call(server, :drain, 30_000)

  @doc """
  Close a world AND remove its local file — disk pressure, when R2 is truth.

  Idle eviction (`evict_after:` on the world) closes the process and keeps
  the file; this is the harder step, for when the disk itself is the
  pressure. It refuses unless the replica actually holds the world, because
  "R2 is truth" is a claim this function must check rather than assume —
  deleting the only copy is erasure by accident, and erasure here destroys a
  key, never a file. The evicted world comes back through
  `restore_if_missing/2` on its next cold open.
  """
  @spec evict(term(), Path.t(), keyword()) :: :ok | {:error, refusal()}
  def evict(name, dir, opts \\ []) do
    replica_url = Keyword.fetch!(opts, :replica_url)

    if replicated?(name, replica_url) do
      case Blazie.World.close(name) do
        ok when ok in [:ok, {:error, :not_found}] ->
          path = Path.join(dir, Store.SQLite.filename(name))
          File.rm(path)
          File.rm(path <> "-wal")
          File.rm(path <> "-shm")
          :ok

        {:error, :timeout} ->
          {:error,
           %{
             problem: :world_would_not_close,
             repair:
               "#{inspect(name)} did not close within the timeout. Nothing was deleted; " <>
                 "a file must never be removed from under a live world."
           }}
      end
    else
      {:error,
       %{
         problem: :replica_does_not_hold,
         repair:
           "The replica has no LTX for #{inspect(name)}, so its local file is the only " <>
             "copy. Evicting it would be deletion, not eviction. Let the replicator ship " <>
             "it first (litestream ltx will show it), then evict."
       }}
    end
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    replica_url = Keyword.fetch!(opts, :replica_url)
    pattern = Keyword.get(opts, :pattern, "*.sqlite")
    sync_interval = Keyword.get(opts, :sync_interval, "1s")

    case take_lease(replica_url, opts) do
      {:ok, lease} ->
        config_path =
          Path.join(System.tmp_dir!(), "litestream-#{System.unique_integer([:positive])}.yml")

        File.write!(config_path, """
        dbs:
          - dir: #{dir}
            pattern: "#{pattern}"
            watch: true
            replica:
              url: #{replica_url}
              sync-interval: #{sync_interval}
        """)

        port =
          Port.open({:spawn_executable, executable!()}, [
            :binary,
            :exit_status,
            args: ["replicate", "-config", config_path],
            line: 4096
          ])

        Process.flag(:trap_exit, true)
        {:ok, %{port: port, config_path: config_path, draining: nil, lease: lease}}

      {:error, refusal} ->
        {:stop, refusal}
    end
  end

  # ── the lease fence ──────────────────────────────────────────────────────────
  #
  # Two nodes must never both replicate one tenant prefix silently — that is
  # the netsplit hole (storage plan, landmine 6): node A partitions mid-flush,
  # node B hydrates from the replica and writes, A returns and flushes stale
  # WAL over it. This binary was probed for the upstream distributed-leasing
  # config before this was written and does not expose one (no lease key in
  # its config schema; the lease symbols in the binary are its Azure SDK's),
  # so the fence here is the honest minimum: a LEASE object at the replica
  # root naming the node that replicates this prefix, taken with
  # write-if-absent semantics where the scheme has them.
  #
  # What IS enforced: on `file://` (and any shared filesystem), `:exclusive`
  # create — a second node's replicator REFUSES to start while another node's
  # lease stands, with the repair naming the holder. A drain or a clean stop
  # releases it; a node retaking its own lease (crash, restart) succeeds.
  #
  # What is NOT enforced, said plainly: on `s3://` there is no exclusive
  # create in this module — R2's conditional writes (If-None-Match) are the
  # production fence, and wiring them through the S3 target is deliberately
  # not faked here with a read-then-write that would only shrink the race.
  # An s3 replicator starts unfenced and says so in the log. Sticky routing
  # (who SHOULD write) remains P4-cluster's open half.

  defp take_lease("file://" <> path, opts) do
    File.mkdir_p!(path)
    lease_path = Path.join(path, "LEASE")
    me = Keyword.get(opts, :node_id, Atom.to_string(node()))

    case :file.open(lease_path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        :ok = :file.write(io, lease_body(me))
        :ok = :file.close(io)
        {:ok, lease_path}

      {:error, :eexist} ->
        case File.read(lease_path) do
          {:ok, body} ->
            case holder_of(body) do
              ^me ->
                # Our own lease, left by a crash or an unclean stop. Retake it:
                # the fence is against ANOTHER node, not against our past self.
                File.write!(lease_path, lease_body(me))
                {:ok, lease_path}

              other ->
                {:error,
                 %{
                   problem: :lease_held,
                   repair:
                     "#{inspect(other)} holds the replication lease for this prefix " <>
                       "(#{lease_path}). Two nodes must never both replicate one tenant " <>
                       "prefix — if that node is dead, remove the LEASE object and start " <>
                       "again; if it is alive, this node must not replicate here."
                 }}
            end

          {:error, _} ->
            {:error,
             %{
               problem: :lease_unreadable,
               repair: "#{lease_path} exists but cannot be read. Resolve it by hand."
             }}
        end

      {:error, posix} ->
        {:error,
         %{
           problem: :lease_unwritable,
           repair: "Could not take the lease at #{lease_path}: #{inspect(posix)}."
         }}
    end
  end

  defp take_lease(_other_scheme, _opts) do
    require Logger

    Logger.warning(
      "replication: no lease fence on this replica scheme — R2 conditional writes are " <>
        "the production fence and are not wired yet; ensure one node per prefix by deployment"
    )

    {:ok, nil}
  end

  defp lease_body(me), do: "#{me}\n#{System.system_time(:second)}\n"

  defp holder_of(body), do: body |> String.split("\n") |> List.first()

  defp release_lease(nil), do: :ok
  defp release_lease(path), do: File.rm(path)

  @impl true
  def handle_call(:drain, from, state) do
    case Port.info(state.port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-TERM", to_string(os_pid)])
        {:noreply, %{state | draining: from}}

      nil ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    File.rm(state.config_path)

    case state.draining do
      # A drain is the deliberate end; stop normally. The lease is released
      # BEFORE the reply — a drained caller must be able to hand the prefix
      # to another node the moment `drain/1` returns.
      from when from != nil ->
        release_lease(state.lease)
        GenServer.reply(from, :ok)
        {:stop, :normal, %{state | draining: nil}}

      # A crash is not: stop abnormally so the supervisor brings it back and
      # the WAL catch-up closes the gap. The lease is kept — the restart
      # retakes its own.
      nil ->
        {:stop, :replicator_died, state}
    end
  end

  def handle_info({port, {:data, _line}}, %{port: port} = state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    with {:os_pid, os_pid} <- Port.info(state.port, :os_pid) do
      System.cmd("kill", ["-TERM", to_string(os_pid)])
    end

    File.rm(state.config_path)

    # The lease is released only by a DELIBERATE end. A crash keeps it on the
    # replica: the supervisor restarts this process on the same node, and a
    # node retaking its own lease succeeds — while another node moving in
    # during the restart window is exactly what the fence exists to refuse.
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
      do: release_lease(state.lease)

    :ok
  end

  # ── hydration ────────────────────────────────────────────────────────────────

  @doc """
  Restore one world's file from the replica when it is not on this disk.

  `{:ok, :present}` when the file is already here (the warm path, free);
  `{:ok, :restored}` after a successful pull; a refusal when neither disk nor
  replica knows the name — which is an honest answer, not an empty world.
  """
  @spec restore_if_missing(term(), keyword()) ::
          {:ok, :present | :restored} | {:error, refusal()}
  def restore_if_missing(name, opts) do
    dir = Keyword.fetch!(opts, :dir)
    replica_url = Keyword.fetch!(opts, :replica_url)
    filename = Store.SQLite.filename(name)
    path = Path.join(dir, filename)

    if File.exists?(path) do
      {:ok, :present}
    else
      case restore("#{replica_url}/#{filename}", path) do
        :ok -> if File.exists?(path), do: {:ok, :restored}, else: nothing_to_restore(name)
        {:error, refusal} -> {:error, %{refusal | repair: "#{inspect(name)}: #{refusal.repair}"}}
      end
    end
  end

  @doc """
  Pull one database from a replica URL to an explicit output path.

  The one restore path — `restore_if_missing/2` and the drill's SQLite pull
  both go through here, so there is no second restore that could be correct
  while the real one is not. `:ok` with no file at `output` afterwards means
  the replica holds nothing under that URL (`-if-replica-exists`).
  """
  @spec restore(String.t(), Path.t()) :: :ok | {:error, refusal()}
  def restore(url, output) do
    case System.cmd(
           executable!(),
           ["restore", "-if-replica-exists", "-o", output, url],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, _} ->
        {:error,
         %{
           problem: :restore_failed,
           repair: "litestream could not restore #{url}: #{String.slice(out, 0, 300)}"
         }}
    end
  end

  @doc """
  Does the replica hold anything for this world?

  Asked of `litestream ltx`, which answers uniformly for `file://` and `s3://`
  — a listing with rows means shipped LTX exists. Used by the drill to decide
  whether a SQLite world can be proven, without pulling anything.
  """
  @spec replicated?(term(), String.t()) :: boolean()
  def replicated?(name, replica_url) do
    ltx_rows("#{replica_url}/#{Store.SQLite.filename(name)}") != []
  end

  # ── replication state as facts ───────────────────────────────────────────────

  @doc "The attributes a replication reading describes itself with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Attribute.define("replicated_ltx", answers: "integer", cardinality: "many") ++
      Attribute.define("replicated_at", answers: "integer", cardinality: "many") ++
      Attribute.define("local_tx", answers: "integer", cardinality: "many")
  end

  @doc "Declare the reading as a job, with how often to run."
  @spec declare(keyword()) :: [tuple()]
  def declare(opts \\ []), do: Job.declare(@job_id, opts)

  @doc """
  A job reporting per-database replication state as facts, honestly minimal.

  For every `.sqlite` file in the watched dir, three facts into whatever world
  the runner writes (the `$backup` world, in the tree): `local_tx` — the
  highest blazie transaction in the local file; `replicated_ltx` — the highest
  LTX transaction the replica holds (litestream's own counter, advanced per
  commit — NOT a blazie tx, so the two are never compared as equals); and
  `replicated_at` — when the newest LTX at the replica was created. The alarm
  shape this preserves: `local_tx` advancing while `replicated_at` stands
  still is a replicator that has stopped shipping. A replica holding nothing
  reads `replicated_ltx` 0 and no `replicated_at`, which is the honest claim.
  """
  @spec reading(keyword()) :: Job.t()
  def reading(opts) do
    dir = Keyword.fetch!(opts, :dir)
    replica_url = Keyword.fetch!(opts, :replica_url)

    Job.new(@job_id, fn _snapshot ->
      Enum.flat_map(sqlite_files(dir), &db_reading(dir, &1, replica_url))
    end)
  end

  defp db_reading(dir, file, replica_url) do
    # The fact's id is the world's NAME where the filename decodes to one —
    # the same id `$storage` readings use — and the raw filename when it does
    # not, so a stray file is still reported rather than skipped silently.
    id = name_of(file)

    case local_tx(Path.join(dir, file)) do
      nil ->
        []

      tx ->
        rows = ltx_rows("#{replica_url}/#{file}")

        [{id, "local_tx", tx}, {id, "replicated_ltx", max_txid(rows)}] ++
          case newest_created(rows) do
            nil -> []
            at -> [{id, "replicated_at", at}]
          end
    end
  end

  defp sqlite_files(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries |> Enum.filter(&String.ends_with?(&1, ".sqlite")) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp name_of(file) do
    with basename <- Path.basename(file, ".sqlite"),
         {:ok, bytes} <- Base.url_decode64(basename) do
      :erlang.binary_to_term(bytes, [:safe])
    else
      _ -> file
    end
  rescue
    _ -> file
  end

  # The highest blazie tx in a local file, read through a second connection —
  # WAL means readers never block the world that is writing. A file that is
  # not a blazie world (no facts table) answers nil and is not reported.
  defp local_tx(path) do
    {:ok, db} = Sqlite3.open(path)

    try do
      {:ok, stmt} = Sqlite3.prepare(db, "SELECT COALESCE(MAX(tx), 0) FROM facts")
      {:row, [tx]} = Sqlite3.step(db, stmt)
      :ok = Sqlite3.release(db, stmt)
      tx
    rescue
      _ -> nil
    after
      Sqlite3.close(db)
    end
  end

  # `litestream ltx <url>` — a header line, then one row per LTX file:
  # `level  min_txid  max_txid  size  created`. Parsed minimally: the txids
  # (hex) and the created stamp are what freshness needs; anything that does
  # not parse is dropped rather than guessed at.
  defp ltx_rows(url) do
    case System.cmd(executable!(), ["ltx", url], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.flat_map(fn line ->
          case String.split(line, ~r/\s+/, trim: true) do
            [_level, _min, max, _size, created] -> parse_row(max, created)
            _ -> []
          end
        end)

      {_out, _} ->
        []
    end
  end

  defp parse_row(max, created) do
    with {txid, ""} <- Integer.parse(max, 16),
         {:ok, at, _} <- DateTime.from_iso8601(created) do
      [{txid, DateTime.to_unix(at)}]
    else
      _ -> []
    end
  end

  defp max_txid(rows), do: rows |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)

  defp newest_created(rows), do: rows |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> nil end)

  defp nothing_to_restore(name) do
    {:error,
     %{
       problem: :nothing_to_restore,
       repair:
         "#{inspect(name)} is on neither this disk nor the replica. A world that was never " <>
           "written has nothing to restore; open it fresh if it is genuinely new."
     }}
  end

  defp executable! do
    System.find_executable("litestream") ||
      raise "litestream is not on PATH. The replicator is a sidecar binary; install it " <>
              "or run without replication (worlds stay durable locally)."
  end
end
