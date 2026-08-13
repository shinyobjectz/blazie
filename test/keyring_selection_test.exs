defmodule Blazie.KeyringSelectionTest do
  @moduledoc "Which keyring a deployment gets, and why."
  use ExUnit.Case, async: false

  alias Blazie.Keyring

  setup do
    was = Application.get_env(:blazie, :kms_key)
    on_exit(fn -> Application.put_env(:blazie, :kms_key, was) end)
    :ok
  end

  test "no KMS key configured means the local keyring" do
    Application.delete_env(:blazie, :kms_key)

    assert {Keyring.Local, opts} = Keyring.configured()
    assert Keyword.has_key?(opts, :dir)
  end

  test "naming a KMS key selects the KMS keyring" do
    Application.put_env(
      :blazie,
      :kms_key,
      "projects/p/locations/global/keyRings/r/cryptoKeys/k"
    )

    assert {Keyring.GCP, opts} = Keyring.configured()
    assert opts[:key] =~ "cryptoKeys/k"
  end

  test "both implementations satisfy the same behaviour" do
    for module <- [Keyring.Local, Keyring.GCP] do
      Code.ensure_loaded!(module)

      for {fun, arity} <- [open: 1, wrap: 3, unwrap: 3, destroy: 2] do
        assert function_exported?(module, fun, arity), "#{inspect(module)}.#{fun}/#{arity}"
      end
    end
  end
end
