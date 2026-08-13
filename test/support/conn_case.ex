defmodule Blazie.ConnCase do
  @moduledoc "A connection to the surface, and a ledger to point it at."

  use ExUnit.CaseTemplate

  alias Blazie.{Attribute, Authority, World}

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest

      import Blazie.ConnCase

      alias Blazie.{Attribute, World, Snapshot}

      @endpoint Blazie.Surface.Endpoint
    end
  end

  setup do
    # Every operation that names a ledger is checked, so a test connection
    # carries a caller and `open_ledger/0` grants to it. A test that wants to
    # be refused replaces or drops the header itself.
    token = "conn-token-#{System.unique_integer([:positive])}"
    Process.put(:blazie_test_token, token)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")

    {:ok, conn: conn, token: token}
  end

  @doc "A ledger named the way a caller would name one — with a string."
  def open_ledger do
    name = "test-ledger-#{System.unique_integer([:positive])}"
    {:ok, _} = World.open(name)

    # Granted to this test's caller, because every operation that names a
    # ledger is checked and a test that skipped this would only ever see 403.
    if token = Process.get(:blazie_test_token), do: Authority.grant(token, name)

    ExUnit.Callbacks.on_exit(fn -> World.close(name) end)
    name
  end

  @doc """
  Define an attribute in a ledger.

  Every write is checked, so a surface test that writes has to have defined
  what it writes — which is the bootstrap doing its job rather than a chore.
  """
  def define(world, attribute, opts \\ []) do
    {:ok, ref} = World.open(world)
    {:ok, _tx} = World.append(ref, Attribute.define(attribute, opts))
    :ok
  end
end
