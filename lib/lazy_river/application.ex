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

  @impl true
  def start(_type, _args) do
    children = [
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
      {Phoenix.PubSub, name: LazyRiver.PubSub},
      LazyRiver.Surface.Endpoint
    ]

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
