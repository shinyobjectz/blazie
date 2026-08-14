defmodule Blazie.RotationTest do
  @moduledoc """
  Token rotation without a reprovision, over the real wire.

  The whole flow in four verbs, every step a fact: mint a successor, SHARE
  each held world with its fingerprint (the secret never crosses), verify
  the successor answers, DROP the elder's grants. Both tokens live during
  the window — that is the grace — and afterward the elder is refused
  everywhere it used to reach. The control plane's rotate endpoint
  sequences exactly these calls; the semantics are proven here, where the
  cluster is real.
  """
  use ExUnit.Case, async: false

  alias Blazie.Authority

  setup do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: Blazie.Surface.Endpoint, port: 0, ip: {127, 0, 0, 1}},
          id: :rotate_wire
        )
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    %{address: "http://127.0.0.1:#{port}"}
  end

  test "the elder shares, the successor answers, the elder retires", ctx do
    world = "rot-world-#{System.unique_integer([:positive])}"
    elder = BlazieClient.new(ctx.address, "elder-#{System.unique_integer([:positive])}")
    successor_token = "successor-#{System.unique_integer([:positive])}"
    successor = BlazieClient.new(ctx.address, successor_token)

    {:ok, _} = BlazieClient.claim(elder, world)
    {:ok, _} = BlazieClient.run(elder, "ada.height = 180", world: world)

    # Share: the successor's SECRET never travels — only its hash.
    assert {:ok, %{"shared" => ^world}} =
             BlazieClient.share(elder, world, Authority.caller(successor_token))

    # The grace window: both answer.
    assert {:ok, %{"worlds" => elder_worlds}} = BlazieClient.me(elder)
    assert {:ok, %{"worlds" => successor_worlds}} = BlazieClient.me(successor)
    assert world in elder_worlds and world in successor_worlds

    assert {:ok, %{"value" => 180}} =
             BlazieClient.run(successor, "return ada.height", world: world)

    # The window closes: the elder drops itself, and is refused everywhere
    # it used to reach — while the successor carries on.
    assert {:ok, %{"dropped" => ^world}} = BlazieClient.drop(elder, world)
    assert {:error, %{repair: _}} = BlazieClient.run(elder, "return 1", world: world)

    assert {:ok, %{"value" => 180}} =
             BlazieClient.run(successor, "return ada.height", world: world)
  end

  test "sharing what you do not hold is refused, and reserved ledgers always are", ctx do
    world = "rot-world-#{System.unique_integer([:positive])}"
    holder = BlazieClient.new(ctx.address, "holder-#{System.unique_integer([:positive])}")
    stranger = BlazieClient.new(ctx.address, "stranger-#{System.unique_integer([:positive])}")

    {:ok, _} = BlazieClient.claim(holder, world)

    assert {:error, %{repair: repair}} =
             BlazieClient.share(stranger, world, Authority.caller("anyone"))

    assert String.length(repair) > 20

    # And no rotation may ever share the ledgers that change authority.
    assert {:error, %{repair: reserved}} =
             BlazieClient.share(holder, "$authority", Authority.caller("anyone"))

    assert String.length(reserved) > 20
  end
end
