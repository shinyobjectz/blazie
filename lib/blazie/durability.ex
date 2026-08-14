defmodule Blazie.Durability do
  @moduledoc """
  The boot-time demand that a production node cannot be accidentally ephemeral.

  Two settings decide whether anything here survives: `LEDGER_DIR` decides
  whether facts outlive the process (`World.default_store/0` answers the
  memory store without it), and `KEY_DIR` decides whether subjects outlive a
  redeploy (keys on an ephemeral disk are every subject erased by accident).
  Both used to default quietly, and one of them merely warned — and a warning
  at boot is a log line nobody reads until the day the default was wrong,
  which has already happened once: the config existed, nothing read it, and
  every world in production was in memory.

  So production refuses to boot without them, and the refusal carries the
  repair. Pure and called from `config/runtime.exs`, because a check that
  lives only in a config script is a check no test runs.
  """

  @wanted ["LEDGER_DIR", "KEY_DIR"]

  @doc """
  The environment, or a raise that says exactly what to set and why.

  Takes the env as a map so a test can hand it one — `System.get_env/0`
  at the real call site.
  """
  @spec demanded!(%{String.t() => String.t()}) :: :ok
  def demanded!(env) when is_map(env) do
    case Enum.filter(@wanted, &(env[&1] in [nil, ""])) do
      [] ->
        :ok

      missing ->
        raise """
        #{Enum.join(missing, " and ")} not set, so this node refuses to boot.

        A production node without them keeps facts or keys on whatever disk the
        container happened to get, and a redeploy then erases every world or
        every subject — silently, and it has happened. Set both to paths on
        persistent storage:

            LEDGER_DIR=/data/ledgers
            KEY_DIR=/data/keys

        and make sure /data is a mounted volume, not the container's own disk.
        """
    end
  end
end
