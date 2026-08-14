defmodule Blazie.ClientElixirTest do
  @moduledoc """
  The Elixir client, over a real wire.

  Tested inside blazie's own suite so the SDK and the surface cannot drift
  apart unnoticed — a client tested against a mock of the server is a second
  copy of the server, and the second copy is always the one that is wrong.
  A real Bandit listener on a random port, real HTTP, real refusals.
  """
  use ExUnit.Case, async: false

  alias Blazie.Authority

  setup do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: Blazie.Surface.Endpoint, port: 0, ip: {127, 0, 0, 1}},
          id: :wire
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    token = "client-test-#{System.unique_integer([:positive])}"
    client = BlazieClient.new("http://127.0.0.1:#{port}", token)

    %{client: client, token: token, port: port}
  end

  test "claim, write, and read back over the wire", %{client: client} do
    world = "client-world-#{System.unique_integer([:positive])}"

    assert {:ok, %{"world" => ^world}} = BlazieClient.claim(client, world)

    # A chunk reads its snapshot, so a write and its read-back are two runs —
    # the second sees what the first landed.
    assert {:ok, %{"wrote" => wrote, "name" => name}} =
             BlazieClient.run(client, "ada.height = 180", world: world)

    assert wrote > 0
    assert is_map(name)

    assert {:ok, %{"value" => 180}} = BlazieClient.run(client, "return ada.height", world: world)

    assert {:ok, %{"worlds" => worlds}} = BlazieClient.me(client)
    assert world in worlds
  end

  test "a pinned answer is cached, and the cache answers when the wire cannot",
       %{client: client} do
    world = "client-world-#{System.unique_integer([:positive])}"
    {:ok, _} = BlazieClient.claim(client, world)

    {:ok, %{"name" => name}} = BlazieClient.run(client, "ada.height = 180", world: world)

    {:ok, cache} = BlazieClient.cache()

    assert {:ok, %{"value" => 180} = answer} =
             BlazieClient.run(client, "return ada.height", world: world, name: name, cache: cache)

    # The server goes away. The name still answers, because an answer at a
    # name is the same answer forever — which is the whole reason caching on
    # one is allowed.
    :ok = stop_supervised(:wire)

    assert {:ok, ^answer} =
             BlazieClient.run(client, "return ada.height", world: world, name: name, cache: cache)

    # Flushed — the erasure caveat made operable — the wire is the only
    # source again, and the wire is gone.
    :ok = BlazieClient.flush(cache)

    assert {:error, %{problem: :unreachable}} =
             BlazieClient.run(client, "return ada.height", world: world, name: name, cache: cache)
  end

  test "an unpinned run is never cached", %{client: client} do
    world = "client-world-#{System.unique_integer([:positive])}"
    {:ok, _} = BlazieClient.claim(client, world)
    {:ok, cache} = BlazieClient.cache()

    {:ok, _} = BlazieClient.run(client, "ada.height = 1", world: world, cache: cache)

    {:ok, %{"value" => 1}} =
      BlazieClient.run(client, "return ada.height", world: world, cache: cache)

    {:ok, _} = BlazieClient.run(client, "ada.height = 2", world: world, cache: cache)

    # The same source again, no name pinned: the answer moved, and the client
    # let it — caching a moving answer would be inventing a name for a moment
    # nobody recorded.
    {:ok, %{"value" => 2}} =
      BlazieClient.run(client, "return ada.height", world: world, cache: cache)
  end

  test "a refusal crosses the wire with its repair intact", %{client: client, port: port} do
    world = "client-world-#{System.unique_integer([:positive])}"
    {:ok, _} = BlazieClient.claim(client, world)

    # Somebody else's token may not name this world, and the refusal that
    # comes back is the cluster's own, repair and all — not a translation.
    other = BlazieClient.new("http://127.0.0.1:#{port}", "intruder-#{System.unique_integer()}")

    assert {:error, %{problem: problem, repair: repair}} =
             BlazieClient.run(other, "return 1", world: world)

    assert is_atom(problem)
    assert String.length(repair) > 30
  end

  test "a world nobody claimed for this caller is a readable refusal", %{client: client} do
    assert {:error, %{repair: repair}} =
             BlazieClient.run(client, "return 1",
               world: "never-claimed-#{System.unique_integer()}"
             )

    assert repair =~ ~r/claim|grant|name/i
  end

  test "the same token still resolves through the client", %{client: client, token: token} do
    world = "client-world-#{System.unique_integer([:positive])}"
    {:ok, _} = BlazieClient.claim(client, world)

    assert Authority.may_name?(token, world)
  end
end
