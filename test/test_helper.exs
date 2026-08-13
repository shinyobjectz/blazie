ExUnit.start(exclude: [:gcp, :crash, :load, :live, :object_storage, :throughput])

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
