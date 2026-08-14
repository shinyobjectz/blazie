defmodule BlazieClient do
  @moduledoc """
  A blazie cluster, from the outside, in Elixir.

  Thin on purpose: the cluster's surface is three routes — run Lua against a
  world, claim a world, ask who you are — and this speaks exactly those.
  Anything cleverer belongs on the cluster, where it can be checked; a fat
  client is a second implementation of the rules that drifts from the first.

  ## Names, and what may be cached

  A `run` pinned to a `name:` answers the same forever, **or `:erased`** —
  erasure is the one event that changes what an old name answers. So the
  client caches pinned runs on `{name, source}` when given a cache, and
  `flush/1` exists because flushing outside caches after an erasure is the
  deployment's job: the cluster cannot reach a copy it never knew was taken.
  An unpinned run reads *now* and is never cached — caching a moving answer
  would be inventing a name for a moment nobody recorded.

  ## Refusals

  Every refusal is `{:error, %{problem: atom, repair: binary}}` — the same
  shape the cluster answers with, passed through rather than translated,
  because the repair is written for whoever is going to act on it and this
  client is not that.

      client = BlazieClient.new("https://demo.blazie.dev", token)
      {:ok, %{"value" => v, "name" => name}} = BlazieClient.run(client, "return 1 + 1", world: "main")
      {:ok, cached} = BlazieClient.run(client, source, world: "main", name: name, cache: cache)
  """

  @enforce_keys [:address, :token]
  defstruct [:address, :token, timeout: 30_000]

  @type t :: %__MODULE__{address: String.t(), token: String.t(), timeout: pos_integer()}
  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "A client for the cluster at `address`, presenting `token`."
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(address, token, opts \\ []) do
    %__MODULE__{
      address: String.trim_trailing(address, "/"),
      token: token,
      timeout: Keyword.get(opts, :timeout, 30_000)
    }
  end

  @doc """
  Run Lua against a world, and get back the value, the name, and what landed.

  Options: `world:` (required), `also:` extra read-only worlds, `name:` a
  snapshot name to pin (the same source at the same name is the same answer),
  `as: "job"` when the chunk must reach the network, and `cache:` a cache
  from `cache/0` — used only for pinned runs, because only they may be.
  """
  @spec run(t(), String.t(), keyword()) :: {:ok, map()} | {:error, refusal()}
  def run(%__MODULE__{} = client, source, opts) when is_binary(source) do
    world = Keyword.fetch!(opts, :world)
    name = Keyword.get(opts, :name)
    cache = Keyword.get(opts, :cache)

    body =
      %{"world" => world, "source" => source}
      |> put_if("also", Keyword.get(opts, :also))
      |> put_if("name", name)
      |> put_if("as", Keyword.get(opts, :as))

    case cached(cache, name, source) do
      {:ok, answer} ->
        {:ok, answer}

      :miss ->
        with {:ok, answer} <- post(client, "/run", body) do
          keep(cache, name, source, answer)
          {:ok, answer}
        end
    end
  end

  @doc "Claim a world name and hold it. First-come; a taken name is a refusal."
  @spec claim(t(), String.t()) :: {:ok, map()} | {:error, refusal()}
  def claim(%__MODULE__{} = client, world) when is_binary(world),
    do: post(client, "/worlds", %{"world" => world})

  @doc "Who this token is, and which worlds it may name."
  @spec me(t()) :: {:ok, map()} | {:error, refusal()}
  def me(%__MODULE__{} = client), do: get(client, "/me")

  # ── the cache ──────────────────────────────────────────────────────────────

  @doc """
  A cache for pinned answers. Hand it to `run/3`'s `cache:`.

  An ETS table owned by a process the caller supervises — the client itself
  owns nothing, so there is no process to forget in a supervision tree and
  no state that survives longer than somebody decided it should.
  """
  @spec cache() :: {:ok, pid()}
  def cache do
    Agent.start_link(fn ->
      :ets.new(__MODULE__.Cache, [:set, :public, read_concurrency: true])
    end)
  end

  @doc """
  Drop everything a cache holds.

  The one honest reason to call this is an erasure: an answer at a name is
  the same answer forever or `:erased`, and after an erasure the copies out
  here are the deployment's to flush — the cluster cannot reach them.
  """
  @spec flush({:ok, pid()} | pid()) :: :ok
  def flush({:ok, pid}), do: flush(pid)

  def flush(pid) when is_pid(pid) do
    Agent.get(pid, fn table -> :ets.delete_all_objects(table) end)
    :ok
  end

  defp cached(nil, _name, _source), do: :miss
  defp cached(_cache, nil, _source), do: :miss
  defp cached({:ok, pid}, name, source), do: cached(pid, name, source)

  defp cached(pid, name, source) when is_pid(pid) do
    table = Agent.get(pid, & &1)

    case :ets.lookup(table, {name, source}) do
      [{_key, answer}] -> {:ok, answer}
      [] -> :miss
    end
  end

  defp keep(nil, _name, _source, _answer), do: :ok
  defp keep(_cache, nil, _source, _answer), do: :ok
  defp keep({:ok, pid}, name, source, answer), do: keep(pid, name, source, answer)

  defp keep(pid, name, source, answer) when is_pid(pid) do
    table = Agent.get(pid, & &1)
    :ets.insert(table, {{name, source}, answer})
    :ok
  end

  # ── the wire ───────────────────────────────────────────────────────────────

  defp post(client, path, body) do
    request(
      client,
      :post,
      {to_charlist(client.address <> path), headers(client), ~c"application/json",
       Jason.encode!(body)}
    )
  end

  defp get(client, path) do
    request(client, :get, {to_charlist(client.address <> path), headers(client)})
  end

  defp headers(client) do
    [
      {~c"authorization", to_charlist("Bearer " <> client.token)},
      {~c"accept", ~c"application/json"}
    ]
  end

  defp request(client, method, request) do
    options = [timeout: client.timeout, connect_timeout: min(client.timeout, 10_000)]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, body}} ->
        answered(status, body)

      {:error, why} ->
        {:error,
         %{
           problem: :unreachable,
           repair:
             "Nothing answered at #{client.address}: #{inspect(why)}. If the cluster was " <>
               "opened moments ago it may still be installing."
         }}
    end
  end

  # The cluster's refusals arrive as {"error": {"problem", "repair"}} and pass
  # through with the problem as an atom the CALLER matches on — existing atoms
  # only, because a hostile cluster must not grow this VM's atom table.
  defp answered(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"problem" => problem, "repair" => repair}}} ->
        {:error, %{problem: existing_atom(problem), repair: repair}}

      {:ok, decoded} when status in 200..299 ->
        {:ok, decoded}

      _other ->
        {:error,
         %{
           problem: :not_a_cluster,
           repair:
             "#{status} with a body that is not a blazie answer. Check the address points " <>
               "at a cluster."
         }}
    end
  end

  defp existing_atom(problem) do
    String.to_existing_atom(problem)
  rescue
    ArgumentError -> :refused
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
