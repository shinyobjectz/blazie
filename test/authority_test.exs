defmodule Blazie.AuthorityTest do
  @moduledoc """
  Doctrine 17: authorization is which ledgers a caller may name. Not row rules,
  not predicates.

  Grants are facts, in a world, read from a snapshot — so revoking is a later
  fact correcting an earlier one, and "who could open what, and when" is a
  question rather than an audit log.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Authority, World}

  # A token per test rather than a shared reset: grants are keyed by caller, so
  # distinct callers cannot interfere and nothing global has to be torn down.
  setup do
    %{token: "token-#{System.unique_integer([:positive])}"}
  end

  defp another_caller, do: "other-token-#{System.unique_integer([:positive])}"

  describe "a caller may name only what it was granted" do
    test "nothing is granted by default", %{token: token} do
      refute Authority.may_name?(token, "tenant-7")
      assert Authority.allowed(token) == []
    end

    test "a grant lets it name that world and no other", %{token: token} do
      Authority.grant(token, "tenant-7")

      assert Authority.may_name?(token, "tenant-7")
      refute Authority.may_name?(token, "tenant-8")
      assert Authority.allowed(token) == ["tenant-7"]
    end

    test "one caller's grant is not another's", %{token: token} do
      Authority.grant(token, "tenant-7")

      refute Authority.may_name?(another_caller(), "tenant-7")
    end

    test "a caller can be granted several", %{token: token} do
      Authority.grant(token, "tenant-7")
      Authority.grant(token, "shared")

      assert Authority.allowed(token) |> Enum.sort() == ["shared", "tenant-7"]
    end
  end

  describe "revoking is a later fact, not a deletion" do
    test "a revoked grant stops working", %{token: token} do
      Authority.grant(token, "tenant-7")
      Authority.revoke(token, "tenant-7")

      refute Authority.may_name?(token, "tenant-7")
      assert Authority.allowed(token) == []
    end

    test "granting again after a revoke works", %{token: token} do
      Authority.grant(token, "tenant-7")
      Authority.revoke(token, "tenant-7")
      Authority.grant(token, "tenant-7")

      assert Authority.may_name?(token, "tenant-7")
    end

    test "the history survives, because nothing was deleted", %{token: token} do
      Authority.grant(token, "tenant-7")
      Authority.revoke(token, "tenant-7")

      assert length(Authority.history(token, "tenant-7")) == 2
    end
  end

  describe "the reserved ledgers are never nameable" do
    # The rule, not a list: everything whose contents change authorization or
    # key state. A caller who could write `$erasures` would write forged
    # tombstones, and the keyring reconciles against tombstones every time it
    # opens — remote key destruction across ledgers, from one grant.
    test "the set covers each module's own world, pinned both ways" do
      assert Authority.world() in Authority.reserved()
      assert Blazie.Erasure.world() in Authority.reserved()
      assert "$backup" in Authority.reserved()
    end

    test "not by default", %{token: token} do
      for world <- Authority.reserved() do
        refute Authority.may_name?(token, world)
      end
    end

    test "not even when a grant was forged straight into the world", %{token: token} do
      # `grant/2` writes without checking — the fact lands. The refusal has to
      # hold anyway, because a fact in the world is exactly what an attacker
      # who reached the bytes can make.
      for world <- Authority.reserved() do
        Authority.grant(token, world)
        refute Authority.may_name?(token, world)
      end
    end

    test "granting one is refused at the door rather than silently ignored", %{token: token} do
      for world <- Authority.reserved() do
        assert {:error, refusal} = Authority.grant_checked(token, world)
        assert refusal.problem == :not_nameable
        assert refusal.repair =~ "no caller may ever name it"
      end
    end
  end

  describe "a caller is a token's fingerprint, not the token" do
    test "the token itself is never stored", %{token: token} do
      Authority.grant(token, "tenant-7")

      {:ok, world} = World.open(Authority.world())
      facts = Blazie.Snapshot.open([world]) |> Blazie.Snapshot.facts()

      refute Enum.any?(facts, fn fact ->
               token in [fact.id, fact.value]
             end)
    end

    test "but the same token still resolves", %{token: token} do
      Authority.grant(token, "tenant-7")

      assert Authority.may_name?(token, "tenant-7")
      refute Authority.may_name?(another_caller(), "tenant-7")
    end
  end
end
