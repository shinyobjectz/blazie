defmodule Blazie.EgressTest do
  @moduledoc """
  The egress port — the one hardened outbound door. Attacked first.

  Every outbound byte in the tree passes here, so the security lives here:
  default-deny allowlist (host AND scheme), an SSRF guard that resolves the
  host to IPs and rejects private/loopback/link-local/metadata ranges (even
  when an allowlisted name resolves to one — DNS rebinding), a per-vendor
  Limit gate, Secret-plane credential injection with response scrub, an
  audit fact per call, and a response-size cap. Transport and resolver are
  injectable so the security is tested without a network.
  """
  use ExUnit.Case, async: false

  alias Blazie.Egress

  # A fake transport: returns a canned response, records what it was asked.
  defp transport(response) do
    me = self()

    fn method, url, headers, opts ->
      send(me, {:dialed, method, url, headers, opts})
      response
    end
  end

  # A resolver that maps a host to chosen IPs (DNS under our control).
  defp resolver(map) do
    fn host -> Map.get(map, host, {:error, :nxdomain}) end
  end

  @ok {:ok, 200, [{"content-type", "text/plain"}], "hello"}

  defp base(extra) do
    Keyword.merge(
      [
        allow: ["luarocks.org", "github.com", "raw.githubusercontent.com"],
        transport: transport(@ok),
        resolve:
          resolver(%{
            "luarocks.org" => {:ok, {151, 101, 1, 1}},
            "github.com" => {:ok, {140, 82, 112, 3}},
            "raw.githubusercontent.com" => {:ok, {185, 199, 108, 133}},
            "evil.example" => {:ok, {10, 0, 0, 5}},
            "rebind.example" => {:ok, {127, 0, 0, 1}}
          }),
        audit: false
      ],
      extra
    )
  end

  # ── the allowlist: default-deny ──────────────────────────────────────────────

  test "an allowlisted https host is fetched" do
    assert {:ok, resp} = Egress.fetch("https://luarocks.org/manifest", base([]))
    assert resp.status == 200
    assert resp.body == "hello"
    assert_received {:dialed, :get, ~c"https://luarocks.org/manifest", _, _}
  end

  test "a host not on the allowlist is refused, dialing nothing" do
    assert {:error, refusal} = Egress.fetch("https://not-listed.example/x", base([]))
    assert refusal.problem == :not_allowed
    assert refusal.repair =~ "allowlist"
    refute_received {:dialed, _, _, _, _}
  end

  test "a non-https scheme is refused" do
    assert {:error, r} = Egress.fetch("http://luarocks.org/x", base([]))
    assert r.problem == :scheme_refused
    assert {:error, r2} = Egress.fetch("file:///etc/passwd", base([]))
    assert r2.problem == :scheme_refused
    refute_received {:dialed, _, _, _, _}
  end

  # ── SSRF: resolve, then check the IP ─────────────────────────────────────────

  test "an allowlisted host that resolves to a private IP is refused (rebinding)" do
    # rebind.example is allowlisted below but resolves to 127.0.0.1.
    opts = base(allow: ["rebind.example"])
    assert {:error, r} = Egress.fetch("https://rebind.example/x", opts)
    assert r.problem == :ssrf_blocked
    assert r.repair =~ "private"
    refute_received {:dialed, _, _, _, _}
  end

  test "the metadata endpoint IP is refused even if named directly" do
    opts =
      base(
        allow: ["metadata.google.internal"],
        resolve: resolver(%{"metadata.google.internal" => {:ok, {169, 254, 169, 254}}})
      )

    assert {:error, r} = Egress.fetch("https://metadata.google.internal/", opts)
    assert r.problem == :ssrf_blocked
  end

  test "every private/loopback/link-local range is blocked" do
    for ip <- [
          {127, 0, 0, 1},
          {10, 1, 2, 3},
          {192, 168, 0, 1},
          {172, 16, 5, 5},
          {169, 254, 1, 1},
          {0, 0, 0, 0}
        ] do
      opts = base(allow: ["h"], resolve: resolver(%{"h" => {:ok, ip}}))

      assert {:error, %{problem: :ssrf_blocked}} = Egress.fetch("https://h/x", opts),
             "#{inspect(ip)} was not blocked"
    end
  end

  test "a host that does not resolve is refused, not dialed" do
    opts = base(resolve: resolver(%{}))
    assert {:error, r} = Egress.fetch("https://github.com/x", opts)
    assert r.problem == :unresolvable
    refute_received {:dialed, _, _, _, _}
  end

  # ── Limit: the account-wide door ─────────────────────────────────────────────

  test "an empty rate bucket refuses before dialing" do
    limiter = fn _vendor -> {:error, %{problem: :rate_limited, repair: "slow down"}} end
    opts = base(limit: limiter)

    assert {:error, r} = Egress.fetch("https://luarocks.org/x", opts)
    assert r.problem == :rate_limited
    refute_received {:dialed, _, _, _, _}
  end

  # ── Secret: credential in at the boundary, scrubbed on the way out ───────────

  test "a credential is injected as a header and scrubbed from the response" do
    # The response echoes the token (a hostile-ish upstream); it must not survive.
    echo = {:ok, 200, [], "authorized as SECRETTOKEN123"}

    opts =
      base(
        transport: transport(echo),
        secret: fn "gh" -> {:ok, "SECRETTOKEN123"} end
      )

    assert {:ok, resp} =
             Egress.fetch("https://github.com/x", Keyword.put(opts, :credential, "gh"))

    # The header carried the token…
    assert_received {:dialed, :get, _, headers, _}
    assert Enum.any?(headers, fn {k, v} -> k == "authorization" and v =~ "SECRETTOKEN123" end)
    # …but the body that comes back is scrubbed.
    refute resp.body =~ "SECRETTOKEN123"
    assert resp.body =~ "[redacted]"
  end

  # ── caps ─────────────────────────────────────────────────────────────────────

  test "a response over the size cap is refused" do
    big = {:ok, 200, [], String.duplicate("x", 100_000)}
    opts = base(transport: transport(big), max_bytes: 1_000)

    assert {:error, r} = Egress.fetch("https://luarocks.org/x", opts)
    assert r.problem == :too_large
    assert r.repair =~ "1000"
  end

  test "a redirect to a non-allowlisted host is refused" do
    redir = {:ok, 302, [{"location", "https://evil.example/x"}], ""}
    opts = base(transport: transport(redir))

    assert {:error, r} = Egress.fetch("https://github.com/x", opts)
    assert r.problem == :redirect_refused
  end

  # ── audit: a call is a fact ──────────────────────────────────────────────────

  test "each call writes an audit fact — host, status, bytes, never the secret" do
    world = {:"$egress_test", System.unique_integer([:positive])}
    on_exit(fn -> Blazie.World.close(world) end)

    opts = base(audit: world, by: "job-7", credential: nil)
    assert {:ok, _} = Egress.fetch("https://luarocks.org/manifest", opts)

    {:ok, w} = Blazie.World.open(world)
    snapshot = Blazie.Snapshot.open([w])
    [call | _] = Blazie.Snapshot.find(snapshot, attribute: "is", value: "egress")
    assert Blazie.Snapshot.value(snapshot, call.id, "host") == "luarocks.org"
    assert Blazie.Snapshot.value(snapshot, call.id, "status") == 200
    assert Blazie.Snapshot.value(snapshot, call.id, "bytes") == 5
    # the by-provenance names who reached out
    [fact | _] = Blazie.Snapshot.find(snapshot, id: call.id, attribute: "host")
    assert fact.by == "job-7"
  end
end
