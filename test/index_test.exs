defmodule Blazie.IndexTest do
  @moduledoc """
  The vector seam: bought, roled, derived, and swappable.

  The gate runs ONE capability — kind-scoped retrieval over a corpus of
  symbols — through two providers: the exact node-local index (whose every
  score is the true score, so it is also the baseline), and the Turbopuffer
  module speaking real HTTP to a server implementing exactly the wire shape
  the module speaks. Same test body, same corpus, same answers: the vendor
  is swappable because nothing above the behaviour can tell them apart.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Index, Job, Snapshot, Symbol, TestLedger, World}
  alias Blazie.Job.Runner

  # A tiny wire-accurate vendor: holds upserts in an Agent, answers queries
  # with exact cosine over what it holds, speaks the same paths, bodies and
  # `dist` dialect the module does. What it pins is the MODULE's wire format.
  defmodule Wire do
    import Plug.Conn

    def init(agent), do: agent

    def call(
          %Plug.Conn{method: "POST", path_info: ["v1", "namespaces", ns, "query"]} = conn,
          agent
        ) do
      {:ok, body, conn} = read_body(conn)
      asked = Jason.decode!(body)
      rows = Agent.get(agent, &Map.get(&1, ns, %{}))

      query = asked["vector"]

      wanted = fn meta ->
        Enum.all?(asked["filters"] || %{}, fn {key, [["Eq", value]]} ->
          Map.get(meta, key) == value
        end)
      end

      results =
        rows
        |> Map.values()
        |> Enum.filter(fn %{"attributes" => meta} -> wanted.(meta) end)
        |> Enum.map(fn %{"id" => id, "vector" => vector} ->
          %{"id" => id, "dist" => 1.0 - cosine(query, vector)}
        end)
        |> Enum.sort_by(& &1["dist"])
        |> Enum.take(asked["top_k"])

      answer(conn, %{"results" => results})
    end

    def call(%Plug.Conn{method: "POST", path_info: ["v1", "namespaces", ns]} = conn, agent) do
      {:ok, body, conn} = read_body(conn)
      %{"upserts" => upserts} = Jason.decode!(body)

      Agent.update(agent, fn held ->
        Map.update(held, ns, Map.new(upserts, &{&1["id"], &1}), fn rows ->
          Enum.reduce(upserts, rows, &Map.put(&2, &1["id"], &1))
        end)
      end)

      answer(conn, %{"ok" => true})
    end

    def call(%Plug.Conn{method: "DELETE", path_info: ["v1", "namespaces", ns]} = conn, agent) do
      Agent.update(agent, &Map.delete(&1, ns))
      answer(conn, %{"ok" => true})
    end

    defp answer(conn, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end

    defp cosine(a, b) do
      dot = Enum.zip_with(a, b, &(&1 * &2)) |> Enum.sum()
      na = :math.sqrt(Enum.map(a, &(&1 * &1)) |> Enum.sum())
      nb = :math.sqrt(Enum.map(b, &(&1 * &1)) |> Enum.sum())
      dot / (na * nb)
    end
  end

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Index.seed() ++ Symbol.seed())
    %{world: world}
  end

  defp exact_provider do
    {Index.Exact, prefix: "t#{System.unique_integer([:positive])}_"}
  end

  defp turbopuffer_provider do
    {:ok, agent} = Agent.start_link(fn -> %{} end)

    server =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: {Wire, agent}, port: 0, ip: {127, 0, 0, 1}},
          id: :"tp_#{System.unique_integer([:positive])}"
        )
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    {Index.Turbopuffer,
     endpoint: "http://127.0.0.1:#{port}",
     key: "test-key",
     prefix: "t#{System.unique_integer([:positive])}_"}
  end

  test "a space without a role refuses everything", %{world: world} do
    snapshot = Snapshot.open([world])
    query = Symbol.new("unroled_64", [1.0, 0.0])

    assert {:error, %{problem: :no_role, repair: repair}} =
             Index.nearest(snapshot, "unroled_64", query, 3, %{}, provider: exact_provider())

    assert repair =~ "Declare it"
  end

  test "a query_only space cannot assert an edge, a similarity space can", %{world: world} do
    {:ok, _} = World.append(world, Index.declare("glance_128", "query_only"))
    {:ok, _} = World.append(world, Index.declare("pe_1024", "similarity"))
    snapshot = Snapshot.open([world])

    assert {:error, %{problem: :role_refuses, repair: repair}} =
             Index.edge(snapshot, "glance_128", "a", "b", 0.9)

    assert repair =~ "invent a relationship"

    assert {:ok, [{_a, "alike", edge}]} = Index.edge(snapshot, "pe_1024", "a", "b", 0.9)
    assert edge["space"] == "pe_1024"
  end

  describe "the Phase 4 gate: one capability, two vendors, same answers" do
    # Sixteen items in two kinds whose vectors point in cleanly separated
    # directions, so top-3 kind-scoped retrieval has an unambiguous truth.
    defp corpus do
      for i <- 1..16 do
        kind = if rem(i, 2) == 0, do: "video", else: "still"
        angle = i / 16 * 1.5 + if(kind == "video", do: 0.0, else: 100.0)
        {"item-#{i}", [:math.cos(angle), :math.sin(angle)], %{"kind" => kind}}
      end
    end

    defp truth(query, kind, k) do
      corpus()
      |> Enum.filter(fn {_id, _v, meta} -> meta["kind"] == kind end)
      |> Enum.map(fn {id, v, _} ->
        s = Symbol.new("gate_2", v)
        {:ok, score} = Symbol.near(Symbol.new("gate_2", query), s)
        {id, score}
      end)
      |> Enum.sort_by(fn {_id, score} -> -score end)
      |> Enum.take(k)
      |> Enum.map(&elem(&1, 0))
    end

    test "kind-scoped retrieval at parity, vendor swapped mid-test", %{world: world} do
      {:ok, _} = World.append(world, Index.declare("gate_2", "retrieval"))
      snapshot = Snapshot.open([world])
      query = [:math.cos(0.7), :math.sin(0.7)]

      for provider <- [exact_provider(), turbopuffer_provider()] do
        {module, opts} = provider
        :ok = module.upsert(opts, "gate_2", corpus())

        {:ok, hits} =
          Index.nearest(snapshot, "gate_2", Symbol.new("gate_2", query), 3, %{"kind" => "video"},
            provider: provider
          )

        ids = Enum.map(hits, fn {id, _score} -> to_string(id) end)

        assert ids == truth(query, "video", 3),
               "#{inspect(module)} disagreed with the exact baseline: #{inspect(ids)}"

        # Kill the index; the world still holds the symbols. Derived means
        # disposable, and disposable means this is not data loss.
        :ok = module.drop(opts, "gate_2")
      end
    end
  end

  test "the maintaining job indexes what lands, and re-fires on new symbols", %{world: world} do
    {:ok, _} = World.append(world, Job.seed() ++ Index.job_seed())
    {:ok, _} = World.append(world, Index.declare("lane_2", "retrieval"))
    {:ok, _} = World.append(world, Attribute.define("embedding", answers: "any"))
    {:ok, _} = World.append(world, Attribute.define("kind", answers: "name"))
    {:ok, _} = World.append(world, Job.declare("indexer", every: 3_600))

    provider = exact_provider()
    {module, popts} = provider

    {:ok, _} =
      World.append(world, [
        {"item-1", "embedding", Symbol.new("lane_2", [1.0, 0.0])},
        {"item-1", "kind", "video"}
      ])

    runner =
      start_supervised!(
        {Runner,
         world: world,
         jobs: [Index.job("indexer", "embedding", provider: provider, meta: ["kind"])],
         name: :"idx_#{System.unique_integer([:positive])}"}
      )

    assert {:ok, ["indexer"]} = Runner.tick(runner, 1_000)
    settle(runner)

    {:ok, [{"item-1", _score}]} = module.search(popts, "lane_2", [1.0, 0.0], 1, %{})

    # Quiet inside the cadence — until a new symbol lands in its read set.
    assert {:ok, []} = Runner.tick(runner, 1_010)

    {:ok, _} =
      World.append(world, [{"item-2", "embedding", Symbol.new("lane_2", [0.0, 1.0])}])

    assert {:ok, ["indexer"]} = Runner.tick(runner, 1_020)
    settle(runner)

    {:ok, [{"item-2", _}]} = module.search(popts, "lane_2", [0.0, 1.0], 1, %{})
  end

  defp settle(runner) do
    Enum.reduce_while(1..400, nil, fn _, _ ->
      if Runner.in_flight(runner) == [], do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
    end)
  end
end
