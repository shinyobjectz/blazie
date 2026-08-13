defmodule LazyRiver.Application do
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
    case Application.get_env(:lazy_river, :vitals_every) do
      nil -> []
      every -> [{LazyRiver.Vitals, every: every}]
    end
  end

  # Only when there is somewhere to put the bytes. A backup job with no target
  # is a crash loop at boot rather than a backup — and the failure a deployment
  # must never have is the one where it looks configured and copies nothing.
  defp backup do
    case Application.get_env(:lazy_river, :backup_target) do
      nil -> []
      _target -> [{LazyRiver.Backup, every: Application.get_env(:lazy_river, :backup_every, 900)}]
    end
  end

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: LazyRiver.Registry},
        # Who to tell when a ledger appends. Duplicate keys: many watchers per
        # ledger. A plain Registry rather than Phoenix.PubSub keeps the core free
        # of the surface's dependencies.
        {Registry, keys: :duplicate, name: LazyRiver.Watchers},
        {DynamicSupervisor, name: LazyRiver.LedgerSupervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: LazyRiver.SubscriptionSupervisor, strategy: :one_for_one},
        # After the ledgers, because it reconciles against erasure tombstones
        # when it opens and those live in one.
        LazyRiver.Keyring,
        # One engine for every ledger: it caches by formula and snapshot name,
        # and a name already says which ledgers it composed.
        {LazyRiver.Formula.Engine, name: LazyRiver.Formula.Engine},
        {Phoenix.PubSub, name: LazyRiver.PubSub},
        LazyRiver.Surface.Endpoint
      ] ++ vitals() ++ backup()

    # Three restarts in five seconds is too tight for a system where restarting
    # a component is a legitimate operation rather than only a symptom. Ten
    # still catches a genuine crash loop; three caught ordinary use.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: LazyRiver.Supervisor,
      max_restarts: 10,
      max_seconds: 5
    )
  end
end
