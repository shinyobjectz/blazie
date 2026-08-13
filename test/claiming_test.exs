defmodule Blazie.ClaimingTest do
  @moduledoc """
  Taking a ledger name, which is the only operation that names one you do not
  hold.

  Every other operation is checked against the ledgers a caller may name, so
  before this existed a caller could not create a ledger at all: naming a new
  one was refused before anything could be created, and a ledger came into
  existence only when somebody with a shell wrote a grant by hand.

  Dropping the check for this one route is the sort of thing that quietly turns
  into "and then anyone could read anything", so the tests that matter here are
  the refusals — a taken name, a node ledger, and the authority ledger, which
  holds the answer to what everyone may name.
  """
  use Blazie.ConnCase, async: true

  alias Blazie.{Authority, Ledger}

  setup do
    %{token: "claim-token-#{System.unique_integer([:positive])}"}
  end

  defp as(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp free_name, do: "claimed-#{System.unique_integer([:positive])}"

  describe "claiming a free name" do
    test "creates it and grants it to the caller", %{conn: conn, token: token} do
      name = free_name()

      body = conn |> as(token) |> post("/ledgers", %{"ledger" => name}) |> json_response(201)

      assert body["ledger"] == name
      assert Authority.may_name?(token, name)
    end

    test "the claimed ledger is immediately usable", %{conn: conn, token: token} do
      name = free_name()

      conn |> as(token) |> post("/ledgers", %{"ledger" => name})

      # A claimed ledger starts empty, and empty includes its vocabulary — so
      # the first write into one has to define what it is about to say. That is
      # the bootstrap working, not a gap: `is`, `answers` and `cardinality`
      # define themselves, and everything else is built from them.
      define =
        Enum.map(
          Blazie.Attribute.define("height", answers: "integer"),
          fn {id, attribute, value} ->
            %{"id" => id, "attribute" => attribute, "value" => value}
          end
        )

      build_conn()
      |> as(token)
      |> post("/write", %{"ledger" => name, "facts" => define})
      |> json_response(200)

      # The point of claiming is that the next request works. A grant that
      # needed a second step to take effect would be a grant nobody could use.
      written =
        build_conn()
        |> as(token)
        |> post("/write", %{
          "ledger" => name,
          "facts" => [%{"id" => "ada", "attribute" => "height", "value" => 180}]
        })
        |> json_response(200)

      assert %{"name" => %{^name => tx}} = written

      asked =
        build_conn()
        |> as(token)
        # Narrowed to ada: the ledger also holds the three facts that defined
        # `height`, because a definition is a fact like any other and asking for
        # everything correctly returns the vocabulary too.
        |> post("/ask", %{"name" => %{name => tx}, "pattern" => %{"id" => "ada"}})
        |> json_response(200)

      assert [%{"id" => "ada", "value" => 180, "by" => nil}] = asked["facts"]
    end
  end

  describe "what may not be claimed" do
    test "a name another caller already holds", %{conn: conn, token: token} do
      held = open_ledger()

      body = conn |> as(token) |> post("/ledgers", %{"ledger" => held}) |> json_response(422)

      assert body["error"]["problem"] == "name_taken"
      # The refusal must not hand the ledger over as a consolation.
      refute Authority.may_name?(token, held)
    end

    test "a ledger belonging to the node", %{conn: conn, token: token} do
      body =
        conn |> as(token) |> post("/ledgers", %{"ledger" => "$vitals"}) |> json_response(422)

      assert body["error"]["problem"] == "reserved_name"
      refute Authority.may_name?(token, "$vitals")
    end

    test "the authority ledger, which decides what everyone may name", %{
      conn: conn,
      token: token
    } do
      # Reserved by prefix before `grant_checked` is ever reached, and refused
      # by `grant_checked` after that. Either refusal is correct; being granted
      # is not, because a caller holding this one could grant itself the rest.
      conn |> as(token) |> post("/ledgers", %{"ledger" => Authority.ledger()}) |> response(422)

      refute Authority.may_name?(token, Authority.ledger())
    end

    test "the empty string", %{conn: conn, token: token} do
      body = conn |> as(token) |> post("/ledgers", %{"ledger" => ""}) |> json_response(422)
      assert body["error"]["problem"] == "empty_name"
    end

    test "nothing at all", %{conn: conn, token: token} do
      body = conn |> as(token) |> post("/ledgers", %{}) |> json_response(422)
      assert body["error"]["problem"] == "incomplete_request"
      assert body["error"]["repair"] =~ "ledger"
    end
  end

  describe "claiming still needs a token" do
    test "authentication is what was dropped, never authorization", %{conn: conn} do
      body =
        conn
        |> delete_req_header("authorization")
        |> post("/ledgers", %{"ledger" => free_name()})
        |> json_response(401)

      assert body["error"]["problem"] == "no_token"
    end

    test "claiming grants only the name claimed", %{conn: conn, token: token} do
      someone_elses = open_ledger()
      mine = free_name()

      conn |> as(token) |> post("/ledgers", %{"ledger" => mine}) |> json_response(201)

      assert Authority.may_name?(token, mine)
      refute Authority.may_name?(token, someone_elses)
    end
  end

  describe "Ledger.exists?/1" do
    test "an opened ledger exists, an unclaimed name does not" do
      opened = open_ledger()

      assert Ledger.exists?(opened)
      refute Ledger.exists?(free_name())
    end
  end
end
