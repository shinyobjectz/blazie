defmodule Blazie.Embedding do
  @moduledoc """
  Text into a symbol, which is a job and could never have been a formula.

  `Blazie.Symbol`'s prose says a symbol is "produced by a formula". It cannot
  be: an embedding is a network call, and a formula has no clock and no network
  by construction. What `Symbol.check/1` actually enforces is provenance — that
  something ran and named itself — and a job satisfies that exactly. So the rule
  held all along and the wording was loose.

  It matters more than a doc fix. A formula's answer is cached under a snapshot
  name forever, so an embedding produced by one would be a wrong answer with no
  expiry the moment a provider changed a model behind the same name. As a job,
  the answer happened once, is written down, and names the job — which is the
  honest account of what an embedding is.

  ## A space is not optional

  Two vectors from different models are not comparable, and comparing them
  anyway returns plausible nonsense. So the space is declared on the attribute
  and travels with every symbol, and this refuses to write one without it.
  """

  alias Blazie.{Attribute, Job, Snapshot, Symbol}

  @doc "The attributes an embedding job is declared with."
  @spec seed() :: [tuple()]
  def seed do
    Symbol.seed() ++
      Attribute.define("embeds", answers: "name") ++
      Attribute.define("into", answers: "name")
  end

  @doc """
  Declare that one field is the embedding of another.

      declare("embedding", embeds: "body", into: "text-3-small",
              asks: "openai:text-embedding-3-small")
  """
  @spec declare(String.t(), keyword()) :: [tuple()]
  def declare(field, opts) do
    Attribute.define(field, answers: "symbol", space: Keyword.fetch!(opts, :into)) ++
      [
        {field, "embeds", Keyword.fetch!(opts, :embeds)},
        {field, "into", Keyword.fetch!(opts, :into)},
        {field, "asks", Keyword.fetch!(opts, :asks)}
      ]
  end

  @doc """
  The work function, as an ordinary job.

  Batched in one request per run, because an embeddings endpoint takes a list
  and a request per entity is the same answer at fifty times the latency.
  """
  @spec work(Snapshot.t(), String.t(), keyword()) :: (Snapshot.t() -> [tuple()])
  def work(%Snapshot{} = declared, field, opts \\ []) do
    fn snapshot ->
      model = Snapshot.value(declared, field, "asks")
      source = Snapshot.value(declared, field, "embeds")
      space = Snapshot.value(declared, field, "into")

      unless model && source && space do
        raise "#{field} must declare `embeds`, `into` and `asks` before it can run"
      end

      case pending(snapshot, field, source) do
        [] ->
          []

        pending ->
          texts = Enum.map(pending, fn {_id, text} -> text end)

          case Blazie.Model.embed(model, texts, opts) do
            {:ok, vectors} when length(vectors) == length(pending) ->
              pending
              |> Enum.zip(vectors)
              |> Enum.map(fn {{id, _text}, values} ->
                {id, field, Symbol.new(space, values)}
              end)

            {:ok, vectors} ->
              raise "asked for #{length(pending)} embeddings and got #{length(vectors)}"

            {:error, refusal} ->
              raise refusal.repair
          end
      end
    end
  end

  @doc "Everything with the source field whose embedding is missing or stale."
  @spec pending(Snapshot.t(), String.t(), String.t()) :: [{term(), String.t()}]
  def pending(%Snapshot{} = snapshot, field, source) do
    snapshot
    |> Snapshot.find(attribute: source)
    |> Enum.filter(&is_binary(&1.value))
    |> Enum.group_by(& &1.id)
    |> Enum.flat_map(fn {id, facts} ->
      written = Enum.max_by(facts, & &1.tx)

      case latest_tx(snapshot, id, field) do
        nil -> [{id, written.value}]
        embedded_at when embedded_at < written.tx -> [{id, written.value}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {id, _text} -> inspect(id) end)
  end

  @doc "A job that keeps one field's embeddings current."
  @spec job(Snapshot.t(), String.t(), keyword()) :: Job.t()
  def job(%Snapshot{} = declared, field, opts \\ []),
    do: Job.new(field, work(declared, field, opts))

  defp latest_tx(snapshot, id, attribute) do
    snapshot
    |> Snapshot.find(id: id, attribute: attribute)
    |> Enum.map(& &1.tx)
    |> Enum.max(fn -> nil end)
  end
end
