defmodule Blazie.SecretTest do
  @moduledoc """
  The secret plane — a secret is never a fact.

  A credential enters here and is wrapped by the Keyring (envelope-encrypted,
  tenant-scoped, erasable); only the wrapped material is written to a per-holder
  secret world. The plaintext is NEVER a fact value — what any caller holds is a
  handle, and the real value is recovered only at the outbound boundary, which
  the dossier fence (a `:formula`) may not cross. A value that gets used is
  scrubbed on the way back so it cannot ride out in a fact, a log, or a dossier.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Secret, Snapshot, World}

  setup do
    holder = "org-#{System.unique_integer([:positive])}"
    on_exit(fn -> World.close(Secret.world(holder)) end)
    %{holder: holder, token: "tok_live_#{System.unique_integer([:positive])}_supersecret"}
  end

  test "the plaintext is never a fact — only wrapped material is stored", ctx do
    {:ok, handle} = Secret.stow(ctx.holder, "bluesky", ctx.token)
    assert handle == "secret:#{ctx.holder}/bluesky"

    snapshot = Snapshot.open([elem(World.open(Secret.world(ctx.holder)), 1)])

    # The material fact holds a wrapped blob, not the token.
    material = Snapshot.value(snapshot, handle, "material")
    assert is_binary(material)
    assert :binary.match(material, ctx.token) == :nomatch

    # And the token appears NOWHERE in the secret world's facts.
    refute leaks?(ctx.holder, ctx.token)
  end

  test "resolve recovers the exact value at the job boundary", ctx do
    {:ok, handle} = Secret.stow(ctx.holder, "bluesky", ctx.token)
    assert {:ok, value} = Secret.resolve(handle, :job)
    assert value == ctx.token
  end

  test "the dossier fence (:formula) may not resolve a secret", ctx do
    {:ok, handle} = Secret.stow(ctx.holder, "bluesky", ctx.token)

    assert {:error, refusal} = Secret.resolve(handle, :formula)
    assert refusal.problem == :fenced
    assert refusal.repair =~ "fence"
  end

  test "scrub redacts the secret from any term — string, map, nested", ctx do
    log_line = "GET /feed Authorization: Bearer #{ctx.token} 200"
    assert Secret.scrub(log_line, [ctx.token]) =~ "[redacted]"
    refute Secret.scrub(log_line, [ctx.token]) =~ ctx.token

    nested = %{"headers" => %{"authorization" => "Bearer #{ctx.token}"}, "rows" => [ctx.token]}
    scrubbed = Secret.scrub(nested, [ctx.token])
    refute inspect(scrubbed) =~ ctx.token
  end

  test "through uses the secret and scrubs it from the result", ctx do
    {:ok, handle} = Secret.stow(ctx.holder, "bluesky", ctx.token)

    # A hostile-ish function that tries to echo the token back out.
    {:ok, result} = Secret.through(handle, fn tok -> %{"used" => true, "echo" => tok} end)

    assert result["used"] == true
    # The credential proxy scrubbed it — a used secret cannot ride back out.
    refute inspect(result) =~ ctx.token
  end

  test "secrets are tenant-scoped — one holder cannot read another's", ctx do
    other = "org-#{System.unique_integer([:positive])}"
    on_exit(fn -> World.close(Secret.world(other)) end)

    {:ok, mine} = Secret.stow(ctx.holder, "bluesky", ctx.token)
    {:ok, theirs} = Secret.stow(other, "bluesky", "tok_theirs_different")

    assert {:ok, ctx.token} == Secret.resolve(mine, :job)
    assert {:ok, "tok_theirs_different"} == Secret.resolve(theirs, :job)
    # Same name, different worlds — no collision, no cross-read.
    refute mine == theirs
  end

  # Scan every fact in the holder's secret world for the token.
  defp leaks?(holder, token) do
    {:ok, w} = World.open(Secret.world(holder))
    snapshot = Snapshot.open([w])

    snapshot
    |> Snapshot.find([])
    |> Enum.any?(fn fact ->
      is_binary(fact.value) and :binary.match(fact.value, token) != :nomatch
    end)
  end
end
