defmodule Blazie.Surface.WatchChannelTest do
  @moduledoc """
  Watching, over the wire.

  A subscription is a run kept — the same chunk answered again as the name
  advances — so what arrives here carries the snapshot name it was answered at,
  and running that source at that name later must give the same answer.

  This channel used to take a pattern and push facts, which meant a client of
  the websocket had to know what a fact is even though nothing else did. What
  goes in is the same Lua you would send to `run`, and what comes back is what
  the chunk returned.
  """
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  alias Blazie.{Attribute, Authority, World, Snapshot}

  @endpoint Blazie.Surface.Endpoint

  setup do
    token = "watch-token-#{System.unique_integer([:positive])}"
    name = "watch-world-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    Authority.grant(token, name)
    {:ok, _} = World.append(world, Attribute.seed())
    {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    {:ok, _} = World.append(world, Attribute.define("colour"))

    {:ok, socket} = connect(Blazie.Surface.Socket, %{"token" => token})
    %{socket: socket, world: world, name: name, token: token}
  end

  describe "connecting" do
    test "a socket needs a token" do
      assert :error = connect(Blazie.Surface.Socket, %{})
      assert :error = connect(Blazie.Surface.Socket, %{"token" => ""})
    end
  end

  describe "joining a watch" do
    test "a granted world joins", ctx do
      assert {:ok, %{"watching" => watching}, _socket} =
               subscribe_and_join(ctx.socket, "watch:heights", %{
                 "worlds" => [ctx.name],
                 "source" =>
                   "local out = {} for p in each { height = true } do out[#out + 1] = p.height end return out"
               })

      assert watching == [ctx.name]
    end

    test "an ungranted world is refused, even holding a socket", ctx do
      other = "watch-world-#{System.unique_integer([:positive])}"
      {:ok, _} = World.open(other)
      on_exit(fn -> World.close(other) end)

      assert {:error, %{"problem" => "not_granted"}} =
               subscribe_and_join(ctx.socket, "watch:x", %{
                 "worlds" => [other],
                 "source" => "return 1"
               })
    end

    test "naming nothing is refused rather than watching everything", ctx do
      assert {:error, %{"problem" => "no_worlds"}} =
               subscribe_and_join(ctx.socket, "watch:x", %{
                 "worlds" => [],
                 "source" => "return 1"
               })
    end
  end

  describe "answers arrive" do
    setup ctx do
      {:ok, _, socket} =
        subscribe_and_join(ctx.socket, "watch:heights", %{
          "worlds" => [ctx.name],
          "source" =>
            "local out = {} for p in each { height = true } do out[#out + 1] = p.height end return out"
        })

      %{joined: socket}
    end

    test "a matching write pushes what the chunk returned", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])

      assert_push("answer", %{"value" => value}, 2_000)
      assert value == [180]
    end

    test "the chunk that is pushed is the chunk you would have run", ctx do
      # Not a resemblance — the same source, against the name it was answered
      # at, has to give the same thing the socket pushed.
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])
      assert_push("answer", %{"name" => name, "value" => pushed}, 2_000)

      source =
        "local out = {} for p in each { height = true } do out[#out + 1] = p.height end return out"

      reopened = Snapshot.reopen(%{ctx.name => name[ctx.name]})

      assert {:ok, ^pushed, _} = Blazie.Lua.Binding.run(source, reopened)
    end

    test "everything pushed can actually cross a wire", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])

      assert_push("answer", payload, 2_000)

      # assert_push compares terms; a socket encodes them. A snapshot name is
      # keyed by world reference inside, and pushing one raw crashed the
      # channel in production with nothing here to catch it.
      assert {:ok, json} = Jason.encode(payload)
      assert %{"name" => %{}} = Jason.decode!(json)
      assert Map.keys(payload["name"]) == [ctx.name]
    end

    test "the answer carries a name that still answers", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])

      assert_push("answer", %{"name" => name, "value" => value}, 2_000)

      # The name is the contract: running it again gives the same answer.
      reopened = Snapshot.reopen(%{ctx.name => name[ctx.name]})

      assert {:ok, ^value, _} =
               Blazie.Lua.Binding.run(
                 "local out = {} for p in each { height = true } do out[#out + 1] = p.height end return out",
                 reopened
               )
    end

    test "a write outside the question is silent", ctx do
      {:ok, _} = World.append(ctx.world, [{42, "colour", "blue"}])

      refute_push("answer", %{}, 50)
    end

    test "each matching write pushes again", ctx do
      # A push crosses three processes — world, subscription, channel — and
      # `assert_push` waits 100ms by default, which is a coin flip when the
      # whole suite is running. The timeout is not the property under test.
      {:ok, _} = World.append(ctx.world, [{42, "height", 180}])
      assert_push("answer", %{"value" => first}, 2_000)

      {:ok, _} = World.append(ctx.world, [{43, "height", 190}])
      assert_push("answer", %{"value" => second}, 2_000)

      assert length(first) == 1
      assert length(second) == 2
    end
  end

  describe "letting go" do
    test "leaving stops the pushes", ctx do
      {:ok, _, socket} =
        subscribe_and_join(ctx.socket, "watch:heights", %{
          "worlds" => [ctx.name],
          "source" =>
            "local out = {} for p in each { height = true } do out[#out + 1] = p.height end return out"
        })

      before = Blazie.Subscription.count()

      # The channel is linked to this process, so closing it would take the
      # test with it.
      Process.flag(:trap_exit, true)
      :ok = close(socket)

      # The subscription is owned by the channel, so it goes with it.
      Enum.reduce_while(1..100, nil, fn _, _ ->
        if Blazie.Subscription.count() < before,
          do: {:halt, :ok},
          else: {:cont, Process.sleep(10)}
      end)

      assert Blazie.Subscription.count() < before
    end
  end
end
