defmodule Blazie.Surface.IdentityController do
  @moduledoc """
  Signing in, from a browser or from a terminal.

  These are the only routes that are not behind a token, because they are how a
  token is got. Everything else stays behind `Authorize`.

  The browser flow ends here rather than at the callback page on purpose: the
  client secret lives on this node, a static site cannot hold one, and a token
  minted anywhere else would be a token this node did not decide to issue.
  """

  use Phoenix.Controller, formats: [:json]

  alias Blazie.{Authority, Identity}

  @doc "Trade GitHub's authorization code for a token."
  def github(conn, %{"code" => code}) when is_binary(code) do
    case Identity.from_code(code) do
      {:ok, admitted} -> json(conn, %{"token" => admitted.token, "login" => admitted.login})
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  def github(conn, _params),
    do: refuse(conn, %{problem: :no_code, repair: "Send the `code` GitHub redirected with."})

  @doc "Begin a device flow. Nothing is recorded until it completes."
  def device(conn, _params) do
    case Identity.begin_device() do
      {:ok, began} ->
        json(conn, %{
          "device_code" => began.device_code,
          "user_code" => began.user_code,
          "verification_uri" => began.verification_uri,
          "interval" => began.interval,
          "expires_in" => began.expires_in
        })

      {:error, refusal} ->
        refuse(conn, refusal)
    end
  end

  @doc """
  Poll a device flow.

  `202` for pending rather than an error, because a human still typing is not a
  failure and a CLI should not have to read a message to tell the difference.
  """
  def device_token(conn, %{"device_code" => code}) when is_binary(code) do
    case Identity.from_device(code) do
      {:ok, admitted} ->
        json(conn, %{"token" => admitted.token, "login" => admitted.login})

      {:pending, interval} ->
        conn
        |> put_status(:accepted)
        |> json(%{"status" => "authorization_pending", "interval" => interval})

      {:error, refusal} ->
        refuse(conn, refusal)
    end
  end

  def device_token(conn, _params),
    do:
      refuse(conn, %{problem: :no_device_code, repair: "Send the `device_code` you were given."})

  @doc "Who this token is, and what it may name."
  def me(conn, _params) do
    token = conn.assigns[:caller]

    json(conn, %{
      "login" => Identity.login_of(token),
      "caller" => Authority.caller(token),
      "worlds" => Authority.allowed(token)
    })
  end

  defp refuse(conn, refusal) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      "error" => %{"problem" => to_string(refusal.problem), "repair" => refusal.repair}
    })
  end
end
