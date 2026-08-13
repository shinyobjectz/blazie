defmodule Blazie.AgentUnattendedTest do
  @moduledoc """
  Phase 0's whole claim: one declared agent runs with nobody calling it.

  Live, because the thing being proven cannot be stubbed. A stub would show the
  wiring holds; only a real model shows that a declaration is enough — that
  writing one fact into a world causes a model to be asked, an answer to be
  checked, and a fact to land, with no line of code invoking any of it.

  `mix test --include live` with OPENROUTER_API_KEY set.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Agent, Agents, Attribute, Job, Snapshot, World}

  @moduletag :live
  @moduletag timeout: 90_000

  setup do
    name = "unattended-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Agents.seed())
    {:ok, _} = World.append(world, Attribute.define("body", answers: "name"))

    {:ok, _} =
      World.append(
        world,
        Agent.declare("severity",
          produces: "ticket",
          watches: ["body"],
          asks: "openrouter:anthropic/claude-haiku-4.5",
          answers: "name",
          describe: "exactly one of: low, medium, high"
        ) ++
          Job.declare("severity", every: 1) ++
          [
            {"severity", "requires", "known"},
            {"known", "is", "formula"},
            {"known", "source",
             "return value == 'low' or value == 'medium' or value == 'high'"}
          ]
      )

    %{world: world, name: name}
  end

  defp settle(world, id, field, remaining \\ 120) do
    case {Snapshot.value(Snapshot.open([world]), id, field), remaining} do
      {nil, 0} -> flunk("#{field} never appeared")
      {nil, _} -> Process.sleep(500) && settle(world, id, field, remaining - 1)
      {value, _} -> value
    end
  end

  test "a ticket lands and the agent answers it, with nobody calling anything", ctx do
    {:ok, agents} = Agents.start_link(world: ctx.name, every: 1)
    on_exit(fn -> if Process.alive?(agents), do: GenServer.stop(agents) end)

    # The runner is up and ticking. Nothing is due, so nothing is asked — the
    # cost gate, checked here rather than assumed.
    assert Agent.due(Snapshot.open([ctx.world]), "severity") == []

    # The only line that does anything. Everything after is the system.
    {:ok, _} =
      World.append(ctx.world, [{"t1", "body", "the production database is down, total outage"}])

    severity = settle(ctx.world, "t1", "severity")
    snapshot = Snapshot.open([ctx.world])

    assert severity in ["low", "medium", "high"]

    # Named by the agent: an answer that came from nowhere would be
    # indistinguishable from one a caller typed in.
    assert [%{by: "severity"}] = Snapshot.find(snapshot, id: "t1", attribute: "severity")

    # And a record of what it was checked against, which is the thing no prompt
    # library can answer afterwards.
    assert [%{value: "known"}] = Snapshot.find(snapshot, id: "t1", attribute: "satisfied")

    # Answered, so no longer due. Without this the agent would re-ask forever.
    assert Agent.due(snapshot, "severity") == []
  end
end
