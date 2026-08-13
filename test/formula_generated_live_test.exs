defmodule Blazie.Formula.GeneratedLiveTest do
  @moduledoc """
  A model writes a program, it is verified, and it runs.

  Live because the thing being proven cannot be stubbed: that a declaration and
  a handful of examples are enough for a program to appear, and that a wrong one
  does not survive the gate. `mix test --include live`.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Formula, Snapshot, World}
  alias Blazie.Formula.Generated

  @moduletag :live
  @moduletag timeout: 120_000

  @asks "openrouter:anthropic/claude-haiku-4.5"

  setup do
    name = "genlive-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} =
      World.append(world, Attribute.seed() ++ Attribute.requires_seed() ++ Generated.seed())

    {:ok, _} = World.append(world, Attribute.define("age", answers: "integer"))
    {:ok, _} = World.append(world, Attribute.define("band", answers: "name"))

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  defp author(world, attempt) do
    write = Generated.author(snapshot(world), asks: @asks)
    {:ok, _tx} = World.append(world, write.(snapshot(world), attempt))
    :ok
  end

  defp declare(world, examples) do
    World.append(world, Generated.declare("bands", produces: "band", given: ["age"], examples: examples))
  end

  test "three examples, no source — a model writes one and it evaluates", %{world: world} do
    {:ok, _} =
      declare(world, [
        %{"given" => %{"age" => 9}, "expect" => "child"},
        %{"given" => %{"age" => 41}, "expect" => "adult"},
        %{"given" => %{"age" => 17}, "expect" => "child"}
      ])

    assert Generated.wanted(snapshot(world)) == ["bands"]

    # Up to three attempts: a rejected candidate feeds the next brief, which is
    # the loop's whole reason to exist. Asserting one attempt would make this
    # test about the model's luck rather than about the harness.
    Enum.reduce_while(1..3, nil, fn attempt, _ ->
      author(world, attempt)
      if Generated.wanted(snapshot(world)) == [], do: {:halt, :ok}, else: {:cont, nil}
    end)

    source = Snapshot.value(snapshot(world), "bands", "source")
    assert is_binary(source), "no source was adopted in three attempts"

    # It names what wrote it, so `at(42)` can say which version made an answer.
    assert [%{by: "author"} | _] = Snapshot.find(snapshot(world), id: "bands", attribute: "source")

    # And it works on real facts, not just on its examples.
    {:ok, _} = World.append(world, [{"ada", "age", 41}, {"kid", "age", 9}])
    [formula] = Formula.declared(snapshot(world))
    {answers, _read} = Formula.run(formula, snapshot(world))

    assert {"ada", "band", "adult", "bands"} in answers
    assert {"kid", "band", "child", "bands"} in answers
  end

  test "a candidate that fails is rejected with why, and does not replace a working one", %{
    world: world
  } do
    {:ok, _} =
      declare(world, [
        %{"given" => %{"age" => 9}, "expect" => "child"},
        %{"given" => %{"age" => 41}, "expect" => "adult"}
      ])

    Enum.reduce_while(1..3, nil, fn attempt, _ ->
      author(world, attempt)
      if Generated.wanted(snapshot(world)) == [], do: {:halt, :ok}, else: {:cont, nil}
    end)

    working = Snapshot.value(snapshot(world), "bands", "source")
    assert is_binary(working)

    # A band nobody demonstrated. The working program cannot satisfy it, so the
    # formula wants a body again.
    {:ok, _} =
      World.append(world, [{"bands", "example", %{"given" => %{"age" => 70}, "expect" => "elder"}}])

    assert Generated.wanted(snapshot(world)) == ["bands"]

    Enum.reduce_while(1..3, nil, fn attempt, _ ->
      author(world, attempt)
      if Generated.wanted(snapshot(world)) == [], do: {:halt, :ok}, else: {:cont, nil}
    end)

    # Whatever happened, the source in the world satisfies every example — a
    # failed attempt writes a rejection and leaves the working program alone.
    assert Generated.verify(snapshot(world), "bands", Snapshot.value(snapshot(world), "bands", "source")) == :ok
  end
end
