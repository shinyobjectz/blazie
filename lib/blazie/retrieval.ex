defmodule Blazie.Retrieval do
  @moduledoc """
  Research, bought — capabilities that name what they do, never who does it.

  Blazie does not build search. The shape is `Nexus.Research`'s, which is
  the one socialite measured into existence: every source answers in ONE
  citable document shape so a citation means the same thing wherever it
  came from; results interleave round-robin because a cross-source score
  would be an invented number comparing incomparable rankings; and the
  vendor appears only in a provider module and its configuration — an agent
  composes research without learning a vendor exists.

      config :blazie, :retrieval, [{SomeProvider, opts}, {OtherProvider, opts}]

  `Blazie.Directive.Research` is the agent's door to this: a tool answers
  `{"do" => "research", "query" => ...}` and the runtime asks every
  configured provider, so what an agent may search is the deployment's
  decision and widening it is an edit somebody makes deliberately.
  """

  @type refusal :: %{problem: atom(), repair: String.t()}
  @typedoc "The one citable shape. `ref` is what a citation names."
  @type doc :: %{String.t() => String.t()}

  @doc "Ask one provider. Every provider answers the same document shape."
  @callback search(opts :: keyword(), query :: String.t(), k :: pos_integer()) ::
              {:ok, [doc()]} | {:error, refusal()}

  @doc """
  Ask every provider, interleaved round-robin.

  A provider that fails is skipped and its failure carried in the answer —
  research that silently lost a source reads as thorough when it was not.
  """
  @spec ask([{module(), keyword()}], String.t(), pos_integer()) ::
          %{documents: [doc()], failed: [refusal()]}
  def ask(providers, query, k) do
    {answers, failures} =
      providers
      |> Enum.map(fn {module, opts} -> module.search(opts, query, k) end)
      |> Enum.split_with(&match?({:ok, _docs}, &1))

    documents =
      answers
      |> Enum.map(fn {:ok, docs} -> docs end)
      |> interleave()
      |> Enum.take(k)

    %{documents: documents, failed: Enum.map(failures, fn {:error, refusal} -> refusal end)}
  end

  # One from each in turn, no invented cross-source score.
  defp interleave(lists) do
    lists
    |> Enum.filter(&(&1 != []))
    |> case do
      [] -> []
      lists -> Enum.map(lists, &hd/1) ++ interleave(Enum.map(lists, &tl/1))
    end
  end
end

defmodule Blazie.Directive.Research do
  @moduledoc """
  The agent's door to retrieval: a directive, so an agent's reach is the
  registry and the deployment's configured providers — never a vendor it
  learned about from a prompt.
  """

  @spec perform(Blazie.Directive.doing(), map()) :: {:ok, map()} | {:error, map()}
  def perform(_doing, %{"query" => query} = asked) do
    case Application.get_env(:blazie, :retrieval, []) do
      [] ->
        {:error,
         %{
           problem: :nothing_to_search,
           repair:
             "No retrieval providers are configured. Research reaches what the deployment " <>
               "granted (`config :blazie, :retrieval, [...]`) — absent rather than forbidden."
         }}

      providers ->
        k = Map.get(asked, "k", 6)
        answer = Blazie.Retrieval.ask(providers, query, k)

        {:ok,
         %{
           "documents" => answer.documents,
           "sources_failed" => length(answer.failed)
         }}
    end
  end

  def perform(_doing, _asked),
    do: {:error, %{problem: :incomplete, repair: "Research needs `query`."}}
end
