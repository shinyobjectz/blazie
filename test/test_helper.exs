# `LEDGER_SYNC=true mix test` runs the whole suite with every file store
# fsyncing each transaction — the durable path, which no test would otherwise
# take, and a flag no test sets is an untested path. CI runs the suite both
# ways.
if System.get_env("LEDGER_SYNC") == "true" do
  Application.put_env(:blazie, :ledger_sync, true)
end

ExUnit.start(exclude: [:gcp, :crash, :load, :live, :object_storage, :python, :throughput])

defmodule Blazie.TestLedger do
  @moduledoc """
  A world that closes itself when the test ends.

  Names are tuples rather than atoms on purpose — it is the same thing a tenant
  name would be, and using atoms here would hide the leak the registry exists
  to prevent.
  """

  alias Blazie.World

  def open do
    name = {:test, System.unique_integer([:positive])}
    {:ok, world} = World.open(name)
    ExUnit.Callbacks.on_exit(fn -> World.close(name) end)
    world
  end
end
