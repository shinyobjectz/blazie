defmodule Blazie.Rollup do
  @moduledoc """
  Aggregation as a projection a job maintains — the shape that won the spike.

  Two honest designs existed for "impressions by week by platform for a
  year": aggregate in Lua at query time, or maintain projection facts and
  query those. Both were measured against a 50,000-reading corpus
  (150k facts): the Lua walk cost **1,127ms per query, every query**; the
  projection cost 231ms to maintain **once**, re-fires only when the
  readings change (the job's read set covers them — the Hints property),
  and answers in under a millisecond. The loser is written down here so it
  stays lost: query-time aggregation over a fact log is the
  `requiresTenantFilter()` of performance — correct, invisible in a demo,
  and quadratic in everybody's patience at scale.

  A rollup is facts like everything else — `rollup:{group}` entities whose
  totals are recomputed whole per maintenance run. Whole, not incremental,
  deliberately: at 231ms per maintenance the complexity of incremental
  update buys nothing yet, and the number that says when it starts buying
  is in this paragraph waiting to be beaten.
  """

  alias Blazie.{Attribute, Job, Snapshot}

  @doc "The attributes a rollup writes."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("rollup_total", answers: "integer", cardinality: "many") ++
      Attribute.define("rollup_count", answers: "integer", cardinality: "many")
  end

  @doc """
  The maintaining job: sum `measure` grouped by `dimensions`.

      Rollup.job("impressions-rollup", "impressions", ["platform", "week"])

  Declare it `after:` an importer's journal job or with a cadence — or with
  neither, and it still re-fires whenever a reading lands, because it read
  them.
  """
  @spec job(term(), String.t(), [String.t()]) :: Job.t()
  def job(id, measure, dimensions) do
    Job.new(id, fn snapshot ->
      snapshot
      |> Snapshot.find(attribute: measure)
      |> Enum.group_by(fn fact ->
        Enum.map(dimensions, &Snapshot.value(snapshot, fact.id, &1))
      end)
      |> Enum.flat_map(fn {group, facts} ->
        key = "rollup:#{measure}:#{Enum.join(Enum.map(group, &to_string/1), "-")}"

        [
          {key, "rollup_total", facts |> Enum.map(& &1.value) |> Enum.sum()},
          {key, "rollup_count", length(facts)}
        ]
      end)
    end)
  end

  @doc "One group's current total — the interactive read the projection buys."
  @spec total(Snapshot.t(), String.t(), [term()]) :: integer() | nil
  def total(%Snapshot{} = snapshot, measure, group) do
    key = "rollup:#{measure}:#{Enum.join(Enum.map(group, &to_string/1), "-")}"
    Snapshot.value(snapshot, key, "rollup_total")
  end
end
