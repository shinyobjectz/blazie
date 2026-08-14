defmodule Blazie.TrajectoryTest do
  @moduledoc """
  What an agent did, and what it cost, as a query.

  "Traces are the core" is the claim every continual-learning design rests on,
  and a trace kept as a log is a second store that has to be joined to the data
  and kept in step. Here a turn IS facts in the world it acted on, so the
  question is asked in the language the rest of the data is already in — and the
  answer at an old snapshot name is still the answer.

  `Spend` was written for this and nothing called it. `model` was in its seed
  from the start and nothing ever wrote it, so "what did gpt-4o-mini cost us"
  was a question the vocabulary could ask and the data could not answer.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Model, Snapshot, Spend, Tool, World}

  setup do
    {:ok, world} = World.open("trace-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} =
      World.append(world, Attribute.seed() ++ Spend.seed() ++ Model.seed() ++ Tool.seed())

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  defp saying(said, spent \\ %{in: 11, out: 5}) do
    fn _reference, _messages, _tools, _opts -> {:ok, {:said, said}, spent} end
  end

  test "a turn lands as facts in the world it acted on", %{world: world} do
    assert {:ok, "done", []} =
             Model.converse("openai:gpt-4o-mini", "do the thing", [], fn _ -> {:ok, %{}} end,
               provider: saying("done"),
               into: world,
               by: "run-1"
             )

    snapshot = snapshot(world)

    assert Snapshot.value(snapshot, "run-1", "asked") == "do the thing"
    assert Snapshot.value(snapshot, "run-1", "answered") == "done"
    assert Snapshot.value(snapshot, "run-1", "model") == "openai:gpt-4o-mini"
    assert is_integer(Snapshot.value(snapshot, "run-1", "took_ms"))
  end

  test "what it cost is a query, not a metrics system", %{world: world} do
    for _ <- 1..3 do
      {:ok, _, _} =
        Model.converse("openai:gpt-4o-mini", "again", [], fn _ -> {:ok, %{}} end,
          provider: saying("ok", %{in: 10, out: 4}),
          into: world,
          by: "run-1"
        )
    end

    # Three turns, summed from the facts themselves rather than from a counter
    # kept beside them — a tally is a second account that can disagree.
    assert %{in: 30, out: 12} = Spend.so_far(snapshot(world), "run-1")
  end

  test "a tool call is written too, so the sequence is recoverable", %{world: world} do
    calls_then_answers = fn _r, messages, _t, _o ->
      if length(messages) > 1 do
        {:ok, {:said, "found it"}, %{in: 2, out: 2}}
      else
        {:ok, {:calls, [%{id: "1", name: "lookup", arguments: %{"who" => "ada"}}]},
         %{in: 3, out: 1}}
      end
    end

    assert {:ok, "found it", [made]} =
             Model.converse(
               "openai:gpt-4o-mini",
               "who is ada",
               [],
               fn _ -> {:ok, %{"plan" => "pro"}} end,
               provider: calls_then_answers,
               into: world,
               by: "run-2"
             )

    assert made.call.name == "lookup"

    # Both turns are there: the one that asked for a tool and the one that
    # answered. A trajectory missing the calls is a trajectory that cannot
    # explain the answer.
    answered = Snapshot.find(snapshot(world), id: "run-2", attribute: "answered")
    assert length(answered) == 2
    assert Enum.any?(answered, &(&1.value =~ "lookup"))
    assert Enum.any?(answered, &(&1.value == "found it"))
  end

  test "without `into` nothing is written, and the work still happens", %{world: world} do
    # A loop that is not being recorded is the ordinary case — a caller with
    # nowhere to put a trajectory should not be forced to invent a world.
    assert {:ok, "done", []} =
             Model.converse("openai:gpt-4o-mini", "quiet", [], fn _ -> {:ok, %{}} end,
               provider: saying("done")
             )

    assert Snapshot.find(snapshot(world), attribute: "asked") == []
  end
end
