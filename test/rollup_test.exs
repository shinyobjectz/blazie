defmodule Blazie.RollupTest do
  @moduledoc """
  The winning query shape, kept honest: the projection answers instantly,
  updates when the readings change, and a reading landing after maintenance
  is not silently missing — the job is due again because it read them.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Job, Rollup, Snapshot, TestLedger, World}
  alias Blazie.Job.Runner

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Job.seed() ++ Rollup.seed())
    {:ok, _} = World.append(world, Attribute.define("platform", answers: "name"))
    {:ok, _} = World.append(world, Attribute.define("impressions", answers: "integer"))
    {:ok, _} = World.append(world, Job.declare("agg", every: 3_600))
    %{world: world}
  end

  defp reading(world, n, platform, impressions) do
    {:ok, _} =
      World.append(world, [
        {"r-#{n}", "platform", platform},
        {"r-#{n}", "impressions", impressions}
      ])
  end

  defp settle(runner) do
    Enum.reduce_while(1..400, nil, fn _, _ ->
      if Runner.in_flight(runner) == [], do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
    end)
  end

  test "totals project, re-fire on new readings, and answer as a point read", %{world: world} do
    reading(world, 1, "bluesky", 100)
    reading(world, 2, "bluesky", 50)
    reading(world, 3, "youtube", 30)

    runner =
      start_supervised!(
        {Runner,
         world: world,
         jobs: [Rollup.job("agg", "impressions", ["platform"])],
         name: :"roll_#{System.unique_integer([:positive])}"}
      )

    {:ok, ["agg"]} = Runner.tick(runner, 1_000)
    settle(runner)

    assert Rollup.total(Snapshot.open([world]), "impressions", ["bluesky"]) == 150
    assert Rollup.total(Snapshot.open([world]), "impressions", ["youtube"]) == 30

    # Quiet until a reading lands — then due again, inside the cadence,
    # because the job READ the readings. The Hints property, reused.
    assert {:ok, []} = Runner.tick(runner, 1_010)

    reading(world, 4, "bluesky", 25)
    assert {:ok, ["agg"]} = Runner.tick(runner, 1_020)
    settle(runner)

    assert Rollup.total(Snapshot.open([world]), "impressions", ["bluesky"]) == 175
  end
end
