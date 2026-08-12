ExUnit.start(exclude: [:gcp])

defmodule LazyRiver.TestLedger do
  @moduledoc """
  A ledger that closes itself when the test ends.

  Names are tuples rather than atoms on purpose — it is the same thing a tenant
  name would be, and using atoms here would hide the leak the registry exists
  to prevent.
  """

  alias LazyRiver.Ledger

  def open do
    name = {:test, System.unique_integer([:positive])}
    {:ok, ledger} = Ledger.open(name)
    ExUnit.Callbacks.on_exit(fn -> Ledger.close(name) end)
    ledger
  end
end
