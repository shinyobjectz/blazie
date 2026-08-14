defmodule Blazie.Refinement do
  @moduledoc """
  Changing a declaration because of what runs actually did (ref).

  The loop closes here. Trajectories are facts, runs are things, and the
  verifier decides what may be adopted — so the last move is to read what kept
  going wrong and change the declaration that let it.

  ## What may be refined, and why the bound is the design

  Only what a thing SAYS about itself: `describe`, `one_of`, `calls_allowed`,
  `requires`. Never a formula's `source` — that belongs to `Formula.Generated`
  and is gated by examples, which is a stronger gate than anything here. Never a
  grant, never anything in a `$` world.

  That bound is not caution, it is the whole safety argument. An agent that
  could refine its own authority would eventually refine it wider, and it would
  do so with a perfectly good reason drawn from a real trajectory — because
  "this run failed because it could not name that world" is a true observation
  with a catastrophic remedy. So the remedy is not available. What is available
  is making its own descriptions better, which is where its failures mostly
  actually live.

  ## A refinement is a fact, which buys both properties that matter

  Adopting is appending, so undoing is appending a later fact rather than
  restoring a backup — the same correction every other mistake here gets.

  And the trigger is written beside the edit, so "did it help" is a query: the
  runs before it and the runs after it are both still there, and neither was
  disturbed by the other. Every continual-learning design promises improvement
  and almost none can answer whether a given change was an improvement, because
  the evidence for the old behaviour was overwritten by the new one.

  ## Nothing here is adopted because a model suggested it

  `propose/3` assembles a brief and returns candidate facts. `adopt/3` refuses
  anything outside the bound. The model is a source of suggestions and the
  refusal is not negotiable — which is the same shape as everywhere else in this
  tree: generated, then checked, and the check is code.
  """

  alias Blazie.{Attribute, Model, Snapshot, World}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @refinable ~w(describe one_of calls_allowed requires)

  @doc "The attributes a refinement is recorded with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("refined", answers: "name", cardinality: "many") ++
      Attribute.define("because", answers: "any") ++
      Attribute.define("refined_at", answers: "integer") ++
      Attribute.define("undone", answers: "integer")
  end

  @doc "What a refinement may touch."
  @spec refinable() :: [String.t()]
  def refinable, do: @refinable

  @doc """
  What keeps going wrong, from the runs themselves.

  Grouped by the reason rather than by the run, because one run failing is an
  incident and the same reason across several is a declaration that is wrong.
  `least:` is how many times before it counts — the same judgement as `enough:`
  when harvesting, and a keyword for the same reason.
  """
  @spec triggers(Snapshot.t(), keyword()) :: [%{reason: String.t(), times: pos_integer()}]
  def triggers(%Snapshot{} = snapshot, opts \\ []) do
    least = Keyword.get(opts, :least, 2)

    snapshot
    |> Snapshot.find(attribute: "failed")
    |> Enum.map(& &1.value)
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_reason, times} -> times >= least end)
    |> Enum.sort_by(fn {_reason, times} -> -times end)
    |> Enum.map(fn {reason, times} -> %{reason: reason, times: times} end)
  end

  @doc """
  A brief for one trigger: what went wrong, and what may be changed about it.

  Assembled rather than authored, the same rule as an agent's ask and a
  generated formula's brief. The bound is IN the brief — a model told it may
  only change a description will propose a better description, where one told
  nothing will propose widening a permission.
  """
  @spec brief(Snapshot.t(), String.t(), String.t()) :: String.t()
  def brief(%Snapshot{} = snapshot, subject, reason) do
    """
    A declaration in this database keeps producing the same failure.

    The thing declared: #{subject}
    What it currently says about itself:
    #{said_about(snapshot, subject)}

    The failure, seen more than once:
    #{reason}

    Propose the SMALLEST change that would stop it. You may change only these:
    #{Enum.join(@refinable, ", ")}.

    You may not change what anything is permitted to do, and you may not write
    a formula's source. If none of the changes available to you would help, say
    so — a refinement that does not address the failure is worse than none,
    because it will be recorded as having been tried.

    Answer with the attribute to set and the value to set it to.
    """
    |> String.trim()
  end

  defp said_about(snapshot, subject) do
    snapshot
    |> Snapshot.find(id: subject)
    |> Enum.filter(&(&1.attribute in @refinable))
    |> Enum.map_join("\n", fn fact -> "  #{fact.attribute} = #{inspect(fact.value)}" end)
    |> case do
      "" -> "  (it says nothing about itself, which may be the problem)"
      said -> said
    end
  end

  @doc """
  Ask a model for the smallest edit, as an attribute and a value.

  Returns what it proposed, unadopted. Deliberately two steps: what a model
  suggests and what a database accepts are different questions, and collapsing
  them is how a suggestion becomes a change nobody checked.
  """
  @spec propose(Snapshot.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{attribute: String.t(), value: term()}} | {:error, refusal()}
  def propose(%Snapshot{} = snapshot, subject, reason, opts) do
    model = Keyword.fetch!(opts, :asks)

    case Model.object(
           model,
           brief(snapshot, subject, reason),
           [
             attribute: [answers: "name", one_of: @refinable, describe: "which one to change"],
             value: [answers: "any", describe: "what to set it to"]
           ],
           opts
         ) do
      {:ok, %{"attribute" => attribute, "value" => value}} ->
        {:ok, %{attribute: attribute, value: value}}

      {:ok, other} ->
        {:error, %{problem: :not_a_refinement, repair: "The model answered #{inspect(other)}."}}

      {:error, refusal} ->
        {:error, refusal}
    end
  end

  @doc """
  Adopt a proposal, recording what prompted it.

  Refuses anything outside the bound, whatever proposed it. The refusal is the
  point: this is the one place in the tree where the thing being changed and the
  thing doing the changing are the same system.
  """
  @spec adopt(World.ref(), String.t(), %{attribute: String.t(), value: term()}, keyword()) ::
          {:ok, pos_integer()} | {:error, refusal()}
  def adopt(world, subject, %{attribute: attribute, value: value}, opts) do
    because = Keyword.fetch!(opts, :because)
    by = Keyword.get(opts, :by, "refinement")
    now = Keyword.get(opts, :now, System.system_time(:second))
    id = "#{subject}/#{attribute}@#{now}"

    with :ok <- within_bounds(attribute),
         :ok <- not_reserved(subject) do
      World.append(world, [
        {subject, attribute, value, by},
        {id, "refined", subject, by},
        {id, "because", because, by},
        {id, "refined_at", now, by}
      ])
    end
  end

  defp within_bounds(attribute) when attribute in @refinable, do: :ok

  defp within_bounds(attribute) do
    {:error,
     %{
       problem: :outside_the_bound,
       repair:
         "A refinement may set #{Enum.join(@refinable, ", ")} and not #{inspect(attribute)}. " <>
           "What a thing says about itself may be refined; what it is permitted to do may not, " <>
           "because an agent that could widen its own authority would eventually do so with a " <>
           "perfectly good reason."
     }}
  end

  defp not_reserved("$" <> _ = subject) do
    {:error,
     %{
       problem: :reserved,
       repair:
         "#{inspect(subject)} belongs to the node itself. Nothing generated may refine it, " <>
           "whatever the evidence."
     }}
  end

  defp not_reserved(_subject), do: :ok

  @doc """
  Undo a refinement, as a later fact.

  Nothing is deleted and the reasoning stays readable: what was tried, why, and
  that it was undone. A refinement that made things worse is evidence too.
  """
  @spec undo(World.ref(), String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def undo(world, id, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    World.append(world, [{id, "undone", now, Keyword.get(opts, :by, "refinement")}])
  end

  @doc """
  Whether a refinement helped: the trigger's rate before it, and after.

  A count of the same failure among runs that began before the refinement and
  runs that began after. Both sets are intact because nothing was overwritten to
  make the second — which is the property that makes this answerable at all.
  """
  @spec outcome(Snapshot.t(), String.t(), String.t()) ::
          %{before: non_neg_integer(), since: non_neg_integer(), at: integer() | nil}
  def outcome(%Snapshot{} = snapshot, id, reason) do
    at = Snapshot.value(snapshot, id, "refined_at")

    failures =
      snapshot
      |> Snapshot.find(attribute: "failed")
      |> Enum.filter(&(&1.value == reason))

    case at do
      nil ->
        %{before: length(failures), since: 0, at: nil}

      when_it_was ->
        {old, new} = Enum.split_with(failures, &began_before?(snapshot, &1.id, when_it_was))
        %{before: length(old), since: length(new), at: when_it_was}
    end
  end

  # Which side of the refinement a failure falls on is decided by when its RUN
  # began, not when the failure was written — a run already in flight when the
  # declaration changed was not tested by the change.
  defp began_before?(snapshot, run, when_it_was) do
    case Snapshot.value(snapshot, run, "began") do
      began when is_integer(began) -> began < when_it_was
      _ -> true
    end
  end

  @doc "Every refinement made to a subject, oldest first."
  @spec of(Snapshot.t(), String.t()) :: [
          %{id: term(), because: term(), at: term(), undone: term()}
        ]
  def of(%Snapshot{} = snapshot, subject) do
    snapshot
    |> Snapshot.find(attribute: "refined", value: subject)
    |> Enum.map(fn fact ->
      %{
        id: fact.id,
        because: Snapshot.value(snapshot, fact.id, "because"),
        at: Snapshot.value(snapshot, fact.id, "refined_at"),
        undone: Snapshot.value(snapshot, fact.id, "undone")
      }
    end)
  end
end
