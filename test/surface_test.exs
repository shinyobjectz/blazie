defmodule LazyRiver.SurfaceTest do
  @moduledoc """
  Doctrine 17, over the wire: four operations, a caller holds the name rather
  than the bytes, and write hands back the name its facts are in.
  """
  use LazyRiver.ConnCase, async: true

  setup do
    ledger = open_ledger()
    define(ledger, "height", answers: "integer")
    %{ledger: ledger}
  end

  describe "open" do
    test "hands back a name, not the bytes", %{conn: conn, ledger: ledger} do
      conn = post(conn, "/open", %{"ledgers" => [ledger]})

      assert %{"name" => name} = json_response(conn, 200)
      assert Map.keys(name) == [ledger]
      assert is_integer(name[ledger]) and name[ledger] >= 0
    end

    test "a name covers every ledger opened", %{conn: conn, ledger: a} do
      b = open_ledger()
      define(b, "height", answers: "integer")
      conn = post(conn, "/open", %{"ledgers" => [a, b]})

      assert %{"name" => name} = json_response(conn, 200)
      assert Map.keys(name) |> Enum.sort() == Enum.sort([a, b])
    end

    test "opening nothing is refused rather than returning everything", %{conn: conn} do
      conn = post(conn, "/open", %{"ledgers" => []})

      assert %{"error" => error} = json_response(conn, 422)
      assert error["problem"] == "no_ledgers"
    end
  end

  describe "write" do
    test "returns the name its facts are in, so a caller reads its own write",
         %{conn: conn, ledger: ledger} do
      conn =
        post(conn, "/write", %{
          "ledger" => ledger,
          "facts" => [%{"id" => 42, "attribute" => "height", "value" => 180}]
        })

      assert %{"name" => %{^ledger => _tx} = name} = json_response(conn, 200)

      # The property, not the number: the name handed back is the snapshot the
      # facts are in, so a caller reads its own write without polling.
      asked = post(conn, "/ask", %{"name" => name, "pattern" => %{"id" => 42}})
      assert [%{"value" => 180}] = json_response(asked, 200)["facts"]
    end

    test "a caller cannot claim a fact was derived", %{conn: conn, ledger: ledger} do
      conn =
        post(conn, "/write", %{
          "ledger" => ledger,
          "facts" => [
            %{"id" => 42, "attribute" => "height", "value" => 180, "by" => "potion"}
          ]
        })

      assert %{"error" => error} = json_response(conn, 422)
      assert error["problem"] == "cannot_claim_derivation"
      assert error["repair"] =~ "came from outside"
    end

    test "an attribute nobody defined is refused, with how to define it",
         %{conn: conn, ledger: ledger} do
      conn =
        post(conn, "/write", %{
          "ledger" => ledger,
          "facts" => [%{"id" => 1, "attribute" => "not_defined_here", "value" => 1}]
        })

      assert %{"error" => error} = json_response(conn, 422)
      assert error["problem"] == "undefined"
      assert error["repair"] =~ "Define it first"
    end

    test "defining it first is itself an ordinary write", %{conn: conn, ledger: ledger} do
      defining =
        Enum.map(LazyRiver.Attribute.define("colour", answers: "name"), fn {id, att, ans} ->
          %{"id" => id, "attribute" => att, "value" => ans}
        end)

      assert %{"name" => _} =
               json_response(
                 post(conn, "/write", %{"ledger" => ledger, "facts" => defining}),
                 200
               )

      assert %{"name" => _} =
               json_response(
                 post(conn, "/write", %{
                   "ledger" => ledger,
                   "facts" => [%{"id" => 1, "attribute" => "colour", "value" => "blue"}]
                 }),
                 200
               )
    end

    test "no attribute name from a request ever becomes an atom", %{conn: conn, ledger: ledger} do
      post(conn, "/write", %{
        "ledger" => ledger,
        "facts" => [%{"id" => 1, "attribute" => "an_attribute_only_ever_sent", "value" => 1}]
      })

      assert_raise ArgumentError, fn -> String.to_existing_atom("an_attribute_only_ever_sent") end
    end
  end

  describe "ask" do
    setup %{conn: conn, ledger: ledger} do
      post(conn, "/write", %{
        "ledger" => ledger,
        "facts" => [
          %{"id" => 42, "attribute" => "height", "value" => 180},
          %{"id" => 43, "attribute" => "height", "value" => 190}
        ]
      })

      :ok
    end

    test "answers at a name", %{conn: conn, ledger: ledger} do
      %{"name" => name} = json_response(post(conn, "/open", %{"ledgers" => [ledger]}), 200)

      conn = post(conn, "/ask", %{"name" => name, "pattern" => %{"attribute" => "height"}})

      assert %{"facts" => facts} = json_response(conn, 200)
      assert length(facts) == 2
      assert Enum.all?(facts, &(&1["attribute"] == "height"))
      assert Enum.all?(facts, &is_nil(&1["by"]))
    end

    test "the answer at a name never changes", %{conn: conn, ledger: ledger} do
      %{"name" => name} = json_response(post(conn, "/open", %{"ledgers" => [ledger]}), 200)

      post(conn, "/write", %{
        "ledger" => ledger,
        "facts" => [%{"id" => 44, "attribute" => "height", "value" => 200}]
      })

      asked = post(conn, "/ask", %{"name" => name, "pattern" => %{"attribute" => "height"}})
      assert length(json_response(asked, 200)["facts"]) == 2

      %{"name" => later} = json_response(post(conn, "/open", %{"ledgers" => [ledger]}), 200)
      asked = post(conn, "/ask", %{"name" => later, "pattern" => %{"attribute" => "height"}})
      assert length(json_response(asked, 200)["facts"]) == 3
    end

    test "a ledger not in the name cannot leak into the answer", %{conn: conn, ledger: a} do
      b = open_ledger()
      define(b, "height", answers: "integer")

      post(conn, "/write", %{
        "ledger" => b,
        "facts" => [%{"id" => 99, "attribute" => "height", "value" => 1}]
      })

      %{"name" => name} = json_response(post(conn, "/open", %{"ledgers" => [a]}), 200)
      conn = post(conn, "/ask", %{"name" => name, "pattern" => %{}})

      ids = json_response(conn, 200)["facts"] |> Enum.map(& &1["id"])
      refute 99 in ids
    end

    test "a name with a nonsense transaction is refused", %{conn: conn, ledger: ledger} do
      conn = post(conn, "/ask", %{"name" => %{ledger => "three"}, "pattern" => %{}})

      assert %{"error" => error} = json_response(conn, 422)
      assert error["problem"] == "bad_transaction"
    end
  end
end
