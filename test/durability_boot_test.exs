defmodule Blazie.DurabilityBootTest do
  @moduledoc """
  A production node cannot be accidentally ephemeral.

  The config existed once, nothing read it, and every world in production was
  in memory — the suite green throughout, the node healthy, the data gone on
  the next deploy. The repair is a refusal at boot, and the refusal lives in
  a function so this file can run it; `config/runtime.exs` only calls it.
  """
  use ExUnit.Case, async: true

  alias Blazie.Durability

  test "both set is a quiet :ok" do
    assert :ok =
             Durability.demanded!(%{
               "LEDGER_DIR" => "/data/ledgers",
               "KEY_DIR" => "/data/keys"
             })
  end

  test "either missing refuses, naming what to set and why" do
    for env <- [
          %{"KEY_DIR" => "/data/keys"},
          %{"LEDGER_DIR" => "/data/ledgers"},
          %{},
          # The empty string is not a path — a compose file with `LEDGER_DIR=`
          # would otherwise pass the check and fail the mount.
          %{"LEDGER_DIR" => "", "KEY_DIR" => "/data/keys"}
        ] do
      error = assert_raise(RuntimeError, fn -> Durability.demanded!(env) end)

      assert error.message =~ "refuses to boot"
      assert error.message =~ "persistent storage"
    end
  end

  test "the missing half is the one named" do
    error =
      assert_raise(RuntimeError, fn -> Durability.demanded!(%{"LEDGER_DIR" => "/x"}) end)

    assert error.message =~ "KEY_DIR not set"
    refute error.message =~ "LEDGER_DIR and KEY_DIR not set"
  end
end
