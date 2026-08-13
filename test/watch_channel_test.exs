defmodule Blazie.Surface.WatchChannelTest do
  @moduledoc """
  The fourth operation, over the wire.

  A subscription is the same question asked again as the name advances, so what
  arrives here carries the snapshot name it was answered at — and asking that
  name later must give the same answer.
  """
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  alias Blazie.{Attribute, Authority, Ledger, Snapshot}

  @endpoint Blazie.Surface.Endpoint

  setup do
    token = "watch-token-#{System.unique_integer([:positive])}"
    name = "watch-ledger-#{System.unique_integer([:positive])}"
    {:ok, ledger} = Ledger.open(name)
    on_exit(fn -> Ledger.close(name) end)

    Authority.grant(token, name)
    {:ok, _} = Ledger.append(ledger, Attribute.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
    {:ok, _} = Ledger.append(ledger, Attribute.define("colour"))

    {:ok, socket} = connect(Blazie.Surface.Socket, %{"token" => token})
    %{socket: socket, ledger: ledger, name: name, token: token}
  end

  describe "connecting" do
    test "a socket needs a token" do
      assert :error = connect(Blazie.Surface.Socket, %{})
      assert :error = connect(Blazie.Surface.Socket, %{"token" => ""})
    end
  end

  describe "joining a watch" do
    test "a granted ledger joins", ctx do
      assert {:ok, %{"watching" => watching}, _socket} =
               subscribe_and_join(ctx.socket, "watch:heights", %{
                 "ledgers" => [ctx.name],
                 "pattern" => %{"attribute" => "height"}
               })

      assert watching == [ctx.name]
    end

    test "an ungranted ledger is refused, even holding a socket", ctx do
      other = "watch-ledger-#{System.unique_integer([:positive])}"
      {:ok, _} = Ledger.open(other)
      on_exit(fn -> Ledger.close(other) end)

      assert {:error, %{"problem" => "not_granted"}} =
               subscribe_and_join(ctx.socket, "watch:x", %{"ledgers" => [other]})
    end

    test "naming nothing is refused rather than watching everything", ctx do
      assert {:error, %{"problem" => "no_ledgers"}} =
               subscribe_and_join(ctx.socket, "watch:x", %{"ledgers" => []})
    end
  end

  describe "answers arrive" do
    setup ctx do
      {:ok, _, socket} =
        subscribe_and_join(ctx.socket, "watch:heights", %{
          "ledgers" => [ctx.name],
          "pattern" => %{"attribute" => "height"}
        })

      %{joined: socket}
    end

    test "a matching write pushes an answer", ctx do
      {:ok, _} = Ledger.append(ctx.ledger, [{42, "height", 180}])

      assert_push("answer", %{"facts" => facts})
      assert [%{"attribute" => "height", "value" => 180}] = facts
    end

    test "everything pushed can actually cross a wire", ctx do
      {:ok, _} = Ledger.append(ctx.ledger, [{42, "height", 180}])

      assert_push("answer", payload)

      # assert_push compares terms; a socket encodes them. A snapshot name is
      # keyed by ledger reference inside, and pushing one raw crashed the
      # channel in production with nothing here to catch it.
      assert {:ok, json} = Jason.encode(payload)
      assert %{"name" => %{}} = Jason.decode!(json)
      assert Map.keys(payload["name"]) == [ctx.name]
    end

    test "the answer carries a name that still answers", ctx do
      {:ok, _} = Ledger.append(ctx.ledger, [{42, "height", 180}])

      assert_push("answer", %{"name" => name, "facts" => facts})

      # The name is the contract: asking it again gives the same answer.
      reopened = Snapshot.reopen(%{ctx.ledger => name[ctx.name]})
      assert length(Snapshot.find(reopened, attribute: "height")) == length(facts)
    end

    test "a write outside the question is silent", ctx do
      {:ok, _} = Ledger.append(ctx.ledger, [{42, "colour", "blue"}])

      refute_push("answer", %{}, 50)
    end

    test "each matching write pushes again", ctx do
      # A push crosses three processes — ledger, subscription, channel — and
      # `assert_push` waits 100ms by default, which is a coin flip when the
      # whole suite is running. The timeout is not the property under test.
      {:ok, _} = Ledger.append(ctx.ledger, [{42, "height", 180}])
      assert_push("answer", %{"facts" => first}, 2_000)

      {:ok, _} = Ledger.append(ctx.ledger, [{43, "height", 190}])
      assert_push("answer", %{"facts" => second}, 2_000)

      assert length(first) == 1
      assert length(second) == 2
    end
  end

  describe "letting go" do
    test "leaving stops the pushes", ctx do
      {:ok, _, socket} =
        subscribe_and_join(ctx.socket, "watch:heights", %{
          "ledgers" => [ctx.name],
          "pattern" => %{"attribute" => "height"}
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
