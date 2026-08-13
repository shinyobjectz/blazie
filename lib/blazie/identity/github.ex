defmodule Blazie.Identity.GitHub do
  @moduledoc """
  The three calls GitHub's OAuth needs, and nothing else.

  A behaviour rather than a module of functions, for the same reason
  `Blazie.Keyring` is one: a test must be able to answer as GitHub without a
  network, and the alternative is a suite that either talks to a real vendor or
  proves nothing.

  Signed and parsed by hand — `:httpc` and `Jason`, no SDK — which is the same
  bargain `Keyring.GCP` takes. GitHub's OAuth is three form posts.
  """

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "Exchange an authorization code for a user access token."
  @callback exchange(code :: String.t()) :: {:ok, String.t()} | {:error, refusal()}

  @doc "Start a device flow: what to show a human, and what to poll with."
  @callback begin_device() :: {:ok, map()} | {:error, refusal()}

  @doc """
  Ask whether a device code has been authorized yet.

  `:authorization_pending` is the ordinary answer, not a failure — it is what
  the CLI polls through while a human is still typing the code.
  """
  @callback poll_device(device_code :: String.t()) ::
              {:ok, String.t()} | {:pending, pos_integer() | nil} | {:error, refusal()}

  @doc "Who a user access token belongs to."
  @callback login(token :: String.t()) :: {:ok, String.t()} | {:error, refusal()}
end

defmodule Blazie.Identity.GitHub.Live do
  @moduledoc """
  GitHub, actually.

  The client secret is read at call time rather than held, so a deployment that
  rotates it does not have to restart — and so a test that forgets to configure
  one gets a refusal naming the setting rather than a `nil` three frames later.
  """

  @behaviour Blazie.Identity.GitHub

  @token_url ~c"https://github.com/login/oauth/access_token"
  @device_url ~c"https://github.com/login/device/code"
  @user_url ~c"https://api.github.com/user"

  # The scope a device flow asks for. `read:user` is enough to learn a login,
  # and asking for more would be asking for what we do not use.
  @scope "read:user"

  @impl true
  def exchange(code) do
    with {:ok, id} <- client_id(),
         {:ok, secret} <- client_secret() do
      @token_url
      |> post_form(%{"client_id" => id, "client_secret" => secret, "code" => code})
      |> case do
        {:ok, %{"access_token" => token}} -> {:ok, token}
        {:ok, %{"error" => error} = body} -> {:error, refused(error, body)}
        {:ok, _} -> {:error, refused("no_token", %{})}
        error -> error
      end
    end
  end

  @impl true
  def begin_device do
    with {:ok, id} <- client_id() do
      @device_url
      |> post_form(%{"client_id" => id, "scope" => @scope})
      |> case do
        {:ok, %{"device_code" => _} = body} ->
          {:ok,
           %{
             device_code: body["device_code"],
             user_code: body["user_code"],
             verification_uri: body["verification_uri"],
             interval: body["interval"] || 5,
             expires_in: body["expires_in"] || 900
           }}

        {:ok, %{"error" => "device_flow_disabled"} = body} ->
          {:error,
           %{
             problem: :device_flow_disabled,
             repair:
               "This OAuth app has device flow turned off. Tick “Enable Device Flow” on " <>
                 "its settings page at github.com/settings/developers. (#{inspect(body)})"
           }}

        {:ok, %{"error" => error} = body} ->
          {:error, refused(error, body)}

        error ->
          error
      end
    end
  end

  @impl true
  def poll_device(device_code) do
    with {:ok, id} <- client_id() do
      @token_url
      |> post_form(%{
        "client_id" => id,
        "device_code" => device_code,
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
      })
      |> case do
        {:ok, %{"access_token" => token}} -> {:ok, token}
        # The two answers that mean "keep waiting" rather than "give up".
        {:ok, %{"error" => "authorization_pending"}} -> {:pending, nil}
        {:ok, %{"error" => "slow_down"} = body} -> {:pending, body["interval"] || 10}
        {:ok, %{"error" => error} = body} -> {:error, refused(error, body)}
        error -> error
      end
    end
  end

  @impl true
  def login(token) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"user-agent", ~c"blazie"}
    ]

    case :httpc.request(:get, {@user_url, headers}, [{:timeout, 15_000}], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(body) do
          {:ok, %{"login" => login}} -> {:ok, login}
          _ -> {:error, refused("no_login", %{})}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error,
         %{problem: :github_refused, repair: "GitHub answered #{status}: #{to_string(body)}"}}

      {:error, why} ->
        {:error,
         %{problem: :github_unreachable, repair: "Could not reach GitHub: #{inspect(why)}"}}
    end
  end

  # ── the one shape all three posts take ─────────────────────────────────────

  defp post_form(url, params) do
    body = URI.encode_query(params)
    headers = [{~c"accept", ~c"application/json"}, {~c"user-agent", ~c"blazie"}]
    request = {url, headers, ~c"application/x-www-form-urlencoded", body}

    case :httpc.request(:post, request, [{:timeout, 15_000}], body_format: :binary) do
      {:ok, {{_, 200, _}, _, response}} ->
        Jason.decode(response)

      {:ok, {{_, status, _}, _, response}} ->
        {:error,
         %{problem: :github_refused, repair: "GitHub answered #{status}: #{to_string(response)}"}}

      {:error, why} ->
        {:error,
         %{problem: :github_unreachable, repair: "Could not reach GitHub: #{inspect(why)}"}}
    end
  end

  defp client_id do
    case Application.get_env(:blazie, :github_client_id) do
      nil -> {:error, missing("GITHUB_CLIENT_ID")}
      id -> {:ok, id}
    end
  end

  defp client_secret do
    case Application.get_env(:blazie, :github_client_secret) do
      nil -> {:error, missing("GITHUB_CLIENT_SECRET")}
      secret -> {:ok, secret}
    end
  end

  defp missing(name) do
    %{
      problem: :not_configured,
      repair: "#{name} is not set, so this node cannot speak to GitHub on anyone's behalf."
    }
  end

  defp refused(error, body) do
    %{
      problem: String.to_atom(error),
      repair: "GitHub refused: #{error}. #{body["error_description"] || ""}" |> String.trim()
    }
  end
end
