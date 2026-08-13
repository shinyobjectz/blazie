defmodule Blazie.Agent do
  @moduledoc """
  An agent, which is a job with memory — declared rather than written.

  You do not write an agent here. You declare that a field is *produced*, and
  what it must satisfy, and the agent is what that implies:

      severity.answers  = 'name'          -- the shape, which is the schema
      severity.produces = 'ticket'        -- what it is a field of
      severity.watches  = { 'body' }      -- what it attends to
      severity.asks     = 'openai:gpt-4o-mini'
      severity.requires = known_severity  -- an ordinary formula

  From that: any ticket with a `body` and no `severity` is work to do; when
  `body` changes the severity is stale; what the model is asked for is the
  declaration itself; and the answer only lands if the requirement holds.

  ## No prompt, and specifically why

  There is nowhere to put one. The shape comes from `answers`, the context from
  `watches`, the constraint from `requires`, and the instruction — the one thing
  a person genuinely has to say — is the field's own name and description. So a
  prompt cannot drift from the schema, because there is one sentence rather than
  two that have to agree.

  ## What blazie contributes that a prompt library cannot

  The answer lands in a world. It names the agent that produced it, records
  which requirements it passed, and goes stale when what it watched moves —
  because a job's read set already decides that. So "what did this agent believe
  on Tuesday, and what changed its mind" is a query rather than a log.

  ## The seed read set

  A job's read set is normally *discovered* by running it, which is fine for the
  second run and useless for the first — an agent that has never run has watched
  nothing, so nothing can wake it. `watches` is the seed: declared up front,
  refined by observation afterwards. It is the one thing an agent must say that
  an ordinary job does not.
  """

  alias Blazie.{Attribute, Snapshot}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The attributes an agent is declared with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("produces", answers: "name") ++
      Attribute.define("watches", answers: "name", cardinality: "many") ++
      Attribute.define("asks", answers: "name") ++
      Attribute.define("describe", answers: "any")
  end

  @doc """
  Declare a generated field.

      declare("severity",
        produces: "ticket",
        watches: ["body"],
        asks: "openai:gpt-4o-mini",
        answers: "name",
        describe: "low, medium or high")
  """
  @spec declare(String.t(), keyword()) :: [tuple()]
  def declare(field, opts) do
    Attribute.define(field, Keyword.take(opts, [:answers, :cardinality])) ++
      [
        {field, "produces", Keyword.fetch!(opts, :produces)},
        {field, "asks", Keyword.fetch!(opts, :asks)}
      ] ++
      for(watched <- Keyword.get(opts, :watches, []), do: {field, "watches", watched}) ++
      case Keyword.get(opts, :describe) do
        nil -> []
        words -> [{field, "describe", words}]
      end
  end

  @doc """
  Which entities are missing this field, or holding one that has gone stale.

  The work list, derived rather than kept. An entity is due when it has
  everything the field watches and either has never been given one, or was given
  one before the last change to something watched.

  Nothing is enqueued and nothing is marked — a queue would be a second account
  of what needs doing, and the first account is already here.
  """
  @spec due(Snapshot.t(), String.t()) :: [term()]
  def due(%Snapshot{} = snapshot, field) do
    watched = watches(snapshot, field)

    case watched do
      [] ->
        []

      _ ->
        snapshot
        |> candidates(watched)
        |> Enum.filter(&stale?(snapshot, &1, field, watched))
        |> Enum.sort_by(&inspect/1)
    end
  end

  @doc "What a field watches, as declared."
  @spec watches(Snapshot.t(), String.t()) :: [String.t()]
  def watches(%Snapshot{} = snapshot, field) do
    snapshot
    |> Snapshot.find(id: field, attribute: "watches")
    |> Enum.map(& &1.value)
    |> Enum.uniq()
  end

  @doc """
  What the model is asked, for one entity.

  Assembled, never authored: the field's own description, the values it watches,
  and — deliberately — nothing else. What an agent may see is decided here,
  where it can be read, rather than by what it managed to reach.
  """
  @spec asking(Snapshot.t(), String.t(), term()) :: String.t()
  def asking(%Snapshot{} = snapshot, field, id) do
    described = Snapshot.value(snapshot, field, "describe")

    context =
      snapshot
      |> watches(field)
      |> Enum.map(fn watched -> {watched, Snapshot.value(snapshot, id, watched)} end)
      |> Enum.reject(fn {_watched, value} -> is_nil(value) end)
      |> Enum.map_join("\n", fn {watched, value} -> "#{watched}: #{show(value)}" end)

    # A requirement marked `shown` goes into the ask. The same words are what it
    # is checked against afterwards, so the instruction cannot drift from the
    # gate — which is the whole reason they are one fact rather than two.
    must =
      case Attribute.instructions(snapshot, field) do
        [] -> ""
        rules -> "\nIt must satisfy:\n" <> Enum.map_join(rules, "\n", &("  - " <> &1))
      end

    """
    Give the #{field} for this #{Snapshot.value(snapshot, field, "produces") || "entity"}.
    #{if described, do: "#{field} is #{described}.", else: ""}#{must}

    #{context}
    """
    |> String.trim()
  end

  @doc """
  The work function for a declared field, as an ordinary job.

  Returns something `Blazie.Job.new/2` takes, so an agent is scheduled, retried,
  sampled and recorded by the machinery that already exists. Nothing here is a
  second runtime.
  """
  @spec work(Snapshot.t(), String.t(), keyword()) :: (Snapshot.t(), pos_integer() -> [tuple()])
  def work(%Snapshot{} = declared, field, opts \\ []) do
    fn snapshot, _attempt ->
      ask_for_each(declared, snapshot, field, opts)
    end
  end

  defp ask_for_each(declared, snapshot, field, opts) do
    model = Snapshot.value(declared, field, "asks")
    shape = [answers: Snapshot.value(declared, field, "answers") || "any"]

    for id <- due(snapshot, field) do
      case Blazie.Model.object(model, asking(snapshot, field, id), shape, opts) do
        {:ok, %{"value" => value}} -> {id, field, value}
        {:ok, answered} -> raise "#{field} answered #{inspect(answered)}, which has no value"
        {:error, refusal} -> raise refusal.repair
      end
    end
  end

  # ── deciding what needs doing ──────────────────────────────────────────────

  defp candidates(snapshot, watched) do
    watched
    |> Enum.flat_map(fn attribute -> snapshot |> Snapshot.find(attribute: attribute) end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  # Stale when it was never given one, or when something it watches changed
  # after the last one was written. The transaction is the clock — there is no
  # timestamp to compare and no bookkeeping to keep in step.
  defp stale?(snapshot, id, field, watched) do
    case latest_tx(snapshot, id, field) do
      nil ->
        true

      given_at ->
        Enum.any?(watched, fn attribute ->
          case latest_tx(snapshot, id, attribute) do
            nil -> false
            changed_at -> changed_at > given_at
          end
        end)
    end
  end

  defp latest_tx(snapshot, id, attribute) do
    snapshot
    |> Snapshot.find(id: id, attribute: attribute)
    |> Enum.map(& &1.tx)
    |> Enum.max(fn -> nil end)
  end

  defp show(value) when is_binary(value), do: value
  defp show(value), do: inspect(value)
end
