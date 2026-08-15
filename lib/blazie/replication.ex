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

  alias Blazie.Store

  @type refusal :: %{problem: atom(), repair: String.t()}

  # ── lifecycle ────────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Deliberate stop: SIGTERM the daemon and wait for its drain."
  @spec drain(GenServer.server()) :: :ok
  def drain(server), do: GenServer.call(server, :drain, 30_000)

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    replica_url = Keyword.fetch!(opts, :replica_url)
    pattern = Keyword.get(opts, :pattern, "*.sqlite")
    sync_interval = Keyword.get(opts, :sync_interval, "1s")

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
    {:ok, %{port: port, config_path: config_path, draining: nil}}
  end

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
    if state.draining, do: GenServer.reply(state.draining, :ok)
    File.rm(state.config_path)

    case state.draining do
      # A drain is the deliberate end; stop normally.
      from when from != nil -> {:stop, :normal, %{state | draining: nil}}
      # A crash is not: stop abnormally so the supervisor brings it back and
      # the WAL catch-up closes the gap.
      nil -> {:stop, :replicator_died, state}
    end
  end

  def handle_info({port, {:data, _line}}, %{port: port} = state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    with {:os_pid, os_pid} <- Port.info(state.port, :os_pid) do
      System.cmd("kill", ["-TERM", to_string(os_pid)])
    end

    File.rm(state.config_path)
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
      case System.cmd(
             executable!(),
             ["restore", "-if-replica-exists", "-o", path, "#{replica_url}/#{filename}"],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          if File.exists?(path), do: {:ok, :restored}, else: nothing_to_restore(name)

        {out, _} ->
          {:error,
           %{
             problem: :restore_failed,
             repair: "litestream could not restore #{inspect(name)}: #{String.slice(out, 0, 300)}"
           }}
      end
    end
  end

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
