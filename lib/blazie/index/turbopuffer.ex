defmodule Blazie.Index.Turbopuffer do
  @moduledoc """
  One vendor's index, as one file this shape.

  The vendor appears here and in configuration and nowhere else — no word,
  no attribute, no space carries its name, so deleting this file is how a
  vendor leaves. Options: `endpoint:`, `key:`, and `prefix:` (namespaces are
  global per account the way cluster names are global per zone, and a prefix
  is how two deployments share an account without sharing an index).

  The wire is `:httpc` and `Jason`, hand-rolled like every other vendor
  boundary in this tree. The API shape this speaks — upsert rows at
  `POST /v1/namespaces/{ns}`, query at `POST /v1/namespaces/{ns}/query`,
  cosine distance answered as `dist` — is pinned by the wire test, which
  runs this module against a server speaking exactly that shape. When the
  vendor moves the API, the live-tagged test is the tripwire and this file
  is the whole repair.
  """

  @behaviour Blazie.Index

  @impl true
  def upsert(opts, space, rows) do
    body = %{
      "upserts" =>
        Enum.map(rows, fn {id, vector, meta} ->
          %{"id" => to_string(id), "vector" => vector, "attributes" => meta}
        end)
    }

    case post(opts, "/v1/namespaces/#{namespace(opts, space)}", body) do
      {:ok, _answer} -> :ok
      {:error, refusal} -> {:error, refusal}
    end
  end

  @impl true
  def search(opts, space, vector, k, filter) do
    filters =
      case Map.to_list(filter) do
        [] -> nil
        pairs -> Map.new(pairs, fn {key, value} -> {key, [["Eq", value]]} end)
      end

    body =
      %{"vector" => vector, "top_k" => k, "distance_metric" => "cosine_distance"}
      |> then(fn body -> if filters, do: Map.put(body, "filters", filters), else: body end)

    case post(opts, "/v1/namespaces/#{namespace(opts, space)}/query", body) do
      {:ok, %{"results" => results}} ->
        # Cosine DISTANCE from the vendor; the seam speaks similarity, so the
        # translation lives here where the vendor's dialect does.
        {:ok, Enum.map(results, fn %{"id" => id, "dist" => dist} -> {id, 1.0 - dist} end)}

      {:ok, other} ->
        {:error,
         %{
           problem: :not_an_index,
           repair: "The index answered #{inspect(other)} to a query, which this shape does not."
         }}

      {:error, refusal} ->
        {:error, refusal}
    end
  end

  @impl true
  def drop(opts, space) do
    request(opts, :delete, "/v1/namespaces/#{namespace(opts, space)}", nil)
    :ok
  end

  defp namespace(opts, space), do: "#{Keyword.get(opts, :prefix, "")}#{space}"

  defp post(opts, path, body), do: request(opts, :post, path, body)

  defp request(opts, method, path, body) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    key = Keyword.get(opts, :key, "")

    headers = [
      {~c"authorization", to_charlist("Bearer " <> key)},
      {~c"accept", ~c"application/json"}
    ]

    request =
      case body do
        nil ->
          {to_charlist(endpoint <> path), headers}

        body ->
          {to_charlist(endpoint <> path), headers, ~c"application/json", Jason.encode!(body)}
      end

    case :httpc.request(method, request, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, answer}} when status in 200..299 ->
        {:ok, Jason.decode!(answer)}

      {:ok, {{_http, status, _reason}, _headers, answer}} ->
        {:error,
         %{
           problem: :index_refused,
           repair: "The index answered #{status}: #{String.slice(answer, 0, 300)}"
         }}

      {:error, why} ->
        {:error,
         %{problem: :unreachable, repair: "Nothing answered at #{endpoint}: #{inspect(why)}"}}
    end
  end
end
