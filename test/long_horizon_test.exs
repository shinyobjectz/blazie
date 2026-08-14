defmodule Blazie.LongHorizonTest do
  @moduledoc """
  A session that outlasts a context window.

  `converse/5` accumulates its messages in memory for the length of one call.
  That is correct for a call and it is the one thing in this stack that grows
  without a bound — so a long session is several calls, and between them the
  context is rebuilt from facts under a policy.

  Mellea's position reached from the other side: the context is per call and the
  durable thing is the record. What it buys here is that a session has no length
  limit at all; what it has is an assembly that stays the size the policy says,
  however long the session runs.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Coding, Model, Run, Snapshot, Spend, Tool, World}

  setup do
    {:ok, world} = World.open("horizon-#{System.unique_integer([:positive])}")
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

  defp turned(world, run, n) do
    for i <- 1..n do
      {:ok, _} =
        World.append(world, [
          {run, "asked", "step #{i}", run},
          {run, "answered", "did #{i}", run}
        ])
    end
  end

  describe "the assembly is bounded, the record is not" do
    test "everything comes back when nothing says otherwise", %{world: world} do
      turned(world, "r", 4)
      assert length(Run.messages(snapshot(world), "r")) == 8
    end

    test "`keep` is a window on the end", %{world: world} do
      turned(world, "r", 20)

      # Twenty turns in the record, three in the assembly. The forty messages
      # that would otherwise be sent are not pruned from anything — they were
      # simply not selected.
      messages = Run.messages(snapshot(world), "r", keep: 3)
      assert length(messages) == 6
      assert List.last(messages)["content"] == "did 20"
      assert hd(messages)["content"] == "step 18"

      assert length(Run.turns(snapshot(world), "r")) == 20
    end

    test "a summary stands in for what it covers, and the turns stay", %{world: world} do
      turned(world, "r", 10)
      {:ok, _} = Run.compact(world, "r", 7, "steps one to seven: set things up")

      messages = Run.messages(snapshot(world), "r")

      # One summary plus the three turns after it.
      assert length(messages) == 7
      assert hd(messages)["content"] =~ "steps one to seven"
      assert Enum.at(messages, 1)["content"] == "step 8"

      # And nothing was destroyed to make that true.
      assert length(Run.turns(snapshot(world), "r")) == 10
    end

    test "outstanding counts what has not been folded yet", %{world: world} do
      turned(world, "r", 10)
      assert Run.outstanding(snapshot(world), "r") == 10

      {:ok, _} = Run.compact(world, "r", 7, "a summary")
      assert Run.outstanding(snapshot(world), "r") == 3
    end
  end

  describe "compaction asks a model, and writes what it said" do
    test "folds everything but the window", %{world: world} do
      turned(world, "r", 12)

      said = fn _r, _m, _t, _o ->
        {:ok, {:said, "they set up a project and wrote two files"}, %{in: 1, out: 1}}
      end

      assert {:ok, 6} =
               Run.compact_with(world, "r", snapshot(world),
                 asks: "openai:x",
                 keep: 6,
                 provider: said
               )

      messages = Run.messages(snapshot(world), "r")
      assert hd(messages)["content"] =~ "set up a project"
      assert length(messages) == 13

      # Twelve turns still there, six of them now represented rather than sent.
      assert length(Run.turns(snapshot(world), "r")) == 12
    end

    test "says there is nothing to do rather than summarising nothing", %{world: world} do
      turned(world, "r", 4)

      assert :enough =
               Run.compact_with(world, "r", snapshot(world), asks: "openai:x", keep: 6)
    end
  end

  describe "a session that runs out of calls carries on" do
    test "across stretches, with what it did already visible as facts", %{world: world} do
      # A model that only ever calls a tool: it will exhaust its calls in every
      # stretch and never answer. What is asserted is that the work continued
      # rather than stopping at the first ceiling.
      always = fn _r, _m, _t, _o ->
        {:ok, {:calls, [%{id: "c", name: "list", arguments: %{}}]}, %{in: 1, out: 1}}
      end

      assert {:ok, "out of stretches", made} =
               Coding.work(world, "long", "keep looking",
                 asks: "openai:x",
                 provider: always,
                 calls: 2,
                 stretches: 3
               )

      # Two calls a stretch, three stretches. A single `converse` would have
      # stopped at two.
      assert length(made) == 6
    end

    test "and stops as soon as it answers", %{world: world} do
      once = fn _r, messages, _t, _o ->
        if length(messages) > 1,
          do: {:ok, {:said, "finished"}, %{in: 1, out: 1}},
          else: {:ok, {:calls, [%{id: "c", name: "list", arguments: %{}}]}, %{in: 1, out: 1}}
      end

      assert {:ok, "finished", _} =
               Coding.work(world, "short", "do it",
                 asks: "openai:x",
                 provider: once,
                 calls: 4,
                 stretches: 3
               )
    end
  end
end
