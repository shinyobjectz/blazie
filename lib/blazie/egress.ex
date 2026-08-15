defmodule Blazie.Egress do
  @moduledoc """
  The one hardened outbound door. Every external byte leaves through here.

  A guest has no sockets; a `:job`'s only reach is what the host grants, and
  the host grants exactly this. Consolidating egress into one function is
  what makes it securable: the allowlist, the SSRF guard, the rate limit,
  the credential proxy, the audit and the caps are all in one place, and
  there is no second path around them. git, luarocks and webfetch are all
  HTTPS, so they are all consumers of this — not three doors, one.

  The security, in order, before a single byte is dialed:

    1. **Scheme** — HTTPS only (config may add HTTP for a named dev host).
    2. **Allowlist** — the host must be named. Default-deny.
    3. **SSRF** — resolve the host to IPs and reject every private, loopback,
       link-local, and metadata range. This runs AFTER the allowlist and on
       the resolved address, so a name that resolves to 127.0.0.1 (DNS
       rebinding) or the 169.254.169.254 metadata endpoint is refused even
       when the NAME is allowlisted.
    4. **Limit** — the account-wide token bucket per vendor (the same door
       `Model` passes), so one job cannot starve the others or a vendor.
    5. **Credential** — resolved from the Secret plane at the boundary,
       injected as a header, and SCRUBBED from the response, so a token
       used never rides back out in a body, a fact, or a log.

  Then the response is size-capped, redirects off the allowlist are refused,
  and the whole call is written as an audit fact — host, status, bytes, and
  the provenance of who reached out — never the URL's secret.

  `transport:`, `resolve:`, `limit:`, and `secret:` are injectable so the
  security is tested without a network; production wires `:httpc`, `:inet`,
  `Blazie.Limit` and `Blazie.Secret`.
  """

  alias Blazie.World

  @type refusal :: %{problem: atom(), repair: String.t()}
  @type response :: %{status: non_neg_integer(), headers: list(), body: binary()}

  @default_max_bytes 25 * 1024 * 1024
  @default_timeout 30_000

  @doc """
  Fetch a URL through the door. Returns `{:ok, response}` or `{:error, refusal}`.

  Options: `allow:` (allowlisted hosts, required), `credential:` (a Secret
  handle to inject), `by:` (provenance for the audit), `max_bytes:`,
  `timeout:`, `audit:` (a world name, or false), plus the injectable
  `transport:`/`resolve:`/`limit:`/`secret:` seams.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, response()} | {:error, refusal()}
  def fetch(url, opts) do
    with {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri, opts),
         :ok <- check_allow(uri, opts),
         :ok <- check_ssrf(uri, opts),
         :ok <- check_limit(uri, opts),
         {:ok, headers} <- credential_headers(opts),
         {:ok, status, resp_headers, body} <- dial(:get, url, headers, opts),
         :ok <- check_size(body, opts),
         :ok <- check_redirect(status, resp_headers, opts) do
      body = scrub(body, opts)
      audit(uri, status, byte_size(body), opts)
      {:ok, %{status: status, headers: resp_headers, body: body}}
    end
  end

  # ── the consumers: git, luarocks, webfetch — all HTTPS over the one door ─────

  @doc """
  Fetch an arbitrary allowlisted URL — the governed replacement for a bare
  `http.get`. Returns `{:ok, body}` or a refusal. This is what a `:job`'s
  webfetch is.
  """
  @spec webfetch(String.t(), keyword()) :: {:ok, binary()} | {:error, refusal()}
  def webfetch(url, opts) do
    with {:ok, resp} <- fetch(url, opts), do: {:ok, resp.body}
  end

  @doc """
  Fetch a git ref as a tarball. `repo` is `host/owner/name`; the archive URL
  is built for the host's known scheme (GitHub/GitLab serve
  `.../archive/<ref>.tar.gz`). No git binary, no clone — the resolved bytes
  ride the same door, so the allowlist and SSRF guard cover it.
  """
  @spec git(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, refusal()}
  def git(repo, ref, opts) do
    url =
      case String.split(repo, "/", parts: 2) do
        ["github.com", path] -> "https://github.com/#{path}/archive/#{ref}.tar.gz"
        ["gitlab.com", path] -> "https://gitlab.com/#{path}/-/archive/#{ref}/#{ref}.tar.gz"
        [host, path] -> "https://#{host}/#{path}/archive/#{ref}.tar.gz"
      end

    webfetch(url, opts)
  end

  @doc """
  Fetch a luarocks package's `.src.rock` (a zip) by name and version. The
  rock's contents are unpacked and vetted by `Blazie.Package.install`; this
  only reaches the bytes, through the door.
  """
  @spec luarocks(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, refusal()}
  def luarocks(name, version, opts) do
    webfetch("https://luarocks.org/manifests/#{name}/#{name}-#{version}.src.rock", opts)
  end

  # ── the checks ───────────────────────────────────────────────────────────────

  defp parse(url) do
    case URI.parse(url) do
      %URI{host: host, scheme: scheme} when is_binary(host) and is_binary(scheme) ->
        {:ok, %URI{} = URI.parse(url)}

      _ ->
        {:error, %{problem: :bad_url, repair: "#{inspect(url)} is not a URL with a host."}}
    end
  end

  defp check_scheme(%URI{scheme: "https"}, _opts), do: :ok

  defp check_scheme(%URI{scheme: "http", host: host}, opts) do
    if host in Keyword.get(opts, :allow_http, []),
      do: :ok,
      else: scheme_refused()
  end

  defp check_scheme(_uri, _opts), do: scheme_refused()

  defp scheme_refused do
    {:error,
     %{
       problem: :scheme_refused,
       repair: "the egress door speaks HTTPS only — no http, file, ftp, or anything else."
     }}
  end

  defp check_allow(%URI{host: host}, opts) do
    allow = Keyword.get(opts, :allow, [])

    if host in allow do
      :ok
    else
      {:error,
       %{
         problem: :not_allowed,
         repair:
           "#{host} is not on the egress allowlist. The door is default-deny; add the host to " <>
             "`config :blazie, :egress, allow: [...]` if it should be reachable."
       }}
    end
  end

  defp check_ssrf(%URI{host: host}, opts) do
    resolve = Keyword.get(opts, :resolve, &default_resolve/1)

    case resolve.(host) do
      {:ok, ip} ->
        if public_ip?(ip) do
          :ok
        else
          {:error,
           %{
             problem: :ssrf_blocked,
             repair:
               "#{host} resolves to #{:inet.ntoa(ip)}, a private/loopback/link-local/metadata " <>
                 "address. The door refuses non-public IPs even for an allowlisted name, so a " <>
                 "rebind or an internal target cannot be reached."
           }}
        end

      {:error, _} ->
        {:error, %{problem: :unresolvable, repair: "#{host} does not resolve to an address."}}
    end
  end

  # RFC 1918 + loopback + link-local + metadata + unspecified + CGNAT + ULA.
  defp public_ip?({0, _, _, _}), do: false
  defp public_ip?({10, _, _, _}), do: false
  defp public_ip?({127, _, _, _}), do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, b, _, _}) when b in 16..31, do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({100, b, _, _}) when b in 64..127, do: false
  defp public_ip?({a, _, _, _}) when a >= 224, do: false
  defp public_ip?({_, _, _, _}), do: true
  # IPv6: loopback, unspecified, link-local (fe80::/10), ULA (fc00::/7).
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: false
  defp public_ip?({_, _, _, _, _, _, _, _}), do: true
  defp public_ip?(_), do: false

  defp check_limit(%URI{host: host}, opts) do
    case Keyword.get(opts, :limit) do
      nil -> :ok
      limiter when is_function(limiter, 1) -> limiter.(host)
    end
  end

  defp credential_headers(opts) do
    case Keyword.get(opts, :credential) do
      nil ->
        {:ok, []}

      handle ->
        secret = Keyword.get(opts, :secret, &default_secret/1)

        case secret.(handle) do
          {:ok, token} ->
            Process.put(:egress_secret, token)
            {:ok, [{"authorization", "Bearer #{token}"}]}

          {:error, refusal} ->
            {:error, refusal}
        end
    end
  end

  defp dial(method, url, headers, opts) do
    transport = Keyword.get(opts, :transport, &default_transport/4)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    transport.(method, String.to_charlist(url), headers, timeout: timeout)
  end

  defp check_size(body, opts) do
    cap = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if byte_size(body) > cap do
      {:error,
       %{
         problem: :too_large,
         repair:
           "the response exceeded #{cap} bytes. Fetch a smaller resource, or raise max_bytes."
       }}
    else
      :ok
    end
  end

  defp check_redirect(status, headers, opts) when status in 300..399 do
    case List.keyfind(headers, "location", 0) do
      {_, location} ->
        case check_allow(URI.parse(location), opts) do
          :ok ->
            :ok

          {:error, _} ->
            {:error,
             %{
               problem: :redirect_refused,
               repair: "redirect to #{location} is off the allowlist."
             }}
        end

      nil ->
        :ok
    end
  end

  defp check_redirect(_status, _headers, _opts), do: :ok

  defp scrub(body, opts) do
    case Keyword.get(opts, :credential) do
      nil ->
        body

      _handle ->
        case Process.get(:egress_secret) do
          nil -> body
          token -> Blazie.Secret.scrub(body, [token])
        end
    end
  end

  defp audit(_uri, _status, _bytes, opts) when opts == [], do: :ok

  defp audit(%URI{host: host, path: path}, status, bytes, opts) do
    case Keyword.get(opts, :audit) do
      world when world not in [nil, false] ->
        id = "egress-#{System.unique_integer([:positive])}"
        by = Keyword.get(opts, :by, "job")
        {:ok, w} = open_audit(world)

        {:ok, _} =
          World.append(w, [
            {id, "is", "egress"},
            {id, "host", host, by},
            {id, "path", path || "/"},
            {id, "status", status},
            {id, "bytes", bytes}
          ])

        :ok

      _ ->
        :ok
    end
  end

  defp open_audit(world) do
    alias Blazie.Attribute

    seed =
      Attribute.define("host", answers: "name", cardinality: "many") ++
        Attribute.define("path", answers: "any", cardinality: "many") ++
        Attribute.define("status", answers: "integer", cardinality: "many") ++
        Attribute.define("bytes", answers: "integer", cardinality: "many")

    with {:ok, w} <- World.open(world) do
      if World.tx(w) == 0, do: {:ok, _} = World.append(w, Attribute.seed() ++ seed)
      {:ok, w}
    end
  end

  # ── production defaults ──────────────────────────────────────────────────────

  defp default_resolve(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} ->
        {:ok, ip}

      _ ->
        case :inet.getaddr(String.to_charlist(host), :inet6) do
          {:ok, ip} -> {:ok, ip}
          error -> error
        end
    end
  end

  defp default_transport(:get, url, headers, opts) do
    charlist_headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # autoredirect off: the door decides where a 3xx may go, not :httpc.
    case :httpc.request(:get, {url, charlist_headers}, [timeout: timeout, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, resp_headers, body}} ->
        {:ok, status, downcase_headers(resp_headers), body}

      {:error, reason} ->
        {:error, %{problem: :transport, repair: "the fetch failed: #{inspect(reason)}"}}
    end
  end

  defp downcase_headers(headers) do
    for {k, v} <- headers, do: {String.downcase(to_string(k)), to_string(v)}
  end

  defp default_secret(handle) do
    Blazie.Secret.resolve(handle, :job)
  end
end
