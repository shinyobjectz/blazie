defmodule LazyRiver.Backup.Target.S3 do
  @moduledoc """
  Copies into S3-compatible object storage.

  Signed by hand, the same way `LazyRiver.Keyring.GCP` mints its tokens by
  hand: SigV4 is a hash chain and four HMACs, which is smaller than the
  dependency that would do it and does not drag a vendor's SDK, its HTTP
  client, and its XML parser into a tree that has four dependencies.

  Path-style against a configured endpoint, so this speaks to anything that
  implements the protocol. Which one is a bill, not a decision — the vendor
  never becomes vocabulary.

      target: {Target.S3,
               endpoint: "https://<account>.r2.cloudflarestorage.com",
               bucket: "lazyriver",
               region: "auto",
               access_key_id: ...,
               secret_access_key: ...}

  ## Listing is parsed with a regular expression, on purpose

  The response is XML and there is no XML parser here. Every key this module
  writes is base64url, digits, `/`, `-` and `.`, so none of them can carry a
  character XML would escape — the regex cannot be wrong about keys we wrote.
  It would be wrong about arbitrary keys, which is why `list/2` is only ever
  asked about our own prefixes. A bucket shared with something else is a
  configuration mistake this cannot detect.
  """

  @behaviour LazyRiver.Backup.Target

  @service "s3"
  @unsigned_payload "UNSIGNED-PAYLOAD"

  @impl true
  def put(opts, key, bytes) do
    case request(opts, :put, at(opts, key), [], bytes) do
      {:ok, _status, _body} -> :ok
      {:error, why} -> {:error, why}
    end
  end

  @impl true
  def get(opts, key) do
    case request(opts, :get, at(opts, key), [], "") do
      {:ok, 200, body} -> {:ok, body}
      {:error, %{status: 404}} -> {:error, :missing}
      {:error, why} -> {:error, why}
    end
  end

  @impl true
  def list(opts, prefix) do
    with {:ok, keys} <- list(opts, at(opts, prefix), nil, []) do
      {:ok, Enum.map(keys, &strip(opts, &1))}
    end
  end

  # An optional prefix, so one bucket can hold several deployments without any
  # of them being able to see or overwrite another's segments by accident.
  # Everything above this module works in unprefixed keys and never learns it
  # is sharing.
  defp at(opts, key) do
    case Keyword.get(opts, :prefix) do
      nil -> key
      prefix -> "#{prefix}/#{key}"
    end
  end

  defp strip(opts, key) do
    case Keyword.get(opts, :prefix) do
      nil -> key
      prefix -> String.replace_prefix(key, "#{prefix}/", "")
    end
  end

  defp list(opts, prefix, token, acc) do
    # Only ever set by a test. A thousand segments is not a number a real
    # bucket reaches quickly, so the continuation path would otherwise go
    # years without running — and a paginated list that silently stops at
    # the first page is a restore that silently stops with it.
    query =
      [{"list-type", "2"}, {"prefix", prefix}] ++
        if(token, do: [{"continuation-token", token}], else: []) ++
        case Keyword.get(opts, :page_size) do
          nil -> []
          size -> [{"max-keys", to_string(size)}]
        end

    case request(opts, :get, "", query, "") do
      {:ok, 200, body} ->
        keys = Regex.scan(~r{<Key>([^<]*)</Key>}, body) |> Enum.map(fn [_, key] -> key end)

        case next_token(body) do
          nil -> {:ok, Enum.sort(acc ++ keys)}
          next -> list(opts, prefix, next, acc ++ keys)
        end

      {:error, why} ->
        {:error, why}
    end
  end

  defp next_token(body) do
    with true <- Regex.match?(~r{<IsTruncated>true</IsTruncated>}, body),
         [_, token] <- Regex.run(~r{<NextContinuationToken>([^<]*)</NextContinuationToken>}, body) do
      token
    else
      _ -> nil
    end
  end

  # ── the request, and its signature ─────────────────────────────────────────

  defp request(opts, method, key, query, body) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    bucket = Keyword.fetch!(opts, :bucket)
    region = Keyword.get(opts, :region, "auto")
    %URI{host: host, scheme: scheme, port: port} = URI.parse(endpoint)

    path = "/" <> bucket <> if key == "", do: "", else: "/" <> encode_path(key)
    now = DateTime.utc_now()

    headers =
      sign(opts, method, host, path, query, region, now)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    url =
      String.to_charlist(
        "#{scheme}://#{host}#{port_of(scheme, port)}#{path}#{query_string(query, "?")}"
      )

    http(method, url, headers, body)
  end

  defp http(:get, url, headers, _body) do
    result = :httpc.request(:get, {url, headers}, http_opts(), body_format: :binary)
    interpret(result)
  end

  defp http(:put, url, headers, body) do
    request = {url, headers, ~c"application/octet-stream", body}
    result = :httpc.request(:put, request, http_opts(), body_format: :binary)
    interpret(result)
  end

  defp http_opts, do: [{:timeout, 60_000}, {:connect_timeout, 15_000}]

  defp interpret({:ok, {{_, status, _}, _headers, body}}) when status in 200..299,
    do: {:ok, status, to_string(body)}

  defp interpret({:ok, {{_, status, _}, _headers, body}}),
    do: {:error, %{problem: :target_refused, status: status, body: to_string(body)}}

  defp interpret({:error, why}), do: {:error, %{problem: :target_unreachable, why: why}}

  # SigV4: a canonical request, a string to sign, and a key derived by four
  # HMACs. The payload is declared unsigned so a segment does not have to be
  # hashed as well as written — it travels over TLS and carries its own CRC
  # inside every record.
  defp sign(opts, method, host, path, query, region, now) do
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{date}/#{region}/#{@service}/aws4_request"

    signed_headers = "host;x-amz-content-sha256;x-amz-date"

    canonical =
      [
        method |> Atom.to_string() |> String.upcase(),
        path,
        query_string(query, ""),
        "host:#{host}\nx-amz-content-sha256:#{@unsigned_payload}\nx-amz-date:#{amz_date}\n",
        signed_headers,
        @unsigned_payload
      ]
      |> Enum.join("\n")

    to_sign =
      "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{hex(:crypto.hash(:sha256, canonical))}"

    signature = hex(:crypto.mac(:hmac, :sha256, signing_key(opts, date, region), to_sign))
    id = Keyword.fetch!(opts, :access_key_id)

    [
      {"authorization",
       "AWS4-HMAC-SHA256 Credential=#{id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"},
      {"x-amz-content-sha256", @unsigned_payload},
      {"x-amz-date", amz_date}
    ]
  end

  defp signing_key(opts, date, region) do
    secret = Keyword.fetch!(opts, :secret_access_key)

    ["AWS4" <> secret, date, region, @service, "aws4_request"]
    |> Enum.reduce(fn step, key -> :crypto.mac(:hmac, :sha256, key, step) end)
  end

  # ── the small print of canonicalisation ────────────────────────────────────

  defp query_string([], _prefix), do: ""

  defp query_string(query, prefix) do
    encoded =
      query
      |> Enum.map(fn {k, v} -> {encode(k), encode(v)} end)
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)

    prefix <> encoded
  end

  # A key's slashes are path separators and must survive; everything else is
  # escaped the way SigV4 wants, which is not the way URI.encode does it.
  defp encode_path(key), do: key |> String.split("/") |> Enum.map_join("/", &encode/1)

  defp encode(value) do
    URI.encode(value, fn
      c when c in ?A..?Z or c in ?a..?z or c in ?0..?9 -> true
      c when c in [?-, ?_, ?., ?~] -> true
      _ -> false
    end)
  end

  defp port_of("https", 443), do: ""
  defp port_of("http", 80), do: ""
  defp port_of(_scheme, nil), do: ""
  defp port_of(_scheme, port), do: ":#{port}"

  defp hex(binary), do: Base.encode16(binary, case: :lower)
end
