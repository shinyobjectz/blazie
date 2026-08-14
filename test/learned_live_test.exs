defmodule Blazie.Formula.LearnedLiveTest do
  @moduledoc """
  The whole learning loop, against a live model: a run keeps calling a tool,
  the calls are harvested as examples, a model writes the formula, the
  verifier runs it against every example in a scratch world, and the
  adopted source answers what the tool answered — without the network.

  This is the loop the promise ledger flagged: every piece was tested alone
  and the composition had never run end to end against a hosted model. Now
  it has, and this is the proof. `mix test --include live`.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Formula, Snapshot, World}
  alias Blazie.Formula.{Generated, Learned}
  alias Blazie.Job.Runner

  @moduletag :live
  @moduletag timeout: 180_000

  @asks "openrouter:anthropic/claude-haiku-4.5"

  test "harvest, author, verify, adopt — and the call becomes a computation" do
    name = "learnlive-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++
          Attribute.requires_seed() ++
          Generated.seed() ++ Blazie.Tool.seed() ++ Blazie.Job.seed()
      )

    {:ok, _} = World.append(world, Attribute.define("plan", answers: "name"))
    {:ok, _} = World.append(world, Attribute.define("tier", answers: "name"))

    # A run that asked the same tool the same shapes of question, as
    # `converse/5` records them: the trajectory that IS the specification.
    calls =
      for {tier, plan} <- [{"free", "starter"}, {"pro", "growth"}, {"team", "scale"}] do
        {"run-7", "called",
         %{"tool" => "plan_of", "arguments" => %{"tier" => tier}, "answered" => plan}, "run-7"}
      end

    {:ok, _} = World.append(world, calls)

    # Harvested — evidence only, never a body — and declared.
    assert {:ok, declaring} =
             Learned.harvest(Snapshot.open([world]), "run-7", "plan_of",
               produces: "plan",
               given: ["tier"]
             )

    {:ok, _} = World.append(world, declaring)

    # The author writes the body against the live model; the verifier runs
    # it against every example in a scratch world before anything lands.
    write = Generated.author(Snapshot.open([world]), asks: @asks)

    adopted =
      Enum.reduce_while(1..3, nil, fn attempt, _ ->
        facts = write.(Snapshot.open([world]), attempt)
        {:ok, _} = World.append(world, facts)

        if Enum.any?(facts, &match?({_id, "source", _body, _by}, &1)),
          do: {:halt, :ok},
          else: {:cont, nil}
      end)

    assert adopted == :ok, "three attempts, no candidate survived the examples"

    # The learned formula answers what the tool answered — from the world,
    # with no clock and no network, which is the entire point of learning it.
    snapshot = Snapshot.open([world])
    source = Snapshot.value(snapshot, "plan_of", "source")
    assert is_binary(source)

    scratch = "learnscratch-#{System.unique_integer([:positive])}"
    {:ok, sw} = World.open(scratch)
    on_exit(fn -> World.close(scratch) end)
    {:ok, _} = World.append(sw, Attribute.seed())
    {:ok, _} = World.append(sw, Attribute.define("tier", answers: "name"))
    {:ok, _} = World.append(sw, Attribute.define("plan", answers: "name"))
    {:ok, _} = World.append(sw, [{"customer-9", "tier", "pro"}])

    {:ok, _value, staged} =
      Blazie.Lua.Binding.run(source, Snapshot.open([sw]), as: :formula, at: 0)

    assert {"customer-9", "plan", "growth"} in Enum.map(staged, fn {id, field, value} ->
             {id, field, value}
           end)

    _ = Runner
    _ = Formula
  end
end
