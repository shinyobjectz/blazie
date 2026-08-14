defmodule Blazie.Authority do
  @moduledoc """
  Which ledgers a caller may name (doctrine 17).

  Not row rules and not predicates — a caller either may name a world or may
  not, decided before anything is read. There is no filter to remember, because
  there is no query that spans ledgers you did not name.

  ## Grants are facts

  They live in a world like everything else, so revoking is a later fact
  correcting an earlier one and nothing is deleted. "Who could open what, and
  when" is a question rather than an audit log someone remembered to write.

      grant("token", "tenant-7")    #  {caller, "may_name", "tenant-7"}
      revoke("token", "tenant-7")   #  {caller, "revoked",  "tenant-7"}

  Whichever of those landed later is the answer, so grant → revoke → grant
  works without any of them being removed.

  ## Three ledgers are never nameable, and the rule says which

  The structurally unnameable set is the set of ledgers whose contents change
  authorization or key state — a caller who could write one could widen what
  callers may do, which no grant is allowed to mean.

  `$authority` holds the answer to "what may this caller name," so a caller
  who could name it could grant itself everything. `$erasures` holds the
  tombstones the keyring reconciles against every time it opens — so a caller
  who could write one forged `erased_at` fact would destroy another tenant's
  keys, remotely and irreversibly, and a caller who could READ it would be
  reading who has exercised a deletion right, which is itself personal data.
  `$backup` holds the record of what was copied where, which is what the next
  incremental copy and every restore steer by.

  All three are excluded structurally rather than by policy: `may_name?/2`
  refuses before consulting any grant, and `grant_checked/2` refuses to write
  the grant in the first place — absent rather than forbidden.

  ## A caller is a token's fingerprint

  Grants are keyed by `sha256` of the presented token, so the world holds no
  secret. A stolen world reveals which fingerprints could name what, and no
  token. The token is still a bearer credential — anyone holding it is the
  caller — which is the right shape for a substrate and the wrong one for a
  public API. An identity behind the token is the next step, not this one.
  """

  alias Blazie.{Attribute, World, Snapshot}

  @world "$authority"
  @may_name "may_name"
  @revoked "revoked"

  # Literals, deliberately: `Erasure.world/0` and `Backup` exist, but a
  # reserved set that called out to them would move when they moved, and a
  # rename that silently made a ledger nameable is the failure this list
  # exists to prevent. A test pins each module's own answer to this list.
  @reserved [@world, "$erasures", "$backup"]

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The world holding grants. Never nameable by a caller."
  @spec world() :: String.t()
  def world, do: @world

  @doc "A caller's identity: the fingerprint of the token it presented."
  @spec caller(String.t()) :: String.t()
  def caller(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc "The ledgers no caller may ever name: they change authorization or key state."
  @spec reserved() :: [String.t()]
  def reserved, do: @reserved

  @doc "May this caller name this world?"
  @spec may_name?(String.t(), World.name()) :: boolean()
  def may_name?(_token, world) when world in @reserved, do: false

  def may_name?(token, world) do
    case latest(caller(token), world) do
      %{attribute: @may_name} -> true
      _ -> false
    end
  end

  @doc "Every world this caller may name."
  @spec allowed(String.t()) :: [World.name()]
  def allowed(token) do
    who = caller(token)

    snapshot()
    |> Snapshot.find(id: who)
    |> Enum.map(& &1.value)
    |> Enum.uniq()
    |> Enum.filter(&(&1 != @world))
    |> Enum.filter(fn world -> match?(%{attribute: @may_name}, latest(who, world)) end)
    |> Enum.sort()
  end

  @doc "Grant a caller the right to name a world."
  @spec grant(String.t(), World.name()) :: {:ok, pos_integer()}
  def grant(token, world), do: write(caller(token), @may_name, world)

  @doc """
  Grant, refusing the one grant that must never exist.

  Granting the authority world would let a caller grant itself everything, so
  it is refused where it is written rather than only where it is read.
  """
  @spec grant_checked(String.t(), World.name()) :: {:ok, pos_integer()} | {:error, refusal()}
  def grant_checked(_token, world) when world in @reserved,
    do:
      {:error,
       %{
         problem: :not_nameable,
         repair:
           "#{inspect(world)} changes what callers may do — grants, tombstones, or the record " <>
             "a restore steers by — so no caller may ever name it, whoever asks. Grant the " <>
             "ledgers the caller should reach instead."
       }}

  def grant_checked(token, world), do: grant(token, world)

  @doc "Revoke by writing a later fact. Nothing is deleted."
  @spec revoke(String.t(), World.name()) :: {:ok, pos_integer()}
  def revoke(token, world), do: write(caller(token), @revoked, world)

  @doc "Every grant and revocation for this caller and world, oldest first."
  @spec history(String.t(), World.name()) :: [Blazie.Fact.t()]
  def history(token, world) do
    snapshot()
    |> Snapshot.find(id: caller(token))
    |> Enum.filter(&(&1.value == world))
  end

  @doc "The attributes the authority describes itself with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Attribute.define(@may_name, answers: "name", cardinality: "many") ++
      Attribute.define(@revoked, answers: "name", cardinality: "many")
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp latest(who, world) do
    snapshot()
    |> Snapshot.find(id: who)
    |> Enum.filter(&(&1.value == world and &1.attribute in [@may_name, @revoked]))
    |> Enum.max_by(& &1.tx, fn -> nil end)
  end

  defp write(who, attribute, world) do
    {:ok, ref} = open()
    World.append(ref, [{who, attribute, world}])
  end

  defp snapshot, do: Snapshot.open([elem(open(), 1)])

  defp open do
    {:ok, ref} = World.open(@world)

    # Seed once: the authority describes itself with ordinary attributes.
    if World.tx(ref) == 0, do: World.append(ref, Attribute.seed() ++ seed())

    {:ok, ref}
  end
end
