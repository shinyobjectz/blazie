defmodule LazyRiver.SurfaceAuthorizationTest do
  @moduledoc """
  Doctrine 17 at the door.

  A snapshot name is a plain map, so it can be forged — which means `open`
  cannot be the only checkpoint. Every operation that names a ledger checks,
  and the test below forges a name to prove it.
  """
  use LazyRiver.ConnCase, async: true

  alias LazyRiver.Authority

  setup do
    token = "surface-token-#{System.unique_integer([:positive])}"
    granted = open_ledger()
    ungranted = open_ledger()

    Authority.grant(token, granted)
    define(granted, "height", answers: "integer")
    define(ungranted, "height", answers: "integer")

    %{token: token, granted: granted, ungranted: ungranted}
  end

  defp as(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  describe "a caller must present a token" do
    test "no token is refused", %{conn: conn, granted: granted} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/open", %{"ledgers" => [granted]})

      assert %{"error" => error} = json_response(conn, 401)
      assert error["problem"] == "no_token"
      assert error["repair"] =~ "Authorization"
    end

    test "a token with no grants can name nothing", %{conn: conn, granted: granted} do
      conn = conn |> as("a-token-nobody-granted") |> post("/open", %{"ledgers" => [granted]})

      assert %{"error" => error} = json_response(conn, 403)
      assert error["problem"] == "not_granted"
    end
  end

  describe "open checks every ledger named" do
    test "a granted ledger opens", %{conn: conn, token: token, granted: granted} do
      conn = conn |> as(token) |> post("/open", %{"ledgers" => [granted]})

      assert %{"name" => _} = json_response(conn, 200)
    end

    test "one ungranted ledger refuses the whole request",
         %{conn: conn, token: token, granted: granted, ungranted: ungranted} do
      conn = conn |> as(token) |> post("/open", %{"ledgers" => [granted, ungranted]})

      assert %{"error" => error} = json_response(conn, 403)
      assert error["repair"] =~ ungranted
    end
  end

  describe "a forged name does not get past ask" do
    test "naming an ungranted ledger in a snapshot name is refused",
         %{conn: conn, token: token, ungranted: ungranted} do
      # Never returned by open — written by hand, which is the whole point.
      forged = %{ungranted => 0}

      conn = conn |> as(token) |> post("/ask", %{"name" => forged, "pattern" => %{}})

      assert %{"error" => error} = json_response(conn, 403)
      assert error["problem"] == "not_granted"
    end

    test "a name mixing granted and ungranted is refused whole",
         %{conn: conn, token: token, granted: granted, ungranted: ungranted} do
      forged = %{granted => 0, ungranted => 0}

      conn = conn |> as(token) |> post("/ask", %{"name" => forged, "pattern" => %{}})

      assert %{"error" => _} = json_response(conn, 403)
    end
  end

  describe "write checks too" do
    test "writing to a granted ledger works", %{conn: conn, token: token, granted: granted} do
      conn =
        conn
        |> as(token)
        |> post("/write", %{
          "ledger" => granted,
          "facts" => [%{"id" => 1, "attribute" => "height", "answer" => 180}]
        })

      assert %{"name" => _} = json_response(conn, 200)
    end

    test "writing to an ungranted ledger is refused",
         %{conn: conn, token: token, ungranted: ungranted} do
      conn =
        conn
        |> as(token)
        |> post("/write", %{
          "ledger" => ungranted,
          "facts" => [%{"id" => 1, "attribute" => "height", "answer" => 180}]
        })

      assert %{"error" => error} = json_response(conn, 403)
      assert error["problem"] == "not_granted"
    end
  end

  describe "revoking takes effect on the next request" do
    test "a revoked caller stops getting in", %{conn: conn, token: token, granted: granted} do
      assert %{"name" => _} =
               json_response(conn |> as(token) |> post("/open", %{"ledgers" => [granted]}), 200)

      Authority.revoke(token, granted)

      assert %{"error" => _} =
               json_response(conn |> as(token) |> post("/open", %{"ledgers" => [granted]}), 403)
    end
  end

  describe "the authority ledger is never reachable" do
    test "not even by a caller granted it", %{conn: conn, token: token} do
      Authority.grant(token, Authority.ledger())

      conn = conn |> as(token) |> post("/open", %{"ledgers" => [Authority.ledger()]})

      assert %{"error" => _} = json_response(conn, 403)
    end
  end
end
