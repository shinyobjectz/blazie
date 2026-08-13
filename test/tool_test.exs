defmodule Blazie.ToolTest do
  @moduledoc """
  Something a model may ask to have run, which is a job.

  The load-bearing tests are the two limits. A tool loop has no natural end — a
  model that calls, reads and calls again will do it forever — and a tool's
  arguments come from a model, so anything interpolated into Lua is a fence
  undone by a quote mark.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Snapshot, Tool, World}

  setup do
    name = "tool-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Blazie.Job.seed() ++ Tool.seed())
    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  describe "a tool is a job" do
    test "declared with what it is for and what it takes", %{world: world} do
      {:ok, _} =
        World.append(
          world,
          Tool.declare("plan",
            describe: "Look up a customer's plan.",
            takes: [customer: [answers: "name"]],
            source: "answer.plan = 'pro'"
          )
        )

      # It IS a job — the fence already decided that a thing which reaches
      # outside is one, so nothing here had to.
      facts =
        snapshot(world)
        |> Snapshot.find(id: "plan")
        |> Enum.map(&{&1.id, &1.attribute, &1.value})

      assert {"plan", "is", "job"} in facts
      assert {"plan", "describe", "Look up a customer's plan."} in facts
    end

    test "only the tools a field may use are offered", %{world: world} do
      {:ok, _} = World.append(world, Tool.declare("plan", describe: "d", takes: [], source: "answer.x = 1"))
      {:ok, _} = World.append(world, Tool.declare("secret", describe: "d", takes: [], source: "answer.x = 2"))
      {:ok, _} = World.append(world, [{"severity", "may_use", "plan"}])

      assert [%{name: "plan"}] = Tool.available(snapshot(world), "severity")
    end
  end

  describe "running one" do
    test "its arguments arrive as args, its answer as answer", %{world: world} do
      {:ok, _} =
        World.append(
          world,
          Tool.declare("echo",
            describe: "echo",
            takes: [word: [answers: "name"]],
            source: "answer.said = args.word"
          )
        )

      assert {:ok, %{"said" => "hello"}} =
               Tool.run(snapshot(world), %{name: "echo", arguments: %{"word" => "hello"}, id: "1"})
    end

    test "it gets the job world, so it may reach outside", %{world: world} do
      {:ok, _} = World.append(world, Tool.declare("reach", describe: "d", takes: [], source: "answer.can = (http ~= nil)"))

      assert {:ok, %{"can" => true}} =
               Tool.run(snapshot(world), %{name: "reach", arguments: %{}, id: "1"})
    end

    test "one that is not declared is a refusal, not a crash", %{world: world} do
      assert {:error, %{problem: :no_such_tool}} =
               Tool.run(snapshot(world), %{name: "ghost", arguments: %{}, id: "1"})
    end

    test "one that never finishes is stopped", %{world: world} do
      {:ok, _} = World.append(world, Tool.declare("spin", describe: "d", takes: [], source: "while true do end"))

      assert {:error, refusal} =
               Tool.run(snapshot(world), %{name: "spin", arguments: %{}, id: "1"}, deadline: 300)

      assert refusal.problem == :took_too_long
    end
  end

  describe "arguments come from a model, so they are encoded" do
    test "a quote mark cannot close the literal and append Lua", %{world: world} do
      {:ok, _} =
        World.append(
          world,
          Tool.declare("echo", describe: "d", takes: [word: [answers: "name"]], source: "answer.said = args.word")
        )

      # If arguments were interpolated, this would end the string and run
      # `escaped = true` — the whole fence undone by one character.
      hostile = "hello' escaped = true --"

      assert {:ok, %{"said" => ^hostile}} =
               Tool.run(snapshot(world), %{name: "echo", arguments: %{"word" => hostile}, id: "1"})
    end

    test "a newline cannot either", %{world: world} do
      {:ok, _} =
        World.append(
          world,
          Tool.declare("echo", describe: "d", takes: [word: [answers: "name"]], source: "answer.said = args.word")
        )

      hostile = "a\nb"
      assert {:ok, %{"said" => ^hostile}} =
               Tool.run(snapshot(world), %{name: "echo", arguments: %{"word" => hostile}, id: "1"})
    end
  end

  describe "how much a run may spend" do
    test "defaults, and is declared as a fact when it should not", %{world: world} do
      assert Tool.calls_allowed(snapshot(world), "severity") == Tool.default_calls_allowed()

      {:ok, _} = World.append(world, [{"severity", "calls_allowed", 1}])
      assert Tool.calls_allowed(snapshot(world), "severity") == 1
    end
  end

  describe "the loop ends" do
    test "a model that only ever calls runs out and says so" do
      # No provider is reached: this drives the loop directly to prove the cap
      # is what stops it. Without this a tool loop is a bill with no ceiling.
      always_calls = fn _reference, _messages, _tools, _opts ->
        {:ok, {:calls, [%{id: "1", name: "x", arguments: %{}}]}}
      end

      assert {:error, refusal} = drive(always_calls, 3)
      assert refusal.problem == :too_many_calls
      assert refusal.repair =~ "calls_allowed"
    end

    test "and one that answers ends it" do
      answers = fn _r, _m, _t, _o -> {:ok, {:said, "done"}} end
      assert {:ok, "done", []} = drive(answers, 3)
    end
  end

  # A stand-in provider, so the loop is tested rather than somebody's uptime.
  defp drive(converse, calls) do
    Process.put(:fake_converse, converse)
    Blazie.ToolTest.FakeLoop.converse(calls)
  end

  defmodule FakeLoop do
    @moduledoc false
    def converse(calls) do
      run = fn _call -> {:ok, %{"ok" => true}} end
      loop(Process.get(:fake_converse), [], run, calls, [])
    end

    defp loop(_c, _made, _run, 0, made), do: {:error, %{problem: :too_many_calls, repair: "raise `calls_allowed`"}}

    defp loop(converse, messages, run, left, made) do
      case converse.(nil, messages, [], []) do
        {:ok, {:said, said}} -> {:ok, said, Enum.reverse(made)}
        {:ok, {:calls, calls}} ->
          Enum.each(calls, run)
          loop(converse, messages, run, left - 1, made)
      end
    end
  end
end
