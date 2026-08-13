defmodule Blazie.SurfaceAuthorizationTest do
  @moduledoc """
  Doctrine 17 at the door.

  A caller may name some ledgers and not others, and that is decided before
  anything is read. The interesting cases are the ways a request can name one
  without looking like it: a snapshot name is a plain map a caller writes by
  hand, and `also` is a list a caller supplies. Both are checked, and both are
  forged below to prove it.

  When the three verbs became `run`, `also` arrived as a new way to name a
  world and the plug did not know about it — a caller could have read any
  world on the cluster by listing it there. The test for it is first.
  """
  use Blazie.ConnCase, async: true

  alias Blazie.Authority

  setup do
    token = "surface-token-#{System.unique_integer([:positive])}"
    granted = open_ledger()
    ungranted = open_ledger()

    Authority.grant(token, granted)

    %{token: token, granted: granted, ungranted: ungranted}
  end

  defp as(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp run(conn, token, params),
    do: conn |> as(token) |> post("/run", Map.put_new(params, "source", "return 1"))

  describe "every way a request can name a world is checked" do
    test "`world` is checked", %{conn: conn, token: token, ungranted: ungranted} do
      assert %{"error" => error} =
               json_response(run(conn, token, %{"world" => ungranted}), 403)

      assert error["problem"] == "not_granted"
    end

    test "`also` is checked", %{
      conn: conn,
      token: token,
      granted: granted,
      ungranted: ungranted
    } do
      # The read world is `world` plus `also`, so an unchecked `also` is a way
      # to read any world on the cluster while naming only your own.
      assert %{"error" => error} =
               json_response(
                 run(conn, token, %{"world" => granted, "also" => [ungranted]}),
                 403
               )

      assert error["problem"] == "not_granted"
      assert error["repair"] =~ ungranted
    end

    test "a forged `name` is checked", %{
      conn: conn,
      token: token,
      granted: granted,
      ungranted: ungranted
    } do
      # Never returned by anything — written by hand, which is the point.
      forged = %{granted => 0, ungranted => 0}

      assert %{"error" => error} =
               json_response(run(conn, token, %{"world" => granted, "name" => forged}), 403)

      assert error["problem"] == "not_granted"
    end

    test "naming one ungranted world refuses the whole request", %{
      conn: conn,
      token: token,
      granted: granted,
      ungranted: ungranted
    } do
      assert %{"error" => error} =
               json_response(
                 run(conn, token, %{"world" => granted, "also" => [granted, ungranted]}),
                 403
               )

      # The refusal says which one, because a caller holding several grants
      # otherwise cannot tell what it is missing.
      assert error["repair"] =~ ungranted
    end
  end

  describe "a caller must present a token" do
    test "no token is refused", %{conn: conn, granted: granted} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/run", %{"world" => granted, "source" => "return 1"})

      assert %{"error" => error} = json_response(conn, 401)
      assert error["problem"] == "no_token"
      assert error["repair"] =~ "Authorization"
    end

    test "a token nobody granted can name nothing", %{conn: conn, granted: granted} do
      assert %{"error" => error} =
               json_response(run(conn, "a-token-nobody-granted", %{"world" => granted}), 403)

      assert error["problem"] == "not_granted"
    end
  end

  describe "a granted caller gets in" do
    test "and can read its own world", %{conn: conn, token: token, granted: granted} do
      assert %{"value" => 1} =
               json_response(run(conn, token, %{"world" => granted}), 200)
    end

    test "and can write to it", %{conn: conn, token: token, granted: granted} do
      body =
        json_response(
          run(conn, token, %{"world" => granted, "source" => "ada.height = 180"}),
          200
        )

      assert body["wrote"] > 0
      assert %{^granted => _tx} = body["name"]
    end

    test "writing to an ungranted world is refused", %{
      conn: conn,
      token: token,
      ungranted: ungranted
    } do
      assert %{"error" => error} =
               json_response(
                 run(conn, token, %{"world" => ungranted, "source" => "ada.height = 180"}),
                 403
               )

      assert error["problem"] == "not_granted"
    end
  end

  describe "revoking takes effect on the next request" do
    test "a revoked caller stops getting in", %{conn: conn, token: token, granted: granted} do
      assert %{"value" => 1} = json_response(run(conn, token, %{"world" => granted}), 200)

      Authority.revoke(token, granted)

      assert %{"error" => _} =
               json_response(run(build_conn(), token, %{"world" => granted}), 403)
    end
  end
end
