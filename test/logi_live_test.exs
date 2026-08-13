defmodule Logi.LiveTest do
  @moduledoc """
  The one thing a stub cannot prove: that this reaches a model and comes back.

  Excluded by default — a suite that needs an API key and a network is not a
  suite. But never running it at all is the failure this tree keeps having: a
  thing built, tested against its own assumptions, and never once pointed at
  reality. `mix test --include live` with OPENROUTER_API_KEY set.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Snapshot, Symbol, World}
  alias Logi.Embedding

  @moduletag :live

  @chat "openrouter:anthropic/claude-haiku-4.5"
  @embed "openrouter:openai/text-embedding-3-small"

  test "text comes back" do
    assert {:ok, said} = Logi.generate(@chat, "Reply with exactly the word: pong")
    assert said =~ "pong"
  end

  test "a declaration is honoured as a shape" do
    # No prompt says "answer with a string" — the declaration is the schema, and
    # this asserts the provider actually enforced it rather than returning prose.
    assert {:ok, %{"value" => severity}} =
             Logi.object(@chat, "The server is on fire and nobody can log in.",
               answers: "name",
               describe: "severity: exactly one of low, medium or high"
             )

    assert severity in ["low", "medium", "high"]
  end

  test "a shape blazie can decide is enforced as a number" do
    assert {:ok, %{"value" => count}} =
             Logi.object(@chat, "How many legs does a spider have?", answers: "integer")

    assert is_integer(count)
  end

  test "text becomes a symbol, and near means near" do
    {:ok, world} = World.open("live-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Embedding.seed())
    {:ok, _} = World.append(world, Attribute.define("body", answers: "name"))

    {:ok, _} =
      World.append(
        world,
        Embedding.declare("embedding", embeds: "body", into: "text-3-small", asks: @embed)
      )

    {:ok, _} =
      World.append(world, [
        {"outage", "body", "the database server is down and nobody can log in"},
        {"alike", "body", "our postgres cluster is unreachable, total outage"},
        {"unlike", "body", "could you change the button colour to blue please"}
      ])

    work = Embedding.work(Snapshot.open([world]), "embedding")

    {:ok, _} =
      World.append(
        world,
        work.(Snapshot.open([world])) |> Enum.map(fn {id, f, v} -> {id, f, v, "embedding"} end)
      )

    snapshot = Snapshot.open([world])
    query = Snapshot.value(snapshot, "outage", "embedding")

    scores =
      snapshot
      |> Symbol.nearest("embedding", query, 3)
      |> Map.new(fn {fact, score} -> {fact.id, score} end)

    # The whole claim, checked against a real model: semantic nearness is
    # nearness. Nothing here is an index; it is one pass and exact.
    assert scores["outage"] > 0.99
    assert scores["alike"] > scores["unlike"]
  end
end
