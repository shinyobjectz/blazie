defmodule Blazie.Model.AgentEndToEndTest do
  @moduledoc """
  A declared agent, run by the machinery that already existed.

  No provider is reached — `asks` points at a stub, because what is worth
  proving is not that HTTP works. It is that declaring a generated field is
  enough: the job schedules, the requirement guards, the sample retries, the
  answer names the agent, and a correction upstream makes it stale.

  If this file needed a new runtime, a queue, or a second store, the claim that
  an agent is a job with memory would be false. It needs none.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Job, Snapshot, World}
  alias Blazie.Job.Generative
  alias Blazie.Agent

  setup do
    name = "e2e-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++
          Attribute.requires_seed() ++
          Job.seed() ++
          Generative.seed() ++ Agent.seed()
      )

    {:ok, _} = World.append(world, Attribute.define("body", answers: "name"))

    {:ok, _} =
      World.append(
        world,
        Agent.declare("severity",
          produces: "ticket",
          watches: ["body"],
          asks: "openai:gpt-4o-mini",
          answers: "name",
          describe: "low, medium or high"
        ) ++
          Job.declare("severity") ++
          [
            {"severity", "requires", "known_severity"},
            {"known_severity", "is", "formula"},
            {"known_severity", "source",
             "return value == 'low' or value == 'medium' or value == 'high'"}
          ]
      )

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  # A model that answers whatever it was told to, in order. Standing in for a
  # provider so the test is about the machinery rather than about somebody
  # else's uptime.
  defp answering(_world, answers) do
    said = :counters.new(1, [])

    Job.new("severity", fn snapshot, _attempt ->
      for id <- Agent.due(snapshot, "severity") do
        :counters.add(said, 1, 1)
        {id, "severity", Enum.at(answers, :counters.get(said, 1) - 1, List.last(answers))}
      end
    end)
  end

  test "a ticket lands, the agent answers, and the answer names it", %{world: world} do
    {:ok, _} = World.append(world, [{"t1", "body", "the server is on fire"}])
    assert Agent.due(snapshot(world), "severity") == ["t1"]

    job = answering(world, ["high"])
    assert {:ok, _tx, %{tries: 1}} = Generative.sample(job, world, snapshot(world), 1000)

    assert Snapshot.value(snapshot(world), "t1", "severity") == "high"
    assert [%{by: "severity"}] = Snapshot.find(snapshot(world), id: "t1", attribute: "severity")
  end

  test "an answer that fails its requirement is retried, and never written", %{world: world} do
    {:ok, _} = World.append(world, [{"t1", "body", "hello"}])

    # First answer is not one of the three allowed. It must never appear.
    job = answering(world, ["catastrophic", "medium"])
    assert {:ok, _tx, %{tries: 2}} = Generative.sample(job, world, snapshot(world), 1000)

    values =
      snapshot(world) |> Snapshot.find(id: "t1", attribute: "severity") |> Enum.map(& &1.value)

    assert values == ["medium"]
  end

  test "which requirement it passed is a fact, not a log", %{world: world} do
    {:ok, _} = World.append(world, [{"t1", "body", "hello"}])
    {:ok, _tx, _} = Generative.sample(answering(world, ["low"]), world, snapshot(world), 1000)

    assert [%{value: "known_severity"}] =
             Snapshot.find(snapshot(world), id: "t1", attribute: "satisfied")
  end

  test "correcting the ticket makes the answer stale, with nothing enqueued", %{world: world} do
    {:ok, _} = World.append(world, [{"t1", "body", "hello"}])
    {:ok, _tx, _} = Generative.sample(answering(world, ["low"]), world, snapshot(world), 1000)
    assert Agent.due(snapshot(world), "severity") == []

    {:ok, _} = World.append(world, [{"t1", "body", "the server is on fire"}])

    # Nobody invalidated anything. The transaction is the clock.
    assert Agent.due(snapshot(world), "severity") == ["t1"]
  end

  test "what it believed before is still true where it was written", %{world: world} do
    {:ok, _} = World.append(world, [{"t1", "body", "hello"}])
    {:ok, _tx, _} = Generative.sample(answering(world, ["low"]), world, snapshot(world), 1000)

    before = snapshot(world) |> Snapshot.name() |> Map.values() |> List.first()

    {:ok, _} = World.append(world, [{"t1", "body", "on fire"}])
    {:ok, _tx, _} = Generative.sample(answering(world, ["high"]), world, snapshot(world), 2000)

    assert Snapshot.value(snapshot(world), "t1", "severity") == "high"

    # The question no prompt library can answer: what did it think on Tuesday?
    at_the_time =
      Snapshot.reopen!(Map.new(Snapshot.name(snapshot(world)), fn {w, _} -> {w, before} end))

    assert Snapshot.value(at_the_time, "t1", "severity") == "low"
  end

  test "it never runs for an entity missing what it watches", %{world: world} do
    {:ok, _} = World.append(world, Attribute.define("colour"))
    {:ok, _} = World.append(world, [{"t9", "colour", "blue"}])

    assert Agent.due(snapshot(world), "severity") == []
  end
end
