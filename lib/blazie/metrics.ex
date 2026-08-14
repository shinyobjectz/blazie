defmodule Blazie.Metrics do
  @moduledoc """
  The facts, projected outward — one render, scrapeable, and an alarm that
  watches the one number whose silence means the most.

  The facts-first position holds: vitals, storage readings, spend, and the
  drill's `proven_at` are already facts, and a metrics system kept beside
  them would be a second account that drifts. What was missing is the
  projection — `render/1` walks the observability worlds and answers
  Prometheus exposition text, so anything that scrapes can watch a cluster
  without learning the fact model — and the alarm: `proven_at` stopping is
  THE backup alarm (a backup nobody has restored is a rumour, and the drill
  proves restores on a cadence), and until now nothing watched it.

  An alarm is a fact with the repair attached, like every refusal — and a
  metric too, so whichever surface somebody watches carries it.
  """

  alias Blazie.{Attribute, Job, Snapshot, World}

  @doc "The attributes alarms are written with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("alarm", answers: "any", cardinality: "many")
  end

  @doc """
  Prometheus exposition text from the observability worlds that are open.

  Latest value per gauge, labelled by node or world where the facts say.
  Missing worlds render as nothing rather than zero — an absent reading and
  a zero reading are different claims, and only one of them is true.
  """
  @spec render() :: String.t()
  def render do
    (vitals() ++ storage() ++ backup() ++ alarms())
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp vitals do
    with_world("$vitals", fn snapshot ->
      for field <- ["open_ledgers", "subscriptions", "memory_bytes", "processes"],
          fact = snapshot |> Snapshot.find(attribute: field) |> List.last(),
          fact != nil do
        "blazie_#{field} #{fact.value}"
      end
    end)
  end

  defp storage do
    with_world("$storage", fn snapshot ->
      for field <- ["bytes", "transactions"],
          fact <- latest_per_id(snapshot, field) do
        ~s(blazie_storage_#{field}{world="#{fact.id}"} #{fact.value})
      end
    end)
  end

  defp backup do
    with_world("$backup", fn snapshot ->
      case Snapshot.value(snapshot, "drill", "proven_at") do
        nil -> []
        at -> ["blazie_backup_proven_at_seconds #{at}"]
      end
    end)
  end

  defp alarms do
    with_world("$vitals", fn snapshot ->
      # The LAST fact per alarm name decides: alarms are transitions, and a
      # cleared alarm's history stays readable without ringing forever.
      snapshot
      |> Snapshot.find(id: "alarms", attribute: "alarm")
      |> Enum.map(& &1.value)
      |> Enum.filter(&is_map/1)
      |> Enum.group_by(&Map.get(&1, "name"))
      |> Enum.reject(fn {_name, states} -> Map.get(List.last(states), "cleared", false) end)
      |> Enum.map(fn {name, _states} -> ~s(blazie_alarm{name="#{name}"} 1) end)
    end)
  end

  defp latest_per_id(snapshot, field) do
    snapshot
    |> Snapshot.find(attribute: field)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, facts} -> List.last(facts) end)
  end

  # A world that is not open answers nothing. Absent, not zero.
  defp with_world(name, fun) do
    case Registry.lookup(Blazie.Registry, name) do
      [{_pid, _}] -> fun.(Snapshot.open([World.via(name)]))
      [] -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  The alarm job: rings when `proven_at` stops advancing.

  `stale:` is how old the last proven restore may be before the alarm — a
  day unless told, which is four missed six-hour drills. The alarm fact
  carries the repair, and it clears itself: a drill that proves again writes
  a newer `proven_at`, the job re-fires (it read it), and the alarm stops
  rendering because the condition stopped holding.
  """
  @spec alarm_job(keyword()) :: Job.t()
  def alarm_job(opts \\ []) do
    stale = Keyword.get(opts, :stale, 86_400)
    proven_at = Keyword.get(opts, :proven_at, &default_proven_at/0)
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:second) end)

    Job.new("backup-alarm", fn snapshot ->
      now = clock.()

      ringing =
        case proven_at.() do
          nil ->
            {"backup-never-proven",
             "No restore has ever been proven. A backup nobody has restored is a rumour — " <>
               "check the drill is configured and running."}

          at when now - at > stale ->
            {"backup-stale",
             "The last proven restore is #{now - at}s old (ceiling #{stale}s). The drill " <>
               "has stopped proving — check the target and the drill's failed facts."}

          _fresh ->
            nil
        end

      # Transitions only: ring once, clear once. The job reads another
      # world's proven_at, so its own read set cannot re-fire it — the
      # cadence is what watches, which is the honest shape for a watchdog.
      was =
        snapshot
        |> Snapshot.find(id: "alarms", attribute: "alarm")
        |> List.last()
        |> case do
          nil -> nil
          %{value: %{"cleared" => true}} -> nil
          %{value: %{"name" => name}} -> name
          _ -> nil
        end

      case {ringing, was} do
        {nil, nil} ->
          []

        {nil, name} ->
          [{"alarms", "alarm", %{"name" => name, "cleared" => true}}]

        {{name, _repair}, name} ->
          []

        {{name, repair}, _other} ->
          [{"alarms", "alarm", %{"name" => name, "repair" => repair}}]
      end
    end)
  end

  defp default_proven_at do
    case Registry.lookup(Blazie.Registry, "$backup") do
      [{_pid, _}] -> Snapshot.value(Snapshot.open([World.via("$backup")]), "drill", "proven_at")
      [] -> nil
    end
  end
end
