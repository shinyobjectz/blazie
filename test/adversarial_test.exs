defmodule LazyRiver.AdversarialTest do
  @moduledoc """
  What a caller sends when it is hostile, broken, or merely wrong.

  Everything here goes through the door rather than round it, because a
  boundary is only as good as the worst thing sent at it. A refusal is the
  correct outcome for nearly all of this — what would be a defect is a crash,
  a leak, or a silent success.
  """
  use LazyRiver.ConnCase, async: true

  alias LazyRiver.{Authority, Wire}

  setup do
    ledger = open_ledger()
    define(ledger, "height", answers: "integer")
    %{ledger: ledger}
  end

  describe "malformed requests are refused, never fatal" do
    test "every operation survives junk", %{conn: conn, ledger: ledger} do
      junk = [
        %{},
        %{"ledgers" => "not a list"},
        %{"ledgers" => [nil]},
        %{"ledgers" => [%{"nested" => true}]},
        %{"name" => "not a map", "pattern" => %{}},
        %{"name" => %{}, "pattern" => "not a map"},
        %{"ledger" => ledger, "facts" => "not a list"},
        %{"ledger" => ledger, "facts" => [nil]},
        %{"ledger" => ledger, "facts" => [%{}]},
        %{"ledger" => ledger, "facts" => [%{"id" => 1}]},
        %{"ledger" => nil, "facts" => []},
        %{"pattern" => %{"attribute" => 12_345}}
      ]

      for body <- junk, path <- ["/open", "/ask", "/write"] do
        conn = post(conn, path, body)

        assert conn.status in [200, 401, 403, 422],
               "#{path} with #{inspect(body)} gave #{conn.status}"
      end
    end

    test "a deeply nested id is refused rather than stored", %{conn: conn, ledger: ledger} do
      nested = Enum.reduce(1..50, "deep", fn _, acc -> %{"a" => acc} end)

      conn =
        post(conn, "/write", %{
          "ledger" => ledger,
          "facts" => [%{"id" => nested, "attribute" => "height", "answer" => 1}]
        })

      assert %{"error" => %{"problem" => "bad_id"}} = json_response(conn, 422)
    end

    test "an enormous attribute name is a name, and still needs defining",
         %{conn: conn, ledger: ledger} do
      huge = String.duplicate("a", 10_000)

      conn =
        post(conn, "/write", %{
          "ledger" => ledger,
          "facts" => [%{"id" => 1, "attribute" => huge, "answer" => 1}]
        })

      assert %{"error" => %{"problem" => "undefined"}} = json_response(conn, 422)
      assert_raise ArgumentError, fn -> String.to_existing_atom(huge) end
    end
  end

  describe "a caller cannot reach past its grants" do
    test "no ledger name shape gets past authorization", %{conn: conn} do
      forbidden = "not-granted-#{System.unique_integer([:positive])}"

      attempts = [
        {"/open", %{"ledgers" => [forbidden]}},
        {"/ask", %{"name" => %{forbidden => 0}, "pattern" => %{}}},
        {"/write", %{"ledger" => forbidden, "facts" => []}},
        {"/open", %{"ledgers" => [LazyRiver.Authority.ledger()]}},
        {"/ask", %{"name" => %{Authority.ledger() => 0}, "pattern" => %{}}}
      ]

      for {path, body} <- attempts do
        conn = post(conn, path, body)
        assert conn.status == 403, "#{path} #{inspect(body)} gave #{conn.status}"
      end
    end

    test "a token that is not a token is refused", %{conn: conn, ledger: ledger} do
      for bad <- ["", "Bearer", "Basic abc", "Bearer ", "bearer lowercase"] do
        conn =
          conn
          |> delete_req_header("authorization")
          |> put_req_header("authorization", bad)
          |> post("/open", %{"ledgers" => [ledger]})

        assert conn.status in [401, 403], "#{inspect(bad)} gave #{conn.status}"
      end
    end

    test "one caller cannot read another's ledger by guessing its name", %{conn: conn} do
      theirs = "private-#{System.unique_integer([:positive])}"
      {:ok, _} = LazyRiver.Ledger.open(theirs)
      on_exit(fn -> LazyRiver.Ledger.close(theirs) end)

      # The name is correct. The grant is not.
      conn = post(conn, "/ask", %{"name" => %{theirs => 99}, "pattern" => %{}})
      assert json_response(conn, 403)
    end
  end

  describe "the wire cannot be talked into lying" do
    test "no assertion shape lets a caller claim provenance" do
      claims = [
        %{"id" => 1, "attribute" => "x", "answer" => 1, "by" => "formula"},
        %{"id" => 1, "attribute" => "x", "answer" => 1, "by" => nil},
        %{"id" => 1, "attribute" => "x", "answer" => 1, "by" => %{}}
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
                 Wire.assertion(%{"id" => 1, "attribute" => "x", "answer" => shape})
      end
    end

    test "a snapshot name cannot carry a nonsense transaction" do
      for bad <- ["three", -1, 1.5, nil, %{}, [1]] do
        assert {:error, %{problem: :bad_transaction}} = Wire.snapshot_name(%{"l" => bad})
      end
    end
  end

  describe "a refusal never leaks what it should not" do
    test "an ungranted ledger's refusal says the name the caller already sent",
         %{conn: conn} do
      forbidden = "secret-name-#{System.unique_integer([:positive])}"
      conn = post(conn, "/open", %{"ledgers" => [forbidden]})

      body = json_response(conn, 403)

      # It echoes what was sent, and nothing about what exists.
      assert body["error"]["repair"] =~ forbidden
      refute body["error"]["repair"] =~ "exists"
    end
  end
end
