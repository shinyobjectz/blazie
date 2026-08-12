defmodule LazyRiver.Keyring.GCPTest do
  @moduledoc """
  One KMS key, and everything else local.

  Excluded by default because it calls Google. Run it with:

      mix test --include gcp
  """
  use ExUnit.Case, async: false

  alias LazyRiver.Keyring.GCP

  @moduletag :gcp

  @key "projects/careful-striker-500202-p7/locations/global/keyRings/lazyriver/cryptoKeys/master"

  setup do
    dir = Path.join(System.tmp_dir!(), "lazyriver_gcp_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, subject: "person-#{System.unique_integer([:positive])}"}
  end

  test "the master is wrapped by KMS and never stored in the clear", ctx do
    {:ok, _ring} = GCP.open(dir: ctx.dir, key: @key)

    on_disk = File.read!(Path.join(ctx.dir, "master.wrapped"))

    assert byte_size(on_disk) > 0
    # KMS ciphertext, not a 32-byte key sitting in a file.
    refute byte_size(on_disk) == 32
  end

  test "wrap and unwrap round trip", ctx do
    {:ok, ring} = GCP.open(dir: ctx.dir, key: @key)
    dek = :crypto.strong_rand_bytes(32)

    {:ok, wrapped} = GCP.wrap(ring, dek, ctx.subject)

    assert {:ok, ^dek} = GCP.unwrap(ring, wrapped, ctx.subject)
  end

  test "reopening asks KMS again rather than trusting anything local", ctx do
    {:ok, ring} = GCP.open(dir: ctx.dir, key: @key)
    dek = :crypto.strong_rand_bytes(32)
    {:ok, wrapped} = GCP.wrap(ring, dek, ctx.subject)

    {:ok, reopened} = GCP.open(dir: ctx.dir, key: @key)

    assert {:ok, ^dek} = GCP.unwrap(reopened, wrapped, ctx.subject)
  end

  test "destroying a subject is local and immediate", ctx do
    {:ok, ring} = GCP.open(dir: ctx.dir, key: @key)
    dek = :crypto.strong_rand_bytes(32)
    {:ok, wrapped} = GCP.wrap(ring, dek, ctx.subject)

    :ok = GCP.destroy(ring, ctx.subject)

    # No KMS key was harmed. One entry went, and every data key it wrapped is
    # unopenable — which is why this scales to any number of subjects.
    assert GCP.unwrap(ring, wrapped, ctx.subject) == :forgotten
  end
end
