defmodule Blazie.CodingLiveTest do
  @moduledoc """
  The coding agent against a model that was not told what to do next.

  A scripted model proves the wiring: tools reach the world, writes land as
  facts, refusals come back as reasons. What it cannot prove is whether the
  assembled prompt is a prompt — whether a model handed this description of a
  workspace and these tool descriptions actually picks the right tool and fills
  its arguments in.

  That is the whole claim of "the prompt is assembled, never authored", and it
  is only testable against something that has not been told the answer.

  `mix test --include live`, with a key for whatever LIVE_CHAT names. Use an
  instruct model — see `refinement_live_test.exs` for what reasoning models cost
  on a task the schema has already constrained.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Coding, Model, Run, Snapshot, Spend, Tool, World}

  @moduletag :live
  @moduletag timeout: 300_000

  defp live_chat, do: System.get_env("LIVE_CHAT") || "openrouter:anthropic/claude-haiku-4.5"

  setup do
    {:ok, world} = World.open("coding-live-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++
          Spend.seed() ++
          Model.seed() ++
          Run.seed() ++
          Tool.seed() ++
          Coding.seed()
      )

    {:ok, _} = World.append(world, Coding.declare("coder"))
    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  test "it writes the file it was asked for", %{world: world} do
    {:ok, said, made} =
      Coding.work(
        world,
        "live-1",
        "Create a file called greet.lua whose content is exactly: return 'hello'",
        asks: live_chat(),
        timeout: 120_000,
        calls: 6
      )

    assert is_binary(said)

    # The claim: a model given only the assembled prompt picked `write` and
    # filled its arguments. Nothing here told it the tool's name.
    assert Enum.any?(made, &(&1.call.name == "write")),
           "it never called write; it called #{inspect(Enum.map(made, & &1.call.name))}"

    assert "greet.lua" in Coding.files(snapshot(world))
    assert Coding.read(snapshot(world), "greet.lua") =~ "hello"
  end

  test "it reads before it writes when it has to", %{world: world} do
    {:ok, _} =
      World.append(world, [
        {"file:count.lua", "path", "count.lua"},
        {"file:count.lua", "content", "return 41"}
      ])

    {:ok, _said, made} =
      Coding.work(
        world,
        "live-2",
        "The file count.lua is off by one. Read it, then correct it.",
        asks: live_chat(),
        timeout: 120_000,
        calls: 8
      )

    called = Enum.map(made, & &1.call.name)

    # Not asserting the order strictly — a model that lists first is not wrong.
    # Asserting that it looked at all, which is what the prompt asks for and
    # what a workspace it cannot see would make impossible.
    assert "read" in called or "list" in called
    assert Coding.read(snapshot(world), "count.lua") =~ "42"
  end

  @tag :python
  test "it writes python, runs it, and reads what happened", %{world: world} do
    # The loop that makes a coding agent converge rather than just edit: write,
    # execute, look at the output. Everything before this was an editor.
    {:ok, said, made} =
      Coding.work(
        world,
        "live-run",
        "Write a python file called sum.py that prints the sum of 1..10, then run it " <>
          "and tell me what it printed.",
        asks: live_chat(),
        timeout: 120_000,
        calls: 10
      )

    called = Enum.map(made, & &1.call.name)
    assert "write" in called
    assert "run" in called, "it never ran anything; it called #{inspect(called)}"

    # 55, computed by cpython inside the sandbox rather than by the model.
    ran = Enum.find(made, &(&1.call.name == "run"))
    assert ran.answered["printed"] =~ "55"
    assert said =~ "55"
  end

  test "and the whole thing is answerable afterwards", %{world: world} do
    {:ok, _, _} =
      Coding.work(world, "live-3", "Create hello.lua containing: return 1",
        asks: live_chat(),
        timeout: 120_000,
        calls: 6
      )

    # Every turn, what it cost, what it called — a query, against the world it
    # was working in.
    assert length(Run.turns(snapshot(world), "live-3")) > 0
    assert %{in: went_in, out: came_out} = Spend.so_far(snapshot(world), "live-3")
    assert went_in > 0 and came_out > 0

    calls = Snapshot.find(snapshot(world), id: "live-3", attribute: "called")
    assert length(calls) > 0
  end
end
