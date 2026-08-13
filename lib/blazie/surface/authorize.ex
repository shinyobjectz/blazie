defmodule Blazie.Surface.Authorize do
  @moduledoc """
  The plug that decides which ledgers a caller may name (doctrine 17).

  ## Why open is not the only checkpoint

  A snapshot name is a plain map — which ledgers, at which transaction — and a
  caller can write one by hand. So checking only at `open` would mean a caller
  could reach any ledger by inventing a name for it. Every operation that names
  a ledger is checked, and a test forges a name to prove it.

  The doctrine still holds as written: authorization is *which ledgers a caller
  may name*. Naming is what `ask` and `write` also do.

  ## Refusals say which

  A refusal names the ledger that failed, because a caller holding several
  grants otherwise cannot tell which one it is missing. That leaks the ledger
  name back to a caller who already sent it, and nothing else.
  """

  import Plug.Conn

  alias Blazie.Authority

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case token(conn) do
      {:ok, token} -> authorize(conn, token, named(conn, opts))
      :error -> deny(conn, 401, :no_token, "Present a token: Authorization: Bearer <token>.")
    end
  end

  defp authorize(conn, token, ledgers) do
    ledgers
    |> Enum.reject(&Authority.may_name?(token, &1))
    |> case do
      [] ->
        assign(conn, :caller, token)

      [refused | _] ->
        deny(
          conn,
          403,
          :not_granted,
          "This caller may not name #{inspect(refused)}. Grant it, or name only what it holds."
        )
    end
  end

  # Every place a ledger can be named, in one list — so adding an operation
  # that names one and forgetting to check it is a change here, not an omission.
  # Claiming a name is the one operation whose whole point is to name a ledger
  # this caller does not hold yet, so checking the grant first would refuse
  # every request it is meant to serve. It still needs a valid token — the
  # check that is dropped is authorization, never authentication — and the
  # operation itself is responsible for refusing a name already taken.
  defp named(_conn, names: false), do: []
  defp named(conn, _opts), do: named(conn)

  defp named(%{params: params}) do
    [
      names(Map.get(params, "ledgers")),
      keys(Map.get(params, "name")),
      List.wrap(Map.get(params, "ledger"))
    ]
    |> List.flatten()
    |> Enum.uniq()
  end

  # A hostile caller sends whatever it likes, and this runs before anything has
  # validated the shape. Anything that is not a name is not a name — the
  # operation refuses it on its own terms, and nothing here may crash first.
  defp names(list) when is_list(list), do: list
  defp names(_), do: []

  defp keys(map) when is_map(map), do: Map.keys(map)
  defp keys(_), do: []

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp deny(conn, status, problem, repair) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{"error" => %{"problem" => to_string(problem), "repair" => repair}})
    )
    |> halt()
  end
end
