defmodule Blazie.Identity do
  @moduledoc """
  Who a token belongs to.

  `Blazie.Authority` already knew what a token may *name*; it deliberately did
  not know who was holding it, and said so — "an identity behind the token is
  the next step, not this one." This is that step, and it changes nothing about
  how authorization works: a caller is still the fingerprint of its token, and
  a grant is still a fact.

  What is new is where tokens come from. They are no longer conjured and handed
  out; a token is minted only after GitHub says who asked for it, and the
  minting is recorded as facts like everything else.

      {caller, "is",           "identity"}
      {caller, "github_login", "shinyobjectz"}
      {caller, "issued_at",    1786634000}

  ## Two flows, one door

  A browser has a redirect and a code; a terminal has neither, so it shows a
  human a short code to type somewhere else. Both end at `admit/1`, which is
  the only place a token is made — so the rule about who may have one is
  written once.

  ## The allowlist is the whole access policy, for now

  `:github_logins` names who may hold a token. It is deliberately a list rather
  than "anyone with a GitHub account": this runs one node holding one person's
  data, and an open door would be a different product. An empty list admits
  nobody and says so, which is the right failure for a setting somebody forgot.

  ## What a token is, and is not

  It is a bearer credential: whoever holds it is the caller. The ledger stores
  only its fingerprint, so a leaked ledger leaks no tokens — but a leaked token
  is the caller until it is revoked. That was true before GitHub was involved
  and is no less true now.
  """

  alias Blazie.{Authority, Ledger, Snapshot}

  @ledger "$identities"
  @is "is"
  @login "github_login"
  @issued "issued_at"

  @type refusal :: %{problem: atom(), repair: String.t()}
  @type admitted :: %{token: String.t(), login: String.t()}

  @doc "The ledger identities are recorded in."
  @spec ledger() :: String.t()
  def ledger, do: @ledger

  @doc "The attributes an identity is described with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Blazie.Attribute.define(@login, answers: "name") ++
      Blazie.Attribute.define(@issued, answers: "integer")
  end

  # ── the browser's way in ───────────────────────────────────────────────────

  @doc """
  Trade GitHub's authorization code for a blazie token.

  The code arrives at the callback page in a query string, which is why the
  exchange happens here and not there: the client secret never leaves this
  node, and a static site could not hold one anyway.
  """
  @spec from_code(String.t(), keyword()) :: {:ok, admitted()} | {:error, refusal()}
  def from_code(code, opts \\ []) when is_binary(code) do
    github = github(opts)

    with {:ok, github_token} <- github.exchange(code),
         {:ok, login} <- github.login(github_token) do
      admit(login, opts)
    end
  end

  # ── the terminal's way in ──────────────────────────────────────────────────

  @doc """
  Begin a device flow, and hand back what a human has to be shown.

  Nothing is recorded here. A device code is GitHub's to remember, and a
  half-finished sign-in is not a fact about anybody.
  """
  @spec begin_device(keyword()) :: {:ok, map()} | {:error, refusal()}
  def begin_device(opts \\ []), do: github(opts).begin_device()

  @doc """
  Ask whether a device code has been authorized, and mint a token if it has.

  `{:pending, interval}` is the ordinary answer while a human is still typing.
  The interval comes back because GitHub asks callers to slow down under load,
  and a CLI that ignores that gets refused outright.
  """
  @spec from_device(String.t(), keyword()) ::
          {:ok, admitted()} | {:pending, pos_integer() | nil} | {:error, refusal()}
  def from_device(device_code, opts \\ []) when is_binary(device_code) do
    github = github(opts)

    case github.poll_device(device_code) do
      {:ok, github_token} ->
        with {:ok, login} <- github.login(github_token), do: admit(login, opts)

      other ->
        other
    end
  end

  # ── the one door ───────────────────────────────────────────────────────────

  @doc """
  Mint a token for a GitHub login, if that login is allowed one.

  The only place a token is made, so the rule about who may have one is written
  once rather than in each flow.
  """
  @spec admit(String.t(), keyword()) :: {:ok, admitted()} | {:error, refusal()}
  def admit(login, opts \\ []) when is_binary(login) do
    allowed = allowed_logins(opts)

    cond do
      allowed == [] ->
        {:error,
         %{
           problem: :nobody_is_allowed,
           repair:
             "No GitHub login is allowed to hold a token here. Set GITHUB_LOGINS to who may — " <>
               "an empty list admits nobody, which is the right answer for a setting " <>
               "somebody forgot rather than a door left open."
         }}

      login not in allowed ->
        {:error,
         %{
           problem: :not_allowed,
           repair:
             "#{login} is not allowed to hold a token here. Add it to GITHUB_LOGINS if it " <>
               "should be."
         }}

      true ->
        {:ok, mint(login)}
    end
  end

  @doc "The GitHub login a token belongs to, or nil."
  @spec login_of(String.t()) :: String.t() | nil
  def login_of(token) when is_binary(token) do
    {:ok, ledger} = Ledger.open(@ledger)
    Snapshot.value(Snapshot.open([ledger]), Authority.caller(token), @login)
  end

  @doc "Every login that currently holds at least one token."
  @spec admitted() :: [String.t()]
  def admitted do
    {:ok, ledger} = Ledger.open(@ledger)

    Snapshot.open([ledger])
    |> Snapshot.find(attribute: @login)
    |> Enum.map(& &1.value)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A token is 32 bytes of randomness, url-safe so it survives a header, a
  # query string and a config file without anybody having to think about it.
  defp mint(login) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    caller = Authority.caller(token)

    {:ok, ledger} = Ledger.open(@ledger)

    if Ledger.tx(ledger) == 0 do
      Ledger.append(ledger, Blazie.Attribute.seed() ++ seed())
    end

    Ledger.append(ledger, [
      {caller, @is, "identity"},
      {caller, @login, login},
      {caller, @issued, System.system_time(:second)}
    ])

    %{token: token, login: login}
  end

  defp github(opts) do
    Keyword.get(opts, :github) ||
      Application.get_env(:blazie, :github, Blazie.Identity.GitHub.Live)
  end

  defp allowed_logins(opts) do
    Keyword.get(opts, :github_logins) || Application.get_env(:blazie, :github_logins, [])
  end
end
