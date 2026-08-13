defmodule Blazie.AdversarialTest do
  @moduledoc """
  What a caller sends when it is hostile, broken, or merely wrong.

  Everything here goes through the door rather than round it, because a
  boundary is only as good as the worst thing sent at it. A refusal is the
  correct outcome for nearly all of this — what would be a defect is a crash,
  a leak, or a silent success.

  Since the door became `run`, the hostile thing a caller sends is Lua. So the
  second half of this file is a guest trying to get out: spending forever,
  spending everything, reaching the outside, and reaching the host functions the
  world is built from.
  """
  use Blazie.ConnCase, async: true

  alias Blazie.{Authority, Wire}

  setup do
    token = "adversary-#{System.unique_integer([:positive])}"
    ledger = open_ledger()
    Authority.grant(token, ledger)

    %{ledger: ledger, token: token}
  end

  defp as(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp run(conn, token, source, params) do
    conn
    |> as(token)
    |> post("/run", Map.merge(%{"ledger" => params["ledger"], "source" => source}, params))
  end

  describe "malformed requests are refused, never fatal" do
    test "every shape of junk is answered rather than fatal", %{conn: conn, token: token, ledger: ledger} do
      junk = [
        %{},
        %{"ledger" => ledger},
        %{"source" => "return 1"},
        %{"ledger" => ledger, "source" => nil},
        %{"ledger" => ledger, "source" => 12_345},
        %{"ledger" => ledger, "source" => %{"not" => "a string"}},
        %{"ledger" => nil, "source" => "return 1"},
        %{"ledger" => %{"nested" => true}, "source" => "return 1"},
        %{"ledger" => ledger, "source" => "return 1", "also" => "not a list"},
        %{"ledger" => ledger, "source" => "return 1", "also" => [nil]},
        %{"ledger" => ledger, "source" => "return 1", "name" => "not a map"},
        %{"ledger" => ledger, "source" => "return 1", "name" => %{ledger => "three"}},
        %{"ledger" => ledger, "source" => "return 1", "as" => %{}}
      ]

      for body <- junk do
        conn = conn |> as(token) |> post("/run", body)

        assert conn.status in [200, 401, 403, 422],
               "#{inspect(body)} gave #{conn.status}"
      end
    end

    test "source that is not Lua is a refusal with a repair", %{conn: conn, token: token, ledger: ledger} do
      body = json_response(run(conn, token, "this is not lua ((", %{"ledger" => ledger}), 422)

      assert body["error"]["problem"] == "not_lua"
      assert body["error"]["repair"] != ""
    end

    test "an error raised inside Lua is a refusal, not a crash", %{conn: conn, token: token, ledger: ledger} do
      body = json_response(run(conn, token, "error('deliberate')", %{"ledger" => ledger}), 422)

      assert body["error"]["problem"] == "raised"
      assert body["error"]["repair"] =~ "deliberate"
    end
  end

  describe "a caller cannot reach past its grants" do
    test "no way of naming a ledger gets past authorization", %{conn: conn, token: token, ledger: ledger} do
      forbidden = "not-granted-#{System.unique_integer([:positive])}"

      attempts = [
        %{"ledger" => forbidden, "source" => "return 1"},
        %{"ledger" => ledger, "source" => "return 1", "also" => [forbidden]},
        %{"ledger" => ledger, "source" => "return 1", "name" => %{forbidden => 0}},
        %{"ledger" => Authority.ledger(), "source" => "return 1"},
        %{"ledger" => ledger, "source" => "return 1", "also" => [Authority.ledger()]},
        %{"ledger" => ledger, "source" => "return 1", "name" => %{Authority.ledger() => 0}}
      ]

      for body <- attempts do
        conn = conn |> as(token) |> post("/run", body)
        assert conn.status == 403, "#{inspect(body)} gave #{conn.status}"
      end
    end

    test "a token that is not a token is refused", %{conn: conn, ledger: ledger} do
      for bad <- ["", "Bearer", "Basic abc", "Bearer ", "bearer lowercase"] do
        conn =
          conn
          |> delete_req_header("authorization")
          |> put_req_header("authorization", bad)
          |> post("/run", %{"ledger" => ledger, "source" => "return 1"})

        assert conn.status in [401, 403], "#{inspect(bad)} gave #{conn.status}"
      end
    end

    test "guessing a real ledger's name does not help", %{conn: conn, token: token} do
      theirs = "private-#{System.unique_integer([:positive])}"
      {:ok, _} = Blazie.Ledger.open(theirs)
      on_exit(fn -> Blazie.Ledger.close(theirs) end)

      # The name is correct. The grant is not.
      assert json_response(run(conn, token, "return 1", %{"ledger" => theirs}), 403)
    end
  end

  describe "a guest cannot spend without limit" do
    test "a loop forever is stopped", %{conn: conn, token: token, ledger: ledger} do
      body = json_response(run(conn, token, "while true do end", %{"ledger" => ledger}), 422)

      assert body["error"]["problem"] == "took_too_long"
    end

    test "a table that grows forever is stopped", %{conn: conn, token: token, ledger: ledger} do
      bomb = "local t = {} while true do t[#t + 1] = string.rep('x', 1000) end"
      body = json_response(run(conn, token, bomb, %{"ledger" => ledger}), 422)

      assert body["error"]["problem"] in ["took_too_much_memory", "took_too_long"]
    end

    test "a stopped guest writes nothing", %{conn: conn, token: token, ledger: ledger} do
      source = "ada.height = 180 while true do end"
      json_response(run(conn, token, source, %{"ledger" => ledger}), 422)

      # Staged writes are appended only after a chunk returns, so a guest killed
      # mid-run leaves nothing behind — the write above must not be there.
      after_it = json_response(run(build_conn(), token, "return ada.height", %{"ledger" => ledger}), 200)
      assert after_it["value"] == nil
    end
  end

  describe "a guest cannot reach the outside" do
    test "a formula gets no http", %{conn: conn, token: token, ledger: ledger} do
      assert %{"value" => nil} =
               json_response(run(conn, token, "return http", %{"ledger" => ledger}), 200)
    end

    test "the removed globals stay removed", %{conn: conn, token: token, ledger: ledger} do
      for name <- Blazie.Lua.removed() do
        body = json_response(run(conn, token, "return #{name}", %{"ledger" => ledger}), 200)
        assert body["value"] == nil, "#{name} came back as #{inspect(body["value"])}"
      end
    end

    test "redefining the deny list does not hand anything back", %{conn: conn, token: token, ledger: ledger} do
      # `__denied` only decides whether an unknown name becomes an entity. The
      # globals themselves are genuinely absent from the state, so clearing it
      # gets an empty entity rather than `io` — the fence is the absence, and
      # this proves the deny list is a tidiness measure rather than the wall.
      source = "__denied = {} local reached = io return type(reached)"
      body = json_response(run(conn, token, source, %{"ledger" => ledger}), 200)

      assert body["value"] in [nil, "table"]

      # Whatever it is, nothing on it works.
      escape = "__denied = {} return io.write ~= nil"
      assert %{"value" => false} =
               json_response(run(build_conn(), token, escape, %{"ledger" => ledger}), 200)
    end
  end

  describe "a guest cannot talk the wire into lying" do
    test "a guest cannot claim provenance", %{conn: conn, token: token, ledger: ledger} do
      # `__write` is a global a guest can call directly, so the question is what
      # happens when it is called with more than the surface passes. The staged
      # tuple is three wide and there is no fourth slot to put a producer in.
      source = "__write('ada', 'height', 180, false, 'some-formula') return 1"
      assert json_response(run(conn, token, source, %{"ledger" => ledger}), 200)

      read = json_response(run(build_conn(), token, "return ada.height", %{"ledger" => ledger}), 200)
      assert read["value"] == 180

      # Written from outside, so it names nothing — whatever was appended to the
      # call. Provenance belongs to what ran, not to what asked.
      {:ok, ref} = Blazie.Ledger.open(ledger)

      assert Blazie.Snapshot.open([ref])
             |> Blazie.Snapshot.find(id: "ada", attribute: "height")
             |> Enum.all?(&(&1.by == nil))
    end

    test "no assertion shape lets a caller claim provenance" do
      claims = [
        %{"id" => 1, "attribute" => "x", "value" => 1, "by" => "formula"},
        %{"id" => 1, "attribute" => "x", "value" => 1, "by" => nil},
        %{"id" => 1, "attribute" => "x", "value" => 1, "by" => %{}}
      ]

      for claim <- claims do
        assert {:error, %{problem: :cannot_claim_derivation}} = Wire.assertion(claim)
      end
    end

    test "a symbol cannot be written from outside in any shape" do
      shapes = [
        %{"$symbol" => %{"space" => "s", "values" => [1.0]}},
        %{"$symbol" => nil},
        %{"$symbol" => "anything"}
      ]

      for shape <- shapes do
        assert {:error, %{problem: :cannot_write_symbol}} =
                 Wire.assertion(%{"id" => 1, "attribute" => "x", "value" => shape})
      end
    end

    test "a snapshot name cannot carry a nonsense transaction" do
      for bad <- ["three", -1, 1.5, nil, %{}, [1]] do
        assert {:error, %{problem: :bad_transaction}} = Wire.snapshot_name(%{"l" => bad})
      end
    end
  end

  describe "a refusal never leaks what it should not" do
    test "an ungranted ledger's refusal says the name the caller already sent", %{
      conn: conn,
      token: token
    } do
      forbidden = "secret-name-#{System.unique_integer([:positive])}"
      body = json_response(run(conn, token, "return 1", %{"ledger" => forbidden}), 403)

      # It echoes what was sent, and nothing about what exists.
      assert body["error"]["repair"] =~ forbidden
      refute body["error"]["repair"] =~ "exists"
    end
  end
end
