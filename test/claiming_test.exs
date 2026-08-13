defmodule Blazie.ClaimingTest do
  @moduledoc """
  Taking a world name, which is the only operation that names one you do not
  hold.

  Every other operation is checked against the ledgers a caller may name, so
  before this existed a caller could not create a world at all: naming a new
  one was refused before anything could be created, and a world came into
  existence only when somebody with a shell wrote a grant by hand.

  Dropping the check for this one route is the sort of thing that quietly turns
  into "and then anyone could read anything", so the tests that matter here are
  the refusals — a taken name, a node world, and the authority world, which
  holds the answer to what everyone may name.
  """
  use Blazie.ConnCase, async: true

  alias Blazie.{Authority, World}

  setup do
    %{token: "claim-token-#{System.unique_integer([:positive])}"}
  end

  defp as(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp free_name, do: "claimed-#{System.unique_integer([:positive])}"

  describe "claiming a free name" do
    test "creates it and grants it to the caller", %{conn: conn, token: token} do
      name = free_name()

      body = conn |> as(token) |> post("/worlds", %{"world" => name}) |> json_response(201)

      assert body["world"] == name
      assert Authority.may_name?(token, name)
    end

    test "the claimed world is immediately usable", %{conn: conn, token: token} do
      name = free_name()

      conn |> as(token) |> post("/worlds", %{"world" => name})

      # The point of claiming is that the next request works. A grant that
      # needed a second step to take effect would be a grant nobody could use.
      # Nothing here defines anything first: a claimed world starts empty, and
      # empty includes its vocabulary, so a field declaring itself is the
      # difference between this working and a fresh world refusing every write.
      written =
        build_conn()
        |> as(token)
        |> post("/run", %{"world" => name, "source" => "ada.height = 180"})
        |> json_response(200)

      assert %{"name" => %{^name => tx}} = written

      read =
        build_conn()
        |> as(token)
        |> post("/run", %{
          "world" => name,
          "source" => "return ada.height",
          "name" => %{name => tx}
        })
        |> json_response(200)

      assert read["value"] == 180
    end
  end

  describe "what may not be claimed" do
    test "a name another caller already holds", %{conn: conn, token: token} do
      held = open_ledger()

      body = conn |> as(token) |> post("/worlds", %{"world" => held}) |> json_response(422)

      assert body["error"]["problem"] == "name_taken"
      # The refusal must not hand the world over as a consolation.
      refute Authority.may_name?(token, held)
    end

    test "a world belonging to the node", %{conn: conn, token: token} do
      body =
        conn |> as(token) |> post("/worlds", %{"world" => "$vitals"}) |> json_response(422)

      assert body["error"]["problem"] == "reserved_name"
      refute Authority.may_name?(token, "$vitals")
    end

    test "the authority world, which decides what everyone may name", %{
      conn: conn,
      token: token
    } do
      # Reserved by prefix before `grant_checked` is ever reached, and refused
      # by `grant_checked` after that. Either refusal is correct; being granted
      # is not, because a caller holding this one could grant itself the rest.
      conn |> as(token) |> post("/worlds", %{"world" => Authority.world()}) |> response(422)

      refute Authority.may_name?(token, Authority.world())
    end

    test "the empty string", %{conn: conn, token: token} do
      body = conn |> as(token) |> post("/worlds", %{"world" => ""}) |> json_response(422)
      assert body["error"]["problem"] == "empty_name"
    end

    test "nothing at all", %{conn: conn, token: token} do
      body = conn |> as(token) |> post("/worlds", %{}) |> json_response(422)
      assert body["error"]["problem"] == "incomplete_request"
      assert body["error"]["repair"] =~ "world"
    end
  end

  describe "claiming still needs a token" do
    test "authentication is what was dropped, never authorization", %{conn: conn} do
      body =
        conn
        |> delete_req_header("authorization")
        |> post("/worlds", %{"world" => free_name()})
        |> json_response(401)

      assert body["error"]["problem"] == "no_token"
    end

    test "claiming grants only the name claimed", %{conn: conn, token: token} do
      someone_elses = open_ledger()
      mine = free_name()

      conn |> as(token) |> post("/worlds", %{"world" => mine}) |> json_response(201)

      assert Authority.may_name?(token, mine)
      refute Authority.may_name?(token, someone_elses)
    end
  end

  describe "World.exists?/1" do
    test "an opened world exists, an unclaimed name does not" do
      opened = open_ledger()

      assert World.exists?(opened)
      refute World.exists?(free_name())
    end
  end
end
