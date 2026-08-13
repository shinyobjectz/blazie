defmodule Blazie.IdentityTest do
  @moduledoc """
  Who a token belongs to, and who may have one at all.

  `Authority` knew what a token may name and deliberately not who held it. This
  is the other half, and the thing worth testing hardest is not the happy path
  — it is that every way in leads to the same door, so the rule about who is
  allowed cannot be true in one flow and false in another.

  GitHub is a behaviour here. A test that reached the real one would either
  need a network and a human, or prove nothing.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Authority, Identity, World, Snapshot}

  # A GitHub that answers however a test needs it to, from the process
  # dictionary so each test sets its own without a global.
  defmodule FakeHub do
    @behaviour Blazie.Identity.GitHub

    def script(answers), do: Process.put(:fake_hub, answers)
    defp answer(key, default), do: Process.get(:fake_hub, %{})[key] || default

    @impl true
    def exchange(_code), do: answer(:exchange, {:ok, "gh-token"})

    @impl true
    def begin_device,
      do:
        answer(
          :begin_device,
          {:ok,
           %{
             device_code: "dc",
             user_code: "ABCD-1234",
             verification_uri: "https://github.com/login/device",
             interval: 5,
             expires_in: 900
           }}
        )

    @impl true
    def poll_device(_code), do: answer(:poll_device, {:ok, "gh-token"})

    @impl true
    def login(_token), do: answer(:login, {:ok, "shinyobjectz"})
  end

  setup do
    on_exit(fn -> World.close(Identity.world()) end)
    FakeHub.script(%{})
    %{opts: [github: FakeHub, github_logins: ["shinyobjectz"]]}
  end

  describe "the door" do
    test "an allowed login is admitted and gets a token", ctx do
      assert {:ok, %{token: token, login: "shinyobjectz"}} =
               Identity.admit("shinyobjectz", ctx.opts)

      assert is_binary(token) and byte_size(token) > 20
      assert Identity.login_of(token) == "shinyobjectz"
    end

    test "a login nobody allowed is refused, and told how to be allowed", ctx do
      assert {:error, refusal} = Identity.admit("someone-else", ctx.opts)

      assert refusal.problem == :not_allowed
      assert refusal.repair =~ "GITHUB_LOGINS"
    end

    test "an empty allowlist admits nobody rather than everybody", _ctx do
      assert {:error, refusal} = Identity.admit("shinyobjectz", github_logins: [])

      assert refusal.problem == :nobody_is_allowed
      # The failure a forgotten setting should produce is a closed door.
      assert refusal.repair =~ "admits nobody"
    end

    test "two tokens for one login are two callers", ctx do
      {:ok, first} = Identity.admit("shinyobjectz", ctx.opts)
      {:ok, second} = Identity.admit("shinyobjectz", ctx.opts)

      assert first.token != second.token
      assert Authority.caller(first.token) != Authority.caller(second.token)
      assert Identity.login_of(first.token) == Identity.login_of(second.token)
      assert Identity.admitted() == ["shinyobjectz"]
    end

    test "the world holds the fingerprint and never the token", ctx do
      {:ok, %{token: token}} = Identity.admit("shinyobjectz", ctx.opts)

      {:ok, world} = World.open(Identity.world())
      facts = Snapshot.find(Snapshot.open([world]), attribute: "github_login")

      assert Enum.any?(facts, &(&1.id == Authority.caller(token)))
      refute Enum.any?(facts, &(&1.id == token))

      raw = Snapshot.facts(Snapshot.open([world])) |> inspect()
      refute raw =~ token, "the token itself reached the world"
    end
  end

  describe "the browser's way in" do
    test "a code becomes a token", ctx do
      assert {:ok, %{token: _, login: "shinyobjectz"}} = Identity.from_code("abc123", ctx.opts)
    end

    test "GitHub refusing the code is refused here", ctx do
      FakeHub.script(%{exchange: {:error, %{problem: :bad_verification_code, repair: "no"}}})

      assert {:error, %{problem: :bad_verification_code}} = Identity.from_code("nope", ctx.opts)
    end

    test "a login GitHub confirms but the allowlist does not is still refused", ctx do
      FakeHub.script(%{login: {:ok, "a-stranger"}})

      assert {:error, %{problem: :not_allowed}} = Identity.from_code("abc123", ctx.opts)
    end
  end

  describe "the terminal's way in" do
    test "beginning hands back what a human has to be shown", ctx do
      assert {:ok, began} = Identity.begin_device(ctx.opts)

      assert began.user_code == "ABCD-1234"
      assert began.verification_uri =~ "github.com"
      assert is_integer(began.interval)
    end

    test "pending is an answer, not a failure", ctx do
      FakeHub.script(%{poll_device: {:pending, nil}})

      assert {:pending, nil} = Identity.from_device("dc", ctx.opts)
    end

    test "slow down carries the interval GitHub asked for", ctx do
      FakeHub.script(%{poll_device: {:pending, 10}})

      assert {:pending, 10} = Identity.from_device("dc", ctx.opts)
    end

    test "authorized becomes a token", ctx do
      assert {:ok, %{login: "shinyobjectz"}} = Identity.from_device("dc", ctx.opts)
    end

    test "and the allowlist applies here exactly as it does in a browser", ctx do
      FakeHub.script(%{login: {:ok, "a-stranger"}})

      assert {:error, %{problem: :not_allowed}} = Identity.from_device("dc", ctx.opts)
    end

    test "device flow being switched off says so, and says where to switch it on", _ctx do
      FakeHub.script(%{
        begin_device:
          {:error,
           %{
             problem: :device_flow_disabled,
             repair: "Tick “Enable Device Flow” on its settings page"
           }}
      })

      assert {:error, refusal} = Identity.begin_device(github: FakeHub)
      assert refusal.problem == :device_flow_disabled
      assert refusal.repair =~ "Enable Device Flow"
    end
  end

  describe "a token is a caller like any other" do
    test "it holds no grants until it is given some", ctx do
      {:ok, %{token: token}} = Identity.admit("shinyobjectz", ctx.opts)

      assert Authority.allowed(token) == []
      refute Authority.may_name?(token, "anything")
    end

    test "and grants work on it the ordinary way", ctx do
      {:ok, %{token: token}} = Identity.admit("shinyobjectz", ctx.opts)
      {:ok, _} = Authority.grant(token, "tenant-7")

      assert Authority.may_name?(token, "tenant-7")
      assert Authority.allowed(token) == ["tenant-7"]
    end

    test "an unknown token belongs to nobody", _ctx do
      assert Identity.login_of("not-a-token-anyone-issued") == nil
    end
  end
end
