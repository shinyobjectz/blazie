defmodule Blazie.Application do
  @moduledoc """
  The tree: a registry of open ledgers, and a supervisor that opens them.

  Ledgers are opened and closed while the system runs, because a tenant is one
  or more ledgers and tenants arrive at runtime. That rules out registering
  them under atom names — atoms are never collected, so a name taken from a
  request would leak the atom table until the node fell over. Names here are
  any term, held in a `Registry`.
  """

  use Application

  # Off in test, where a background job taking readings every minute is noise
  # rather than observability.
  defp vitals do
    case Application.get_env(:blazie, :vitals_every) do
      nil -> []
      every -> [{Blazie.Vitals, every: every}]
    end
  end

  # Same shape as vitals, and off in test for the same reason.
  defp storage do
    case Application.get_env(:blazie, :storage_every) do
      nil -> []
      every -> [{Blazie.Storage, every: every}]
    end
  end

  # One runner per world named in `:agent_worlds`. Off by default and off in
  # test: a runner that asks a model on a cadence is the one background process
  # here that costs money, so it starts because somebody said to.
  defp agents do
    for world <- Application.get_env(:blazie, :agent_worlds, []) do
      {Blazie.Agents, world: world, every: Application.get_env(:blazie, :agents_every, 30)}
    end
  end

  # Only when there is somewhere to put the bytes. A backup job with no target
  # is a crash loop at boot rather than a backup — and the failure a deployment
  # must never have is the one where it looks configured and copies nothing.
  defp backup do
    case Application.get_env(:blazie, :backup_target) do
      nil -> []
      _target -> [{Blazie.Backup, every: Application.get_env(:blazie, :backup_every, 900)}]
    end
  end

  # Two conditions, because there are two ways for a drill to be wrong. Without a
  # target it has nothing to restore from and would fail every cadence saying so.
  # Without `:drill_every` nobody asked for one, and a drill nobody asked for is
  # a process pulling a world down onto a node's scratch disk on a timer.
  defp drill do
    case {Application.get_env(:blazie, :backup_target),
          Application.get_env(:blazie, :drill_every)} do
      {nil, _every} -> []
      {_target, nil} -> []
      {_target, every} -> [{Blazie.Drill, every: every}]
    end
  end

  # The replicator sidecar, only when somewhere to ship to is configured:
  # `config :blazie, :replication, dir: ..., replica_url: ...`. Off in test —
  # tests that want one start it themselves with their own scratch replica.
  defp replication do
    case Application.get_env(:blazie, :replication) do
      nil -> []
      opts -> [{Blazie.Replication, opts}]
    end
  end

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Blazie.Registry},
        # Who to tell when a world appends. Duplicate keys: many watchers per
        # world. A plain Registry rather than Phoenix.PubSub keeps the core free
        # of the surface's dependencies.
        {Registry, keys: :duplicate, name: Blazie.Watchers},
        {DynamicSupervisor, name: Blazie.WorldSupervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: Blazie.SubscriptionSupervisor, strategy: :one_for_one},
        # After the ledgers, because it reconciles against erasure tombstones
        # when it opens and those live in one.
        Blazie.Keyring,
        # One engine for every world: it caches by formula and snapshot name,
        # and a name already says which ledgers it composed.
        {Blazie.Formula.Engine, name: Blazie.Formula.Engine},
        # The one bucket per vendor account. A vendor's rate limit is global
        # by definition, so it has to be held somewhere that sees every
        # Studio's traffic — here, before any provider does.
        Blazie.Limit,
        # Owns the exact index's ETS tables for the node's lifetime. In the
        # tree because an unlinked owner dying silently emptied every space —
        # searches answered [] instead of erroring, which is the one failure
        # an index must not have.
        Blazie.Index.Exact.holder_spec(),
        {Phoenix.PubSub, name: Blazie.PubSub},
        Blazie.Surface.Endpoint
      ] ++ vitals() ++ storage() ++ agents() ++ backup() ++ drill() ++ replication()

    # Three restarts in five seconds is too tight for a system where restarting
    # a component is a legitimate operation rather than only a symptom. Ten
    # still catches a genuine crash loop; three caught ordinary use.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Blazie.Supervisor,
      max_restarts: 10,
      max_seconds: 5
    )
  end
end
