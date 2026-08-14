defmodule Blazie.ToolLiveTest do
  @moduledoc """
  An agent doing something rather than saying something.

  The tool answers what no model could know — a lookup table only this world
  holds — so an answer that is right is proof the call happened. `mix test
  --include live`.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Snapshot, Tool, World}

  @moduletag :live

  # Whatever you point it at — see `model_live_test.exs`. Pinned to one vendor,
  # a live test proves that one vendor answers, which is not the question.
  defp live_chat, do: System.get_env("LIVE_CHAT") || "openrouter:anthropic/claude-haiku-4.5"
  @moduletag timeout: 90_000

  setup do
    name = "toollive-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Blazie.Job.seed() ++ Tool.seed())

    {:ok, _} =
      World.append(
        world,
        Tool.declare("plan_of",
          describe: "Look up which subscription plan a customer is on, by their id.",
          takes: [customer: [answers: "name"]],
          source: """
          local plans = { c_9134 = 'enterprise', c_2200 = 'hobby' }
          answer.plan = plans[args.customer] or 'unknown'
          """
        ) ++ [{"triage", "may_use", "plan_of"}]
      )

    %{world: world}
  end

  test "it answers something only the tool could answer, and the call is a fact", %{world: world} do
    snapshot = Snapshot.open([world])
    tools = Tool.available(snapshot, "triage")
    assert [%{name: "plan_of"}] = tools

    {:ok, said, made} =
      Blazie.Model.converse(
        live_chat(),
        "Which plan is customer c_9134 on? Answer with just the plan name.",
        tools,
        &Tool.run(snapshot, &1),
        calls: Tool.calls_allowed(snapshot, "triage")
      )

    # `enterprise` exists nowhere but that Lua table.
    assert String.contains?(String.downcase(said), "enterprise")
    assert [%{call: %{name: "plan_of"}}] = made

    {:ok, _} =
      World.append(world, Enum.map(made, &Tool.called("triage", &1.call, &1.answered, "triage")))

    # A trace is a query, not a log somebody remembered to keep.
    [%{value: recorded, by: "triage"}] =
      Snapshot.find(Snapshot.open([world]), id: "triage", attribute: "called")

    assert recorded["tool"] == "plan_of"
    assert recorded["arguments"]["customer"] == "c_9134"
    assert recorded["answered"]["plan"] == "enterprise"
  end
end
