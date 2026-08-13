defmodule Blazie.Job.GenerativeTest do
  @moduledoc """
  A job whose answer is produced rather than fetched, and checked before it lands.

  The sampling loop is the part worth copying from Mellea and BAML, and it is
  not the interesting part — it is small on purpose. What matters here is what
  neither of those can do: the answer lands in a world, names what produced it,
  records which requirements it satisfied, and re-runs when what it READ moves.

  So the load-bearing tests are the ones about what is written and what is not.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Job, Snapshot, World}
  alias Blazie.Job.Generative

  setup do
    name = "gen-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++ Attribute.requires_seed() ++ Job.seed() ++ Generative.seed()
      )

    {:ok, _} = World.append(world, Attribute.define("score", answers: "integer"))
    {:ok, _} = World.append(world, Job.declare("guess"))

    {:ok, _} =
      World.append(world, [
        {"score", "requires", "positive"},
        {"positive", "is", "formula"},
        {"positive", "source", "return value > 0"}
      ])

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  describe "a sample that satisfies its requirements" do
    test "lands, and names the job that made it", %{world: world} do
      job = Job.new("guess", fn _snap -> [{"n", "score", 42}] end)

      assert {:ok, _tx, %{tries: 1}} = Generative.sample(job, world, snapshot(world), 1000)

      facts = Snapshot.find(snapshot(world), id: "n", attribute: "score")
      assert [%{value: 42, by: "guess"}] = facts
    end

    test "records which requirements it satisfied", %{world: world} do
      job = Job.new("guess", fn _snap -> [{"n", "score", 42}] end)
      {:ok, _tx, _} = Generative.sample(job, world, snapshot(world), 1000)

      # The thing neither Mellea nor BAML can answer later: which constraints
      # did this particular output actually pass?
      satisfied = Snapshot.find(snapshot(world), id: "n", attribute: "satisfied")
      assert [%{value: "positive"}] = satisfied
    end
  end

  describe "a sample that does not satisfy them" do
    test "is tried again, and the good one lands", %{world: world} do
      # Fails once, then succeeds — the loop's whole reason to exist.
      job =
        Job.new("guess", fn _snap, try_number ->
          if try_number == 1, do: [{"n", "score", -1}], else: [{"n", "score", 7}]
        end)

      assert {:ok, _tx, %{tries: 2}} = Generative.sample(job, world, snapshot(world), 1000)
      assert Snapshot.value(snapshot(world), "n", "score") == 7
    end

    test "the rejected sample is NOT written", %{world: world} do
      job =
        Job.new("guess", fn _snap, try_number ->
          if try_number == 1, do: [{"n", "score", -1}], else: [{"n", "score", 7}]
        end)

      {:ok, _tx, _} = Generative.sample(job, world, snapshot(world), 1000)

      scores = Snapshot.find(snapshot(world), id: "n", attribute: "score") |> Enum.map(& &1.value)

      # -1 never existed. An unchecked answer in the world is not a correction,
      # it is a lie with a timestamp — and corrections are only cheap when what
      # they correct was true when it was written.
      assert scores == [7]
    end

    test "giving up writes why, with the reasons", %{world: world} do
      job = Job.new("guess", fn _snap -> [{"n", "score", -1}] end)

      assert {:unmet, _tx, unmet} = Generative.sample(job, world, snapshot(world), 1000, tries: 2)
      assert unmet != []

      failures = Snapshot.find(snapshot(world), id: "guess", attribute: "failed")
      assert failures != [], "a job that gave up silently is a job nobody can debug"
      assert Enum.any?(failures, &(&1.value =~ "positive"))
    end

    test "and still nothing bad was written", %{world: world} do
      job = Job.new("guess", fn _snap -> [{"n", "score", -1}] end)
      {:unmet, _tx, _} = Generative.sample(job, world, snapshot(world), 1000, tries: 2)

      assert Snapshot.find(snapshot(world), id: "n", attribute: "score") == []
    end
  end

  describe "work that raises" do
    test "is a failure fact, not a crash", %{world: world} do
      job = Job.new("guess", fn _snap -> raise "the model refused" end)

      assert {:failed, _tx, reason} = Generative.sample(job, world, snapshot(world), 1000)
      assert reason =~ "refused"

      assert Snapshot.find(snapshot(world), id: "guess", attribute: "failed") != []
    end
  end

  describe "how many tries it took" do
    test "is written down, because it is what a cost looks like", %{world: world} do
      job =
        Job.new("guess", fn _snap, try_number ->
          if try_number < 3, do: [{"n", "score", -1}], else: [{"n", "score", 1}]
        end)

      {:ok, _tx, %{tries: 3}} = Generative.sample(job, world, snapshot(world), 1000)
      assert Snapshot.value(snapshot(world), "guess", "tries") == 3
    end
  end

  describe "an ordinary job" do
    test "can be sampled without being rewritten", %{world: world} do
      # Arity one, no notion of attempts. Sampling it must still work.
      job = Job.new("guess", fn _snap -> [{"n", "score", 5}] end)

      assert {:ok, _tx, %{tries: 1}} = Generative.sample(job, world, snapshot(world), 1000)
    end
  end
end
