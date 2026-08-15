defmodule Blazie.IndexNativeTest do
  @moduledoc """
  The built-in index, production-worthy — what "eliminate the vendor" hides.

  Deleting a vendor module is an hour; the real task is that the exact index
  must be trustworthy without one. Three properties, each previously untrue:
  the holder that owns every ETS table is SUPERVISED (it was an unlinked
  Agent started by whoever touched an index first — a crash silently emptied
  every space and searches answered [] instead of erroring); the provider is
  CONFIGURED by default (nothing set `:blazie, :index`, so production raised);
  and a killed index comes back from the facts, because derived-and-disposable
  is only true if the maintaining job actually rebuilds it — asked here across
  a holder death, which is the restart case a node lives through.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Index, Job, Snapshot, Symbol, World, TestLedger}
  alias Blazie.Job.Runner

  setup do
    world = TestLedger.open()

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++ Index.seed() ++ Symbol.seed() ++ Job.seed() ++ Index.job_seed()
      )

    %{world: world, prefix: "native#{System.unique_integer([:positive])}_"}
  end

  test "the holder is supervised: alive at boot, and back after a kill" do
    pid = Process.whereis(Blazie.Index.Exact.Holder)
    assert is_pid(pid), "the Exact holder is not in the supervision tree"

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # The supervisor brings it back; nobody has to touch an index first.
    revived =
      Enum.reduce_while(1..200, nil, fn _, _ ->
        case Process.whereis(Blazie.Index.Exact.Holder) do
          nil -> {:cont, Process.sleep(5)}
          new -> {:halt, new}
        end
      end)

    assert is_pid(revived) and revived != pid
  end

  test "the index is configured by default — nearest works with no provider opt", %{
    world: world,
    prefix: prefix
  } do
    assert {Index.Exact, _} = Application.get_env(:blazie, :index)

    space = "#{prefix}cfg"
    {:ok, _} = World.append(world, Index.declare(space, "retrieval"))
    :ok = Index.Exact.upsert([], space, [{"a", [1.0, 0.0], %{}}])

    snapshot = Snapshot.open([world])
    query = Symbol.new(space, [1.0, 0.0])

    # No provider: passed — the configured default answers.
    assert {:ok, [{"a", _score}]} = Index.nearest(snapshot, space, query, 1)
    :ok = Index.Exact.drop([], space)
  end

  test "a dead index comes back from the facts — the maintaining job rebuilds", %{
    world: world,
    prefix: prefix
  } do
    space = "#{prefix}rebuild"
    {:ok, _} = World.append(world, Index.declare(space, "retrieval"))
    {:ok, _} = World.append(world, Attribute.define("embedding", answers: "any"))
    {:ok, _} = World.append(world, Job.declare("rebuilder", every: 3_600))
    {:ok, _} = World.append(world, [{"item-1", "embedding", Symbol.new(space, [1.0, 0.0])}])

    provider = {Index.Exact, prefix: prefix}

    runner =
      start_supervised!(
        {Runner,
         world: world,
         jobs: [Index.job("rebuilder", "embedding", provider: provider)],
         name: :"native_#{System.unique_integer([:positive])}"}
      )

    {:ok, _} = Runner.tick(runner, 1_000)
    settle(runner)
    {:ok, [{"item-1", _}]} = Index.Exact.search([prefix: prefix], space, [1.0, 0.0], 1, %{})

    # The node "restarts": the holder dies and every table with it.
    holder = Process.whereis(Blazie.Index.Exact.Holder)
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}
    assert {:ok, []} = Index.Exact.search([prefix: prefix], space, [1.0, 0.0], 1, %{})

    # A new symbol lands; the job's read set makes it due; the WHOLE space
    # comes back — not just the new symbol — because the job reads every
    # symbol under the attribute.
    {:ok, _} = World.append(world, [{"item-2", "embedding", Symbol.new(space, [0.0, 1.0])}])
    {:ok, _} = Runner.tick(runner, 1_020)
    settle(runner)

    {:ok, [{"item-1", _}]} = Index.Exact.search([prefix: prefix], space, [1.0, 0.0], 1, %{})
    {:ok, [{"item-2", _}]} = Index.Exact.search([prefix: prefix], space, [0.0, 1.0], 1, %{})
  end

  defp settle(runner) do
    Enum.reduce_while(1..400, nil, fn _, _ ->
      if Runner.in_flight(runner) == [], do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
    end)
  end
end
