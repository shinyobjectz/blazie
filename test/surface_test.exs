defmodule Blazie.SurfaceTest do
  @moduledoc """
  The whole public surface: send Lua, get back what it returned.

  `open`, `ask` and `write` used to be three operations here, and between them
  they asked a caller to know what a fact is, what a pattern is, and that a
  snapshot's name is a map of ledgers to transactions. They still happen — this
  opens, runs and appends — but as steps rather than vocabulary.

  What is checked below is that replacing them cost none of the properties they
  carried. A caller still holds a name rather than the bytes; the same source at
  the same name still answers the same forever; a world outside the name still
  cannot leak in; and a write still comes back as the name its facts landed in.
  """
  use Blazie.ConnCase, async: true

  setup do
    %{world: open_ledger()}
  end

  defp run(conn, world, source, extra \\ %{}) do
    post(conn, "/run", Map.merge(%{"world" => world, "source" => source}, extra))
  end

  # A second request on its own connection, carrying this test's caller. Each
  # run is a separate request on purpose — reading your own write in the same
  # connection would prove less than reading it in a new one.
  defp again(token) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  describe "what comes back" do
    test "the value the chunk returned", %{conn: conn, world: world} do
      assert %{"value" => 4} = json_response(run(conn, world, "return 2 + 2"), 200)
    end

    test "a name, never the bytes", %{conn: conn, world: world} do
      body = json_response(run(conn, world, "return 1"), 200)

      # Which world at which transaction, and nothing else. A caller holding
      # this can hand it to somebody else and they get the same answers.
      assert %{^world => tx} = body["name"]
      assert is_integer(tx)
    end

    test "a write comes back as the name its facts landed in", %{conn: conn, world: world, token: token} do
      body = json_response(run(conn, world, "ada.height = 180"), 200)

      assert body["wrote"] > 0
      assert %{^world => tx} = body["name"]

      # Reading its own write at that name, without polling for it.
      read = json_response(run(again(token), world, "return ada.height", %{"name" => %{world => tx}}), 200)
      assert read["value"] == 180
    end

    test "reading nothing writes nothing", %{conn: conn, world: world} do
      assert %{"wrote" => 0} = json_response(run(conn, world, "return 1"), 200)
    end
  end

  describe "a name is a promise" do
    test "the same source at the same name answers the same forever", %{
      conn: conn,
      world: world,
      token: token
    } do
      first = json_response(run(conn, world, "ada.height = 180"), 200)
      pinned = first["name"]

      json_response(run(again(token), world, "ada.height = 200"), 200)

      # Pinned: still 180, however much landed afterwards.
      assert %{"value" => 180} =
               json_response(
                 run(again(token), world, "return ada.height", %{"name" => pinned}),
                 200
               )

      # Unpinned: now.
      assert %{"value" => 200} =
               json_response(run(again(token), world, "return ada.height"), 200)
    end

    test "a nonsense transaction in a name is refused", %{conn: conn, world: world} do
      body = json_response(run(conn, world, "return 1", %{"name" => %{world => "three"}}), 422)

      assert body["error"]["problem"] == "bad_transaction"
    end
  end

  describe "a world is only the ledgers named" do
    test "a world not in the world cannot leak into an answer", %{conn: conn, world: a, token: token} do
      b = open_ledger()
      json_response(run(conn, b, "hidden.height = 1"), 200)

      # `a` is the whole world here, so nothing in `b` is reachable.
      assert %{"value" => nil} = json_response(run(again(token), a, "return hidden.height"), 200)
    end

    test "`also` widens the world to read, but not to write", %{conn: conn, world: a, token: token} do
      b = open_ledger()
      json_response(run(conn, b, "grace.height = 175"), 200)

      body =
        json_response(
          run(again(token), a, "ada.friend_height = grace.height  return grace.height", %{
            "also" => [b]
          }),
          200
        )

      # Read from `b`…
      assert body["value"] == 175
      # …and written into `a`, which is the only world writes ever land in.
      assert %{^a => _} = body["name"]
      refute Map.has_key?(body["name"], b) and body["wrote"] == 0
    end
  end

  describe "the vocabulary still holds, it is just no longer yours to write" do
    test "a field declares itself on first use", %{conn: conn, world: world, token: token} do
      # No definition step anywhere in this test, which is the point.
      assert %{"wrote" => wrote} = json_response(run(conn, world, "ada.height = 180"), 200)

      # The declaration went with it: one assertion for the value, and the
      # facts that say what `height` is.
      assert wrote > 1
      assert %{"value" => 180} = json_response(run(again(token), world, "return ada.height"), 200)
    end

    test "a redeclaration the facts contradict is still refused", %{conn: conn, world: world, token: token} do
      json_response(run(conn, world, "ada.height = 180"), 200)

      # Reaching under the surface deliberately: `height` answers integers and
      # there is an integer written under it, so saying it answers names now
      # contradicts what is already there.
      source = "__write('height', 'answers', 'name', false)"
      body = json_response(run(again(token), world, source), 422)

      assert body["error"]["problem"] == "contradicted"
      assert body["error"]["repair"] =~ "narrow in three steps"
    end

    test "no field name from a request ever becomes an atom", %{conn: conn, world: world} do
      unique = "field_#{System.unique_integer([:positive])}"

      json_response(run(conn, world, "ada.#{unique} = 1"), 200)

      # An atom is never collected, so a surface that made one from a request
      # would be a way to exhaust the VM from outside.
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
    end
  end

  describe "a table comes back as json" do
    # Lua has one data structure for both a list and an object, and Luerl hands
    # it back as neither — a list of {key, value} pairs that JSON cannot encode.
    # Every non-empty table a chunk returned used to fail to serialise, which is
    # everything a console would ever ask for.
    test "keys 1..n become a list", %{conn: conn, world: world} do
      assert %{"value" => [1, 2, 3]} =
               json_response(run(conn, world, "return {1, 2, 3}"), 200)
    end

    test "named keys become an object", %{conn: conn, world: world} do
      assert %{"value" => %{"id" => "ada", "height" => 180}} =
               json_response(run(conn, world, "return {id = 'ada', height = 180}"), 200)
    end

    test "nesting survives", %{conn: conn, world: world} do
      source = "return { rows = { {id = 'ada'}, {id = 'grace'} } }"

      assert %{"value" => %{"rows" => [%{"id" => "ada"}, %{"id" => "grace"}]}} =
               json_response(run(conn, world, source), 200)
    end

    test "a whole table of entities, which is what a data browser asks for", %{
      conn: conn,
      world: world,
      token: token
    } do
      json_response(run(conn, world, "ada.height = 180\nada.name = 'Ada'"), 200)

      source = """
      local rows = {}
      for e in each {} do
        local row = { id = e.id }
        for field, value in pairs(e) do row[field] = value end
        rows[#rows + 1] = row
      end
      return rows
      """

      body = json_response(run(again(token), world, source), 200)

      assert Enum.any?(body["value"], fn row ->
               row["id"] == "ada" and row["height"] == 180 and row["name"] == "Ada"
             end),
             "expected ada as a row, got: #{inspect(body["value"])}"
    end
  end

  describe "provenance" do
    test "what a caller writes names nothing", %{conn: conn, world: world} do
      json_response(run(conn, world, "ada.height = 180"), 200)

      {:ok, ref} = World.open(world)

      assert Snapshot.open([ref])
             |> Snapshot.find(id: "ada")
             |> Enum.all?(&(&1.by == nil)),
             "a fact written from outside cannot name a producer"
    end
  end
end
