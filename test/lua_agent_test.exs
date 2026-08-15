defmodule Blazie.LuaAgentTest do
  @moduledoc """
  C2/C3 — the pi agent, end to end: the loop is a Lua program in a guest.

  agent.lua runs as a workspace guest with the grants it needs (ask, file,
  sh). A scripted model drives it through a real coding task — read, write,
  run, done — and every action happens over the workspace map, inside the
  fence, with no Elixir in the loop. This proves the whole agent runs in the
  process, which is the point: it is embeddable anywhere a Luerl with these
  grants runs.
  """
  use ExUnit.Case, async: false

  alias Blazie.Lua

  defp scripted(turns) do
    at = :counters.new(1, [])
    me = self()

    fn _ref, messages, _tools, _opts ->
      i = :counters.get(at, 1)
      :counters.add(at, 1, 1)
      send(me, {:turn, i + 1, messages})

      case Enum.at(turns, i) do
        {:calls, calls} -> {:ok, {:calls, calls}, %{in: 1, out: 1}}
        {:said, text} -> {:ok, {:said, text}, %{in: 1, out: 1}}
        nil -> {:ok, {:said, "done"}, %{in: 1, out: 1}}
      end
    end
  end

  # Run agent.lua over a workspace with a scripted model.
  defp run_agent(task, files, turns) do
    agent_src = File.read!(Path.join(:code.priv_dir(:blazie), "lua/agent.lua"))

    source = """
    #{agent_src |> String.replace(~r/\nreturn agent\n?$/, "\n")}
    return agent.run(#{inspect(task)}, 12)
    """

    Lua.workspace(source, files,
      model: "openai:x",
      provider: scripted(turns)
    )
  end

  test "the agent writes a file, runs it, and finishes — over the workspace, in the fence" do
    task = "create greeting.txt containing hello, verify it"

    turns = [
      {:calls,
       [%{id: "1", name: "write", arguments: %{"path" => "greeting.txt", "content" => "hello"}}]},
      {:calls, [%{id: "2", name: "run", arguments: %{"line" => "cat greeting.txt | upper"}}]},
      {:calls,
       [%{id: "3", name: "done", arguments: %{"summary" => "wrote and verified greeting.txt"}}]}
    ]

    {:ok, answer} = run_agent(task, %{}, turns)

    assert answer.value == "wrote and verified greeting.txt"
    # The write actually landed in the workspace…
    assert answer.files["greeting.txt"] == "hello"
    # …and the model's second turn saw the file's own bytes come back from run.
    assert_received {:turn, 1, _}
    assert_received {:turn, 2, _}
    assert_received {:turn, 3, msgs}
    assert Enum.any?(msgs, fn m -> is_map(m) and Map.get(m, "content", "") =~ "HELLO" end)
  end

  test "the agent reads an existing file before editing it" do
    task = "read config.txt"
    files = %{"config.txt" => "port=8080\n"}

    turns = [
      {:calls, [%{id: "1", name: "read", arguments: %{"path" => "config.txt"}}]},
      {:calls, [%{id: "2", name: "done", arguments: %{"summary" => "read the config"}}]}
    ]

    {:ok, answer} = run_agent(task, files, turns)
    assert answer.value == "read the config"
    # The model's second turn saw the file content the read returned.
    assert_received {:turn, 1, _}
    assert_received {:turn, 2, msgs}
    assert Enum.any?(msgs, fn m -> is_map(m) and Map.get(m, "content", "") =~ "port=8080" end)
  end

  test "the agent stops at its step budget rather than looping forever" do
    # A model that always asks to run, never done — the budget is the stopper.
    turns =
      List.duplicate(
        {:calls, [%{id: "x", name: "run", arguments: %{"line" => "echo tick"}}]},
        20
      )

    {:ok, answer} = run_agent("loop", %{}, turns)
    assert answer.value =~ "step budget"
  end

  test "the whole agent ran in one guest process — the fence held throughout" do
    # A tool call trying to reach the host still hits the shell's shelf, and
    # the agent keeps going: the loop is fenced end to end.
    turns = [
      {:calls, [%{id: "1", name: "run", arguments: %{"line" => "curl http://evil.example"}}]},
      {:calls, [%{id: "2", name: "done", arguments: %{"summary" => "the curl was refused"}}]}
    ]

    {:ok, answer} = run_agent("try to escape", %{}, turns)
    assert answer.value == "the curl was refused"
    # The model saw the shelf refusal as the observation.
    assert_received {:turn, 1, _}
    assert_received {:turn, 2, msgs}
    assert Enum.any?(msgs, fn m -> is_map(m) and Map.get(m, "content", "") =~ "not a builtin" end)
  end
end
