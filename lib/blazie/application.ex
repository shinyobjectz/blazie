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
  # a process pulling a ledger down onto a node's scratch disk on a timer.
  defp drill do
    case {Application.get_env(:blazie, :backup_target),
          Application.get_env(:blazie, :drill_every)} do
      {nil, _every} -> []
      {_target, nil} -> []
      {_target, every} -> [{Blazie.Drill, every: every}]
    end
  end

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Blazie.Registry},
        # Who to tell when a ledger appends. Duplicate keys: many watchers per
        # ledger. A plain Registry rather than Phoenix.PubSub keeps the core free
        # of the surface's dependencies.
        {Registry, keys: :duplicate, name: Blazie.Watchers},
        {DynamicSupervisor, name: Blazie.LedgerSupervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: Blazie.SubscriptionSupervisor, strategy: :one_for_one},
        # After the ledgers, because it reconciles against erasure tombstones
        # when it opens and those live in one.
        Blazie.Keyring,
        # One engine for every ledger: it caches by formula and snapshot name,
        # and a name already says which ledgers it composed.
        {Blazie.Formula.Engine, name: Blazie.Formula.Engine},
        {Phoenix.PubSub, name: Blazie.PubSub},
        Blazie.Surface.Endpoint
      ] ++ vitals() ++ backup() ++ drill()

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
