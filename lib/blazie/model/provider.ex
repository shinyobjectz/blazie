defmodule Blazie.Model.Provider do
  @moduledoc """
  What a provider has to be able to do, and nothing more.

  Three callbacks. A provider that cannot embed says so rather than pretending,
  because a refusal naming the limit is worth more than a generic failure at the
  point of use — Anthropic has no embeddings endpoint, and a caller asking for
  one should be told that rather than handed a 404.

  New endpoints are modules, not branches. That is the one structural thing
  worth copying from `req_llm`: twenty-one providers is only tractable when
  adding the twenty-second changes no existing file.
  """

  alias Blazie.Model.Reference

  @type refusal :: %{problem: atom(), repair: String.t()}

  @callback generate(Reference.t(), [map()], keyword()) :: {:ok, String.t()} | {:error, refusal()}
  @callback object(Reference.t(), [map()], keyword(), keyword()) ::
              {:ok, map()} | {:error, refusal()}
  @callback embed(Reference.t(), [String.t()], keyword()) ::
              {:ok, [[float()]]} | {:error, refusal()}

  @doc """
  Ask, offering tools the model may call.

  Answers `{:said, text}` when it is done, or `{:calls, [%{id, name, arguments}]}`
  when it wants something run. Two shapes rather than one because they mean
  different things to the caller: one ends the loop and the other continues it,
  and a caller that had to inspect a map to find out which would eventually get
  it wrong.
  """
  @callback converse(Reference.t(), [map()], [map()], keyword()) ::
              {:ok, {:said, String.t()} | {:calls, [map()]}} | {:error, refusal()}

  @optional_callbacks converse: 4

  @doc "The module for a model."
  @spec for(Reference.t()) :: module()
  def for(%Reference{} = model), do: Reference.module(model)

  @doc """
  A json request, signed by hand.

  `:httpc` and `Jason`, which is what `Blazie.Identity.GitHub` and
  `Backup.Target.S3` already do. An SDK here would drag its own HTTP client, its
  own retry policy, and its own idea of when to raise, into a tree that has six
  dependencies and counts them.
  """
  @spec post(String.t(), [{String.t(), String.t()}], map(), keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def post(url, headers, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    payload = Jason.encode!(body)

    request =
      {String.to_charlist(url),
       Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end), ~c"application/json",
       payload}

    case :httpc.request(:post, request, [{:timeout, timeout}], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, raw}} when status in 200..299 ->
        decode(raw)

      {:ok, {{_, status, _}, _headers, raw}} ->
        {:error,
         %{
           problem: :refused_by_provider,
           repair: "The provider answered #{status}: #{String.slice(to_string(raw), 0, 400)}"
         }}

      {:error, why} ->
        {:error,
         %{
           problem: :unreachable,
           repair: "Nothing answered at #{url}: #{inspect(why)}"
         }}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _why} ->
        {:error,
         %{
           problem: :not_json,
           repair:
             "The provider answered something that is not json: #{String.slice(to_string(raw), 0, 200)}"
         }}
    end
  end

  @doc """
  What a call spent, from whatever shape the provider reported it in.

  Zero when a provider says nothing. That is a real limitation and it is stated
  rather than guessed at: a spend of zero means "not reported", and a budget
  built on guesses would refuse the wrong runs.
  """
  @spec spent(map()) :: %{in: non_neg_integer(), out: non_neg_integer()}
  def spent(%{"usage" => usage}) when is_map(usage) do
    %{
      in: Map.get(usage, "prompt_tokens") || Map.get(usage, "input_tokens") || 0,
      out: Map.get(usage, "completion_tokens") || Map.get(usage, "output_tokens") || 0
    }
  end

  def spent(_answered), do: %{in: 0, out: 0}

  @doc "The refusal a provider gives when it cannot do a thing at all."
  @spec cannot(String.t(), String.t()) :: {:error, refusal()}
  def cannot(what, provider) do
    {:error,
     %{
       problem: :not_offered,
       repair: "#{provider} has no #{what} endpoint. Use a provider that does."
     }}
  end
end
