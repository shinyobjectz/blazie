defmodule Blazie.Job.Generative do
  @moduledoc """
  A job whose answer is produced rather than fetched, and checked before it lands.

  Still a job. Nothing here is a new word — what changes is that the work is
  asked more than once, and an answer only counts when the requirements on its
  attribute hold.

      sample(job, world, snapshot, now, tries: 5)

  ## What this is, next to Mellea and BAML

  Both of those make a single generative call reliable: a typed signature, a
  schema, automatic validation, retry on violation. That is the loop below, and
  it is not the novel part — it is the part worth copying, and the reason this
  file is small.

  What neither can do is what falls out here for free. A BAML function re-run
  gives a new answer with no relationship to the old one; there is nowhere for
  it to go and nothing that knows it changed. Here the answer lands in a world
  as facts, names the job that produced it, records which requirements it
  satisfied, and re-runs when something it READ changes — because a job's read
  set already decides that. So this is not "generation with validation", it is a
  body of generated knowledge that stays correct as its inputs move.

  And because a satisfied requirement is written down as an ordinary fact,
  *"which requirements did this output actually pass, and when"* is a query
  rather than a log somebody remembered to keep.

  ## Rejected samples are not written

  A sample that fails its requirements is discarded, and only the count of
  attempts survives. That is deliberate: an unchecked answer in the world is
  not a correction, it is a lie with a timestamp — and a correction is only
  cheap when the thing being corrected was true when it was written.

  What IS written when every attempt fails is the failure itself, with the
  reasons, because a job that gave up silently is a job nobody can debug.
  """

  alias Blazie.{Attribute, Snapshot, World}

  @tries 3

  @type outcome ::
          {:ok, pos_integer(), %{tries: pos_integer()}}
          | {:unmet, pos_integer(), [map()]}
          | {:failed, pos_integer(), String.t()}

  @doc """
  Ask the job for an answer until one satisfies its attribute's requirements.

  `work` is called with the snapshot and the attempt number, so a caller that
  wants to vary temperature, or prompt differently on a retry, has the one
  number that makes that possible without this module knowing what a model is.
  """
  @spec sample(Blazie.Job.t(), World.ref(), Snapshot.t(), integer(), keyword()) :: outcome()
  def sample(job, world, %Snapshot{} = snapshot, now, opts \\ []) do
    tries = Keyword.get(opts, :tries, @tries)

    attempt(job, world, snapshot, now, 1, tries, [])
  end

  defp attempt(job, world, _snapshot, now, try_number, tries, _last) when try_number > tries do
    # Everything failed. The reasons are written, because a job that gave up
    # without saying why is a job nobody can fix.
    {:ok, tx} =
      World.append(world, [
        {job.id, "failed", "no sample satisfied its requirements in #{tries} tries", job.id},
        {job.id, "tries", tries, job.id},
        {job.id, "ran_at", now, job.id}
      ])

    {:unmet, tx, []}
  end

  defp attempt(job, world, snapshot, now, try_number, tries, _last) do
    produced = produce(job, snapshot, try_number)

    case produced do
      {:error, reason} ->
        {:ok, tx} =
          World.append(world, [
            {job.id, "failed", reason, job.id},
            {job.id, "ran_at", now, job.id}
          ])

        {:failed, tx, reason}

      {:ok, assertions} ->
        case Attribute.unmet(assertions, snapshot) do
          [] ->
            land(job, world, assertions, snapshot, now, try_number)

          unmet ->
            if try_number >= tries do
              {:ok, tx} =
                World.append(
                  world,
                  Enum.map(unmet, &{job.id, "failed", &1.repair, job.id}) ++
                    [{job.id, "tries", try_number, job.id}, {job.id, "ran_at", now, job.id}]
                )

              {:unmet, tx, unmet}
            else
              attempt(job, world, snapshot, now, try_number + 1, tries, unmet)
            end
        end
    end
  end

  # The answer, plus what it was checked against. `satisfied` is what makes
  # "which requirements did this pass" answerable later without a second store.
  defp land(job, world, assertions, snapshot, now, try_number) do
    satisfied =
      assertions
      |> Enum.flat_map(fn assertion ->
        attribute = elem(assertion, 1)

        for requirement <- Attribute.requirements(snapshot, attribute),
            do: {elem(assertion, 0), "satisfied", requirement, job.id}
      end)
      |> Enum.uniq()

    stamped = Enum.map(assertions, &stamp(&1, job.id))

    {:ok, tx} =
      World.append(
        world,
        stamped ++
          satisfied ++ [{job.id, "tries", try_number, job.id}, {job.id, "ran_at", now, job.id}]
      )

    {:ok, tx, %{tries: try_number}}
  end

  defp produce(job, snapshot, try_number) do
    {:ok, apply_work(job, snapshot, try_number)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # A job's work takes a snapshot. One that wants to know which attempt this is
  # takes two arguments, and both shapes are supported so an ordinary job can
  # be sampled without being rewritten.
  defp apply_work(%{work: work}, snapshot, try_number) do
    if is_function(work, 2), do: work.(snapshot, try_number), else: work.(snapshot)
  end

  defp stamp({id, attribute, value}, by), do: {id, attribute, value, by}
  defp stamp({id, attribute, value, _by}, by), do: {id, attribute, value, by}

  @doc "The attributes a sampled job is described with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("tries", answers: "integer", cardinality: "many") ++
      Attribute.define("satisfied", answers: "name", cardinality: "many")
  end
end
