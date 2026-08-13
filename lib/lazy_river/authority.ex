defmodule LazyRiver.Authority do
  @moduledoc """
  Which ledgers a caller may name (doctrine 17).

  Not row rules and not predicates — a caller either may name a ledger or may
  not, decided before anything is read. There is no filter to remember, because
  there is no query that spans ledgers you did not name.

  ## Grants are facts

  They live in a ledger like everything else, so revoking is a later fact
  correcting an earlier one and nothing is deleted. "Who could open what, and
  when" is a question rather than an audit log someone remembered to write.

      grant("token", "tenant-7")    #  {caller, "may_name", "tenant-7"}
      revoke("token", "tenant-7")   #  {caller, "revoked",  "tenant-7"}

  Whichever of those landed later is the answer, so grant → revoke → grant
  works without any of them being removed.

  ## The authority ledger is never nameable

  It holds the answer to "what may this caller name," so a caller who could
  name it could grant itself everything. It is excluded structurally rather
  than by policy: `may_name?/2` refuses it before consulting any grant, and
  `grant_checked/2` refuses to write the grant in the first place.

  ## A caller is a token's fingerprint

  Grants are keyed by `sha256` of the presented token, so the ledger holds no
  secret. A stolen ledger reveals which fingerprints could name what, and no
  token. The token is still a bearer credential — anyone holding it is the
  caller — which is the right shape for a substrate and the wrong one for a
  public API. An identity behind the token is the next step, not this one.
  """

  alias LazyRiver.{Attribute, Ledger, Snapshot}

  @ledger "$authority"
  @may_name "may_name"
  @revoked "revoked"

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The ledger holding grants. Never nameable by a caller."
  @spec ledger() :: String.t()
  def ledger, do: @ledger

  @doc "A caller's identity: the fingerprint of the token it presented."
  @spec caller(String.t()) :: String.t()
  def caller(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc "May this caller name this ledger?"
  @spec may_name?(String.t(), Ledger.name()) :: boolean()
  def may_name?(_token, @ledger), do: false

  def may_name?(token, ledger) do
    case latest(caller(token), ledger) do
      %{attribute: @may_name} -> true
      _ -> false
    end
  end

  @doc "Every ledger this caller may name."
  @spec allowed(String.t()) :: [Ledger.name()]
  def allowed(token) do
    who = caller(token)

    snapshot()
    |> Snapshot.find(id: who)
    |> Enum.map(& &1.value)
    |> Enum.uniq()
    |> Enum.filter(&(&1 != @ledger))
    |> Enum.filter(fn ledger -> match?(%{attribute: @may_name}, latest(who, ledger)) end)
    |> Enum.sort()
  end

  @doc "Grant a caller the right to name a ledger."
  @spec grant(String.t(), Ledger.name()) :: {:ok, pos_integer()}
  def grant(token, ledger), do: write(caller(token), @may_name, ledger)

  @doc """
  Grant, refusing the one grant that must never exist.

  Granting the authority ledger would let a caller grant itself everything, so
  it is refused where it is written rather than only where it is read.
  """
  @spec grant_checked(String.t(), Ledger.name()) :: {:ok, pos_integer()} | {:error, refusal()}
  def grant_checked(_token, @ledger),
    do:
      {:error,
       %{
         problem: :authority_is_not_nameable,
         repair:
           "The authority ledger holds the answer to what a caller may name, so no caller may " <>
             "name it. Grant the ledgers it should reach instead."
       }}

  def grant_checked(token, ledger), do: grant(token, ledger)

  @doc "Revoke by writing a later fact. Nothing is deleted."
  @spec revoke(String.t(), Ledger.name()) :: {:ok, pos_integer()}
  def revoke(token, ledger), do: write(caller(token), @revoked, ledger)

  @doc "Every grant and revocation for this caller and ledger, oldest first."
  @spec history(String.t(), Ledger.name()) :: [LazyRiver.Fact.t()]
  def history(token, ledger) do
    snapshot()
    |> Snapshot.find(id: caller(token))
    |> Enum.filter(&(&1.value == ledger))
  end

  @doc "The attributes the authority describes itself with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Attribute.define(@may_name, answers: "name", cardinality: "many") ++
      Attribute.define(@revoked, answers: "name", cardinality: "many")
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp latest(who, ledger) do
    snapshot()
    |> Snapshot.find(id: who)
    |> Enum.filter(&(&1.value == ledger and &1.attribute in [@may_name, @revoked]))
    |> Enum.max_by(& &1.tx, fn -> nil end)
  end

  defp write(who, attribute, ledger) do
    {:ok, ref} = open()
    Ledger.append(ref, [{who, attribute, ledger}])
  end

  defp snapshot, do: Snapshot.open([elem(open(), 1)])

  defp open do
    {:ok, ref} = Ledger.open(@ledger)

    # Seed once: the authority describes itself with ordinary attributes.
    if Ledger.tx(ref) == 0, do: Ledger.append(ref, Attribute.seed() ++ seed())

    {:ok, ref}
  end
end
