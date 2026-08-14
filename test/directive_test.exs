defmodule Blazie.DirectiveTest do
  @moduledoc """
  Effects the runtime owns, rather than shapes the loop recognises.

  `Coding` matched `"writing" => true` out of a tool's answer and did the work
  inline — Jido's directive idea with no type, no registry and no record, and it
  meant every new effect was another branch in one `case`.

  What is asserted here is the three things that buys: the registry is a bound,
  both halves are facts, and delegation is a run rather than a new kind of thing.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Coding, Directive, Model, Run, Snapshot, Spend, Tool, World}

  setup do
    {:ok, world} = World.open("dir-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++
          Spend.seed() ++
          Model.seed() ++
          Run.seed() ++
          Tool.seed() ++
          Coding.seed() ++ Directive.seed() ++ Directive.Ask.seed()
      )

    {:ok, _} = World.append(world, Coding.declare("coder"))
    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])
  defp doing(world), do: %{world: world, run: "r", snapshot: snapshot(world), opts: []}

  describe "the registry is the bound" do
    test "what the runtime can do is a list somebody can read" do
      assert Enum.sort(Map.keys(Directive.known())) == ["ask", "research", "run", "write"]
    end

    test "asking for something absent is refused with what is available", %{world: world} do
      assert {:error, refusal} = Directive.perform(doing(world), %{"do" => "rm -rf"})

      assert refusal.problem == :no_such_directive
      assert refusal.repair =~ "ask, research, run, write"

      # Absent rather than forbidden. A tool cannot reach past this list because
      # the list is what reaching means.
      assert refusal.repair =~ "absent rather than forbidden"
    end

    test "an answer that is not a directive passes straight through", %{world: world} do
      assert {:ok, %{"paths" => ["a"]}} = Directive.perform(doing(world), %{"paths" => ["a"]})
    end
  end

  describe "both halves are facts" do
    test "what was asked and what came of it", %{world: world} do
      {:ok, _} =
        Directive.perform(doing(world), %{"do" => "write", "path" => "a.lua", "content" => "x"})

      asked = Directive.asked_for(snapshot(world), "r")
      assert [%{"do" => "write", "path" => "a.lua"}] = asked

      [came] =
        Snapshot.find(snapshot(world), id: "r", attribute: "came_of_it") |> Enum.map(& &1.value)

      assert came["do"] == "write"
      assert came["answered"]["wrote"] == "a.lua"
    end

    test "a directive that failed is as visible as one that worked", %{world: world} do
      {:error, _} = Directive.perform(doing(world), %{"do" => "write", "path" => "a.lua"})

      [came] =
        Snapshot.find(snapshot(world), id: "r", attribute: "came_of_it") |> Enum.map(& &1.value)

      # Jido's directives are values the server applies and discards. Here the
      # refusal survives, so "what did this agent do to the world" is a query
      # rather than an inference from its prose.
      assert came["refused"] =~ "needs `path` and `content`"
    end
  end

  describe "delegation" do
    test "a child is a run, with what asked for it", %{world: world} do
      once = fn _r, messages, _t, _o ->
        if length(messages) > 1,
          do: {:ok, {:said, "child finished"}, %{in: 1, out: 1}},
          else: {:ok, {:said, "child finished"}, %{in: 1, out: 1}}
      end

      assert {:ok, %{"asked" => child, "said" => "child finished"}} =
               Directive.perform(
                 %{
                   world: world,
                   run: "r",
                   snapshot: snapshot(world),
                   opts: [asks: "openai:x", provider: once]
                 },
                 %{"do" => "ask", "task" => "do the small thing"}
               )

      # Not a new kind of thing: a run, which this tree already knows how to
      # resume, fork, compact and read afterwards.
      assert child in Run.all(snapshot(world))
      assert Snapshot.value(snapshot(world), child, "asked_by") == "r"
      assert Snapshot.value(snapshot(world), child, "depth") == 1
    end

    test "and it cannot delegate forever", %{world: world} do
      {:ok, _} = World.append(world, [{"deep", "depth", 2}])

      assert {:error, refusal} =
               Directive.perform(
                 %{
                   world: world,
                   run: "deep",
                   snapshot: snapshot(world),
                   opts: [asks: "openai:x"]
                 },
                 %{"do" => "ask", "task" => "and another"}
               )

      # A child that could delegate without limit is a fork bomb with a language
      # model attached, and the bill arrives before the recursion does.
      assert refusal.problem == :too_deep
      assert refusal.repair =~ "bill before it is a recursion"
    end
  end

  test "the loop knows nothing about what a tool means", %{world: world} do
    # The property worth having. `write` and `run` and `ask` are three entries in
    # a map; the loop runs a tool and hands the answer to the runtime. Adding a
    # fourth effect is a module, not a branch.
    speak = fn _r, messages, _t, _o ->
      if length(messages) > 1,
        do: {:ok, {:said, "done"}, %{in: 1, out: 1}},
        else:
          {:ok,
           {:calls,
            [%{id: "c", name: "write", arguments: %{"path" => "z.lua", "content" => "return 9"}}]},
           %{in: 1, out: 1}}
    end

    assert {:ok, "done", _} =
             Coding.work(world, "loop", "write z.lua", asks: "openai:x", provider: speak)

    assert Coding.read(snapshot(world), "z.lua") == "return 9"
    assert [%{"do" => "write"}] = Directive.asked_for(snapshot(world), "loop")
  end
end
