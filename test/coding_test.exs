defmodule Blazie.CodingTest do
  @moduledoc """
  The coding agent, driven by a scripted model.

  An ordinary loop — read, edit, repeat. What is worth asserting is not that it
  loops but where its effects go: files are facts, a tool never writes, and a
  refused write comes back to the model as a reason rather than as a crash.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Coding, Model, Run, Snapshot, Spend, Tool, World}

  setup do
    {:ok, world} = World.open("coding-#{System.unique_integer([:positive])}")
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

  # A model that plays a fixed script of turns.
  defp scripted(turns) do
    at = :counters.new(1, [])

    fn _r, _m, _t, _o ->
      i = :counters.get(at, 1)
      :counters.add(at, 1, 1)

      case Enum.at(turns, i) do
        nil ->
          {:ok, {:said, "done"}, %{in: 1, out: 1}}

        {:say, said} ->
          {:ok, {:said, said}, %{in: 1, out: 1}}

        {:call, name, args} ->
          {:ok, {:calls, [%{id: "c", name: name, arguments: args}]}, %{in: 1, out: 1}}
      end
    end
  end

  defp work(world, turns) do
    Coding.work(world, "run-1", "make it right", asks: "openai:x", provider: scripted(turns))
  end

  test "its tools are lua, and they read the world", %{world: world} do
    {:ok, _} =
      World.append(world, [
        {"file:a.lua", "path", "a.lua"},
        {"file:a.lua", "content", "return 1"}
      ])

    assert {:ok, %{"paths" => ["a.lua"]}} =
             Tool.run(snapshot(world), %{name: "list", arguments: %{}})

    assert {:ok, %{"content" => "return 1"}} =
             Tool.run(snapshot(world), %{name: "read", arguments: %{"path" => "a.lua"}})
  end

  test "a write ANSWERS rather than writing", %{world: world} do
    # The tool itself must not touch the world: an agent's answer is exactly the
    # thing nobody has decided about yet.
    assert {:ok, %{"do" => "write", "path" => "b.lua"}} =
             Tool.run(snapshot(world), %{
               name: "write",
               arguments: %{"path" => "b.lua", "content" => "return 2"}
             })

    assert Coding.files(snapshot(world)) == []
  end

  test "the loop applies the write, and it lands as facts", %{world: world} do
    assert {:ok, "done", made} =
             work(world, [
               {:call, "write", %{"path" => "b.lua", "content" => "return 2"}},
               {:say, "done"}
             ])

    assert [%{call: %{name: "write"}, answered: %{"wrote" => "b.lua"}}] = made
    assert Coding.files(snapshot(world)) == ["b.lua"]
    assert Coding.read(snapshot(world), "b.lua") == "return 2"
  end

  test "and the whole thing is a run afterwards", %{world: world} do
    {:ok, _, _} =
      work(world, [
        {:call, "list", %{}},
        {:call, "write", %{"path" => "c.lua", "content" => "return 3"}},
        {:say, "wrote c.lua"}
      ])

    # Every turn under one id, readable after the fact — which is what makes a
    # trajectory something `Learned` and `Refinement` can read.
    turns = Run.turns(snapshot(world), "run-1")
    assert length(turns) == 3

    said = Enum.map_join(turns, " ", & &1.answered)
    assert said =~ "list"
    assert said =~ "write"
    assert said =~ "wrote c.lua"
  end

  test "a refused write comes back as a reason, not a crash", %{world: world} do
    # `content` is declared to answer any, so make a requirement it can break.
    {:ok, _} =
      World.append(
        world,
        Attribute.requires_seed() ++
          [
            {"content", "requires", "not_empty"},
            {"not_empty", "is", "formula"},
            {"not_empty", "source", "return #value > 0"}
          ]
      )

    assert {:ok, _said, made} =
             work(world, [
               {:call, "write", %{"path" => "d.lua", "content" => ""}},
               {:say, "I will try again"}
             ])

    assert [%{answered: %{"error" => reason}}] = made
    assert reason =~ "refused"

    # Nothing landed, and the model was told why — which is the repair path, and
    # the difference between a loop that recovers and one that repeats.
    assert Coding.files(snapshot(world)) == []
  end

  @tag :python
  test "it runs a file in the sandbox and gets what it printed", %{world: world} do
    {:ok, _} =
      World.append(world, [
        {"file:go.py", "path", "go.py"},
        {"file:go.py", "content", "print(6*7)"}
      ])

    assert {:ok, %{"printed" => printed}} =
             Coding.execute(world, "run-1", "go.py", snapshot(world))

    assert String.trim(printed) == "42"
  end

  @tag :python
  test "the whole workspace is beside it, so an import works", %{world: world} do
    {:ok, _} =
      World.append(world, [
        {"file:lib.py", "path", "lib.py"},
        {"file:lib.py", "content", "def double(n):\n    return n * 2\n"},
        {"file:go.py", "path", "go.py"},
        {"file:go.py", "content",
         "import sys\nsys.path.insert(0, '/work')\nimport lib\nprint(lib.double(21))\n"}
      ])

    assert {:ok, %{"printed" => printed}} =
             Coding.execute(world, "run-1", "go.py", snapshot(world))

    assert String.trim(printed) == "42"
  end

  @tag :python
  test "what it writes comes back as facts", %{world: world} do
    {:ok, _} =
      World.append(world, [
        {"file:go.py", "path", "go.py"},
        {"file:go.py", "content", "open('/work/out.txt','w').write('made by the guest')"}
      ])

    assert {:ok, %{"changed" => changed}} =
             Coding.execute(world, "run-1", "go.py", snapshot(world))

    # A run that wrote a file and told nobody would be a run whose work vanished
    # with the directory it happened in.
    assert "out.txt" in changed
    assert Coding.read(snapshot(world), "out.txt") == "made by the guest"
  end

  @tag :python
  test "a file that fails comes back with the traceback, not a crash", %{world: world} do
    {:ok, _} =
      World.append(world, [
        {"file:bad.py", "path", "bad.py"},
        {"file:bad.py", "content", "raise ValueError('deliberate')"}
      ])

    assert {:ok, answered} = Coding.execute(world, "run-1", "bad.py", snapshot(world))

    # The model has to be able to read what went wrong; a refusal it never sees
    # is a loop that repeats.
    assert answered["failed"] =~ "ValueError" or answered["failed"] =~ "deliberate"
  end

  test "without a python module it says what to set", %{world: world} do
    held = Application.get_env(:blazie, :python_wasm)
    Application.delete_env(:blazie, :python_wasm)
    on_exit(fn -> if held, do: Application.put_env(:blazie, :python_wasm, held) end)

    if System.get_env("PYTHON_WASM") do
      assert true
    else
      assert {:error, refusal} = Coding.execute(world, "run-1", "go.py", snapshot(world))
      assert refusal.problem == :no_python
      assert refusal.repair =~ "PYTHON_WASM"
    end
  end

  test "the prompt is built from what is declared", %{world: world} do
    {:ok, _} =
      World.append(world, [{"file:x.lua", "path", "x.lua"}, {"file:x.lua", "content", "--"}])

    said = Coding.prompt(snapshot(world), "coder", "do the thing")

    # The workspace it is actually looking at, and the tools it actually has —
    # neither of which can drift, because neither is written down twice.
    assert said =~ "x.lua"
    assert said =~ "do the thing"
    assert said =~ "list —"
    assert said =~ "write"
  end

  test "an agent only reaches the tools it was granted", %{world: world} do
    {:ok, _} =
      World.append(
        world,
        Tool.declare("dangerous", describe: "not for you", takes: %{}, source: "answer.x = 1")
      )

    names = Enum.map(Tool.available(snapshot(world), "coder"), & &1.name) |> Enum.sort()

    # Declared in the same world and not granted, so not offered. Two agents in
    # one world are not two agents with each other's hands.
    assert names == ["ask", "list", "read", "run", "write"]
  end
end
