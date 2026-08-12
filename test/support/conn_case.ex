defmodule LazyRiver.ConnCase do
  @moduledoc "A connection to the surface, and a ledger to point it at."

  use ExUnit.CaseTemplate

  alias LazyRiver.{Attribute, Ledger}

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest

      import LazyRiver.ConnCase

      alias LazyRiver.{Attribute, Ledger, Snapshot}

      @endpoint LazyRiver.Surface.Endpoint
    end
  end

  setup do
    {:ok,
     conn:
       Phoenix.ConnTest.build_conn()
       |> Plug.Conn.put_req_header("content-type", "application/json")}
  end

  @doc "A ledger named the way a caller would name one — with a string."
  def open_ledger do
    name = "test-ledger-#{System.unique_integer([:positive])}"
    {:ok, _} = Ledger.open(name)
    ExUnit.Callbacks.on_exit(fn -> Ledger.close(name) end)
    name
  end

  @doc """
  Define an attribute in a ledger.

  Every write is checked, so a surface test that writes has to have defined
  what it writes — which is the bootstrap doing its job rather than a chore.
  """
  def define(ledger, attribute, opts \\ []) do
    {:ok, ref} = Ledger.open(ledger)
    {:ok, _tx} = Ledger.append(ref, Attribute.define(attribute, opts))
    :ok
  end
end
