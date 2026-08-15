defmodule Blazie.EgressConsumersTest do
  @moduledoc """
  git, luarocks and webfetch — thin consumers of the one egress port.

  Each builds the right HTTPS URL for a well-known host and fetches it
  through Blazie.Egress, inheriting every guard. They add no second path
  out: delete Egress and they cannot reach anything.
  """
  use ExUnit.Case, async: false

  alias Blazie.Egress

  defp fake(body) do
    me = self()

    fn _m, url, _h, _o ->
      send(me, {:url, List.to_string(url)})
      {:ok, 200, [], body}
    end
  end

  defp opts(body) do
    [
      transport: fake(body),
      resolve: fn _ -> {:ok, {1, 2, 3, 4}} end,
      audit: false,
      allow: ["github.com", "codeload.github.com", "luarocks.org", "example.com"]
    ]
  end

  test "webfetch fetches an allowlisted URL through the port" do
    assert {:ok, "page"} = Egress.webfetch("https://example.com/x", opts("page"))
    assert_received {:url, "https://example.com/x"}
  end

  test "webfetch inherits the allowlist — an unlisted host is refused" do
    assert {:error, %{problem: :not_allowed}} =
             Egress.webfetch("https://nope.example/x", opts("page"))
  end

  test "git fetches a ref tarball from a git host" do
    assert {:ok, "tarbytes"} = Egress.git("github.com/owner/repo", "v1.2.3", opts("tarbytes"))
    assert_received {:url, url}
    assert url =~ "github.com/owner/repo"
    assert url =~ "v1.2.3"
  end

  test "luarocks fetches a rock by name and version" do
    assert {:ok, "rockbytes"} = Egress.luarocks("json", "1.0.0-1", opts("rockbytes"))
    assert_received {:url, url}
    assert url =~ "luarocks.org"
    assert url =~ "json"
    assert url =~ "1.0.0-1"
  end
end
