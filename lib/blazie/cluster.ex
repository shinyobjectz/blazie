defmodule Blazie.Cluster do
  @moduledoc """
  One ledger, one owner.

  Distribution is not implemented and is deliberately not implemented — a
  substrate on one node is the right shape for now, and doing it properly is
  real design work rather than a switch. What is implemented is the one thing
  that has to exist *before* a second node does, because adding one without it
  would be worse than not adding one at all.

  ## The failure this exists to prevent

  Two nodes both open ledger `tenant-7`. Each starts its own process, each
  appends, each is certain it holds the history. Now there are two ledgers with
  the same name and different contents, and an answer at a name depends on
  which node you asked — which is the guarantee everything else here rests on,
  broken silently and irrecoverably.

  So a ledger's name is claimed across the cluster when it opens. A claim
  somebody else holds is refused with its repair, rather than quietly forking.

  ## Why `:global` and not something better

  It is in OTP, it needs no dependency, it drops a claim automatically when the
  holder dies, and claiming happens once per open rather than per operation.
  Its weaknesses are real and they are weaknesses of *distribution*, which is
  not here yet: it resolves netsplits by choosing, and choosing is exactly the
  decision a real design has to make deliberately. Replacing it is part of
  doing distribution properly, not a prerequisite for this.
  """

  @type name :: term()
  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "Which node owns this ledger, or nil if nobody has claimed it."
  @spec owner(name()) :: node() | nil
  def owner(name) do
    case :global.whereis_name(key(name)) do
      :undefined -> nil
      pid -> node(pid)
    end
  end

  @doc "Is this ledger ours to run?"
  @spec owned_here?(name()) :: boolean()
  def owned_here?(name), do: owner(name) == node()

  @doc false
  # Exposed so a test can stand in for another node's ledger process.
  @spec claim_as(name(), pid()) :: :yes | :no
  def claim_as(name, pid), do: :global.register_name(key(name), pid)

  @doc "Give up a claim."
  @spec release(name()) :: :ok
  def release(name) do
    :global.unregister_name(key(name))
    :ok
  end

  @doc "Every node this one can see."
  @spec nodes() :: [node()]
  def nodes, do: [node() | Node.list()]

  @doc """
  Is this actually a cluster?

  False, today, on purpose. Somewhere to look rather than something to assume.
  """
  @spec distributed?() :: boolean()
  def distributed?, do: Node.list() != []

  defp key(name), do: {:blazie_ledger, name}

  @doc "Why a ledger somebody else holds cannot be opened here."
  @spec refusal(name()) :: refusal()
  def refusal(name), do: held_elsewhere(name)

  defp held_elsewhere(name) do
    %{
      problem: :owned_elsewhere,
      repair:
        "#{inspect(name)} is already open on #{inspect(owner(name))}. A ledger has one owner: " <>
          "two of them appending under one name would fork its history, and an answer at a " <>
          "name would depend on which node you asked. Reach it there, or close it there first."
    }
  end
end
