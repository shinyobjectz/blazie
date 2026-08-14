defmodule Blazie.Judge do
  @moduledoc """
  Laws with names and versions, verdicts that never raise, and citations
  found in the text rather than trusted from a model.

  The contract exists because a run once answered a research brief from
  training memory and still settled done. The pieces are socialite's
  `contract.py` and `judge.py`, mapped onto what blazie already has: a LAW
  is an attribute requirement — the same `requires` machinery every sampled
  job clears — plus a name, a version, and `is: law` as facts, so "which
  laws, which versions, since when" is a query. The verdict runner's whole
  job is turning failure into data with a name, so it catches everything:
  a law that crashes is a verdict that says the law crashed, never a raise
  that takes the run with it.

  ## Citations are offsets found in the text

  A model asked "which passages support this" answers with quotes, and an
  invented quote looks exactly like a receipt. So the model's quote is only
  ever a CANDIDATE: the offset comes from `:binary.match/2` against the
  actual source, and a quote the source does not contain is `:invented` —
  recorded as such, because a judge that silently dropped fabrications
  would be measuring only the honest half.
  """

  alias Blazie.{Attribute, Model, Snapshot}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The attributes a law describes itself with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.requires_seed() ++
      Attribute.define("version", answers: "integer") ++
      Attribute.define("verdict", answers: "any", cardinality: "many")
  end

  @doc """
  The facts declaring one law: a named, versioned requirement on an attribute.

      Judge.law("cites_something", version: 1, on: "dossier",
        source: "return #value > 0")
  """
  @spec law(String.t(), keyword()) :: [tuple()]
  def law(name, opts) do
    on = Keyword.fetch!(opts, :on)
    version = Keyword.fetch!(opts, :version)

    [
      {on, "requires", name},
      {name, "is", "law"},
      {name, "version", version},
      {name, "source", Keyword.fetch!(opts, :source)}
    ]
  end

  @doc """
  Every law on an attribute, judged against a value — as verdict facts,
  whatever happens.

  One verdict fact per law, naming the law and its version, saying whether
  it held and why not. A law that cannot be judged — its source crashes,
  its judge is unreachable — is a verdict that says so with `held: false`,
  because "unjudgeable" must park an answer exactly as "failed" does: the
  one thing a verdict may never be is absent.
  """
  @spec verdict(Snapshot.t(), {term(), String.t(), term()}) :: [tuple()]
  def verdict(%Snapshot{} = snapshot, {id, attribute, _value} = assertion) do
    unmet =
      try do
        Attribute.unmet([assertion], snapshot)
      rescue
        error -> [%{requirement: "the-runner", repair: Exception.message(error)}]
      catch
        kind, reason -> [%{requirement: "the-runner", repair: "#{kind}: #{inspect(reason)}"}]
      end

    failed = Map.new(unmet, fn failure -> {failure.requirement, failure.repair} end)

    for law <- laws(snapshot, attribute) do
      version = Snapshot.value(snapshot, law, "version") || 0

      value =
        case Map.fetch(failed, law) do
          :error -> %{"law" => law, "version" => version, "held" => true}
          {:ok, why} -> %{"law" => law, "version" => version, "held" => false, "reason" => why}
        end

      {id, "verdict", value}
    end ++ runner_failures(id, failed)
  end

  defp runner_failures(id, failed) do
    case Map.fetch(failed, "the-runner") do
      :error ->
        []

      {:ok, why} ->
        [
          {id, "verdict",
           %{"law" => "the-runner", "version" => 0, "held" => false, "reason" => why}}
        ]
    end
  end

  defp laws(snapshot, attribute) do
    snapshot
    |> Snapshot.find(id: attribute, attribute: "requires")
    |> Enum.map(& &1.value)
    |> Enum.filter(&(Snapshot.value(snapshot, &1, "is") == "law"))
  end

  @doc """
  Which of a model's claimed quotes the sources actually contain.

  Asks the model which passages support the answer, then throws the model's
  word away and looks: every quote is matched byte-for-byte against its
  named source, and the offset in the answer is where the SOURCE said it,
  not where the model did. Answers `supported` (with offsets) and
  `invented` (recorded, never dropped). Never raises; a judge that cannot
  judge answers that.
  """
  @spec grounded(String.t(), %{String.t() => String.t()}, keyword()) ::
          {:ok, %{supported: [map()], invented: [map()]}} | {:error, refusal()}
  def grounded(answer, sources, opts) do
    model = Keyword.fetch!(opts, :asks)

    prompt = """
    An answer and its sources follow. List the exact quotes from the sources
    that support the answer — verbatim, character for character, with the
    source's name. Do not paraphrase: a quote that is not exactly in a
    source is worthless.

    ANSWER:
    #{answer}

    #{Enum.map_join(sources, "\n", fn {name, text} -> "SOURCE #{name}:\n#{text}\n" end)}
    """

    case Model.object(
           model,
           prompt,
           [quotes: [answers: "any", describe: "a list of {source, quote} objects"]],
           opts
         ) do
      {:ok, %{"quotes" => quotes}} when is_list(quotes) ->
        {:ok, placed(quotes, sources)}

      {:ok, other} ->
        {:ok, placed(List.wrap(other["quotes"]), sources)}

      {:error, refusal} ->
        {:error, refusal}
    end
  rescue
    error ->
      {:error, %{problem: :judge_failed, repair: Exception.message(error)}}
  end

  defp placed(quotes, sources) do
    {supported, invented} =
      quotes
      |> Enum.filter(&is_map/1)
      |> Enum.split_with(fn quote ->
        text = Map.get(sources, Map.get(quote, "source"), "")
        quoted = Map.get(quote, "quote", "")
        quoted != "" and :binary.match(text, quoted) != :nomatch
      end)

    %{
      supported:
        Enum.map(supported, fn quote ->
          source = Map.get(quote, "source")
          {at, length} = :binary.match(Map.get(sources, source), Map.get(quote, "quote"))

          %{
            "source" => source,
            "quote" => Map.get(quote, "quote"),
            "at" => at,
            "length" => length
          }
        end),
      invented: invented
    }
  end
end
