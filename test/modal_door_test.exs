defmodule Blazie.ModalDoorTest do
  @moduledoc """
  The MadEmb door: a customer's own suite reached as a provider, with the
  GPU's seconds on the Studio's bill.

  What the pattern buys and what it must never do are both here: media is
  embedded in the call that carries it — the provider holds no state, so
  there is nowhere for a signed URL to wait out its signature — and the
  suite's answer includes what the GPU spent, booked at the same seam as
  tokens so one bill query answers for both.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Model, Price, Snapshot, TestLedger, World}

  defmodule Suite do
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{method: "POST", path_info: ["embed"]} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      %{"lane" => lane, "input" => inputs} = Jason.decode!(body)

      answer = %{
        "vectors" => Enum.map(inputs, fn _ -> [1.0, 0.0] end),
        "gpu_seconds" => length(inputs) * 0.25,
        "role" => if(lane == "madem-similarity", do: "similarity", else: "retrieval")
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(answer))
    end
  end

  setup do
    server =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: Suite, port: 0, ip: {127, 0, 0, 1}},
          id: :"suite_#{System.unique_integer([:positive])}"
        )
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Model.seed() ++ Price.seed())

    %{endpoint: "http://127.0.0.1:#{port}", world: world}
  end

  test "vectors come back and the GPU's seconds land on the bill", ctx do
    {:ok, priced} =
      Price.declare("modal:madem-text",
        per_gpu_second: 0.0016,
        source: "https://modal.com/pricing#t4",
        checked: "2026-08-14"
      )

    {:ok, _} = World.append(ctx.world, priced)
    prices = Snapshot.open([ctx.world])

    {:ok, vectors} =
      Model.embed("modal:madem-text", ["one", "two"],
        endpoint: ctx.endpoint,
        token: "t",
        into: ctx.world,
        by: "sweep-1",
        for: "studio-a",
        prices: prices
      )

    assert length(vectors) == 2

    bill = Price.bill(Snapshot.open([ctx.world]), "studio-a")
    assert bill.calls == 1
    # Two inputs at a quarter GPU-second each, at the declared T4 rate.
    assert_in_delta bill.usd, 0.5 * 0.0016, 1.0e-9
  end

  test "an unpriced suite books nothing and the blindness is on the bill", ctx do
    {:ok, _} =
      Model.embed("modal:madem-video", ["clip"],
        endpoint: ctx.endpoint,
        token: "t",
        into: ctx.world,
        by: "sweep-2",
        for: "studio-b",
        prices: Snapshot.open([ctx.world])
      )

    bill = Price.bill(Snapshot.open([ctx.world]), "studio-b")
    assert bill.calls == 0
    assert bill.unpriced == 1
  end

  test "a language ask at the suite is refused with the repair", ctx do
    assert {:error, %{problem: :not_a_language_model, repair: repair}} =
             Model.generate("modal:madem-text", "hello", endpoint: ctx.endpoint)

    assert repair =~ "vectors"
  end
end
