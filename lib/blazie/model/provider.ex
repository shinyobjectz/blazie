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
              {:ok, {:said, String.t()} | {:calls, [map()]}, usage()} | {:error, refusal()}

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
    # The default is a per-provider decision, made from measurements rather
    # than one number for everybody: instruct models answer judgment-with-
    # schema tasks in ~2.4s while reasoning models think for minutes (378s
    # was measured before a timeout ended it), and a Workers AI model took
    # over a minute on a single proposal. A caller's explicit `timeout:`
    # always wins; a provider that knows its models are slow says so once,
    # in `default_timeout:` at ITS call site, instead of every caller
    # rediscovering the measurement.
    timeout =
      Keyword.get(opts, :timeout) || Keyword.get(opts, :default_timeout) || 60_000

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

      {:error, :timeout} ->
        {:error,
         %{
           problem: :timed_out,
           repair:
             "#{url} did not answer within #{timeout}ms. Reasoning models spend tokens thinking " <>
               "before they write any, and one asked something hard exceeds this regularly — " <>
               "measured on a Workers AI model that took longer than a minute on a single " <>
               "proposal. Pass `timeout:` if the work is honestly that slow; a cap raised to hide " <>
               "a hung provider only makes the wait longer."
         }}

      {:error, why} ->
        {:error,
         %{
           problem: :unreachable,
           repair:
             "Nothing answered at #{url}: #{inspect(why)}. That is the network or the address " <>
               "rather than the model — check the base url the provider was given."
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
  @typedoc "What a turn cost, as the provider reported it. Zero means not reported."
  @type usage :: %{in: non_neg_integer(), out: non_neg_integer()}

  @spec spent(map()) :: usage()
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
