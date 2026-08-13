defmodule LogiTest do
  @moduledoc """
  The model call, and the agent that is declared rather than written.

  Nothing here reaches a provider. What is worth testing is the seams — that a
  declaration becomes a schema, that a work list is derived rather than kept,
  and that a prompt is assembled from things that already exist so it cannot
  drift from them.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Snapshot, World}
  alias Logi.{Agent, Model, Schema}

  setup do
    name = "logi-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Attribute.requires_seed() ++ Agent.seed())
    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  describe "a model reference" do
    test "is one string, parsed" do
      assert {:ok, %Model{provider: :openai, name: "gpt-4o-mini"}} = Model.from("openai:gpt-4o-mini")
    end

    test "an unknown provider says which are known" do
      assert {:error, refusal} = Model.from("nope:x")
      assert refusal.repair =~ "anthropic, openai"
    end

    test "a provider name from outside cannot mint an atom" do
      # `to_existing_atom` guards this: an atom is never collected, so a
      # provider taken from a request would be a way to exhaust the table.
      assert {:error, _} = Model.from("definitely_not_a_provider_#{System.unique_integer()}:x")
    end
  end

  describe "a declaration becomes the shape asked for" do
    test "a bare answers is wrapped, because a provider wants an object" do
      assert %{"properties" => %{"value" => %{"type" => "integer"}}} = Schema.json(answers: "integer")
    end

    test "the four shapes blazie can decide map across" do
      for {answers, json} <- [
            {"integer", "integer"},
            {"number", "number"},
            {"boolean", "boolean"},
            {"name", "string"}
          ] do
        assert %{"properties" => %{"value" => %{"type" => ^json}}} = Schema.json(answers: answers)
      end
    end

    test "a shape nothing can decide is permissive rather than impossible" do
      # `answers: "email"` is a name the engine cannot evaluate. A value cannot
      # contradict a shape nobody can decide, so this is permissive here for the
      # same reason `Attribute.satisfies?/2` is permissive there.
      assert %{"properties" => %{"value" => shape}} = Schema.json(answers: "email")
      refute Map.has_key?(shape, "type")
    end
  end

  describe "an agent is declared, not written" do
    setup %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("body", answers: "name"))

      {:ok, _} =
        World.append(
          world,
          Agent.declare("severity",
            produces: "ticket",
            watches: ["body"],
            asks: "openai:gpt-4o-mini",
            answers: "name",
            describe: "low, medium or high"
          )
        )

      :ok
    end

    test "what it watches is what it said", %{world: world} do
      assert Agent.watches(snapshot(world), "severity") == ["body"]
    end

    test "an entity with the watched field and no answer is due", %{world: world} do
      {:ok, _} = World.append(world, [{"t1", "body", "the server is on fire"}])

      assert Agent.due(snapshot(world), "severity") == ["t1"]
    end

    test "one that has been answered is not due again", %{world: world} do
      {:ok, _} = World.append(world, [{"t1", "body", "hello"}])
      {:ok, _} = World.append(world, [{"t1", "severity", "low", "severity"}])

      assert Agent.due(snapshot(world), "severity") == []
    end

    test "it goes stale when what it watches changes", %{world: world} do
      {:ok, _} = World.append(world, [{"t1", "body", "hello"}])
      {:ok, _} = World.append(world, [{"t1", "severity", "low", "severity"}])
      assert Agent.due(snapshot(world), "severity") == []

      # The whole point: a correction upstream makes the answer stale, and
      # nothing had to be enqueued or invalidated for that to be true.
      {:ok, _} = World.append(world, [{"t1", "body", "the server is on fire"}])
      assert Agent.due(snapshot(world), "severity") == ["t1"]
    end

    test "an entity missing what it watches is not due", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("colour"))
      {:ok, _} = World.append(world, [{"t2", "colour", "blue"}])

      assert Agent.due(snapshot(world), "severity") == []
    end

    test "the work list is derived, so nothing has to be kept in step", %{world: world} do
      {:ok, _} = World.append(world, [{"t1", "body", "a"}, {"t2", "body", "b"}])
      assert Agent.due(snapshot(world), "severity") == ["t1", "t2"]

      {:ok, _} = World.append(world, [{"t1", "severity", "low", "severity"}])
      assert Agent.due(snapshot(world), "severity") == ["t2"]
    end
  end

  describe "the prompt is assembled" do
    test "from the declaration and the watched values, and nothing else", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("body", answers: "name"))
      {:ok, _} = World.append(world, Attribute.define("secret", answers: "name"))

      {:ok, _} =
        World.append(
          world,
          Agent.declare("severity",
            produces: "ticket",
            watches: ["body"],
            asks: "openai:gpt-4o-mini",
            answers: "name",
            describe: "low, medium or high"
          )
        )

      {:ok, _} =
        World.append(world, [{"t1", "body", "on fire"}, {"t1", "secret", "do not send this"}])

      asked = Agent.asking(snapshot(world), "severity", "t1")

      assert asked =~ "severity"
      assert asked =~ "low, medium or high"
      assert asked =~ "on fire"

      # What an agent may see is decided where it can be read, not by what it
      # managed to reach. `secret` is not watched, so it is not in the ask.
      refute asked =~ "do not send this"
    end
  end
end
