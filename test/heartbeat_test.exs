defmodule Blazie.HeartbeatTest do
  @moduledoc """
  A run that stopped is picked up by declared work, not by a person noticing.

  The pieces this leans on are each already true: a run that spent its
  stretches has no `ended`, its task is a fact, and the runner ticks whatever
  the world says is due. What is asserted here is the joint: that a stalled
  run is found, continued from its own record, and finished — and that the
  bounds hold, because a heartbeat without bounds is a bill arriving on a
  cadence.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Coding, Job, Model, Run, Snapshot, Spend, Tool, World}
  alias Blazie.Job.Runner

  setup do
    {:ok, world} = World.open("heartbeat-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++
          Spend.seed() ++
          Model.seed() ++
          Run.seed() ++
          Tool.seed() ++
          Job.seed() ++
          Coding.seed()
      )

    {:ok, _} = World.append(world, Coding.declare("coder"))
    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  # A model that only ever calls a tool — it exhausts any call budget and the
  # run stops rather than ends.
  defp stalling(_r, _m, _t, _o),
    do: {:ok, {:calls, [%{id: "c", name: "list", arguments: %{}}]}, %{in: 1, out: 1}}

  defp answering(_r, _m, _t, _o), do: {:ok, {:said, "all done"}, %{in: 1, out: 1}}

  describe "a run records enough to be continued" do
    test "the task is a fact, and ending is earned", %{world: world} do
      {:ok, "out of stretches", _} =
        Coding.work(world, "r", "polish the widget",
          asks: "openai:x",
          provider: &stalling/4,
          calls: 1,
          stretches: 1
        )

      at = snapshot(world)
      assert Snapshot.value(at, "r", "task") == "polish the widget"
      assert Snapshot.value(at, "r", "ended") == nil
    end

    test "a run that answers is ended, and is nobody's business after", %{world: world} do
      {:ok, "all done", _} =
        Coding.work(world, "r", "say hello", asks: "openai:x", provider: &answering/4)

      at = snapshot(world)
      assert is_integer(Snapshot.value(at, "r", "ended"))
      assert Coding.stalled(at, Snapshot.value(at, "r", "began") + 9_999) == []
    end
  end

  describe "what counts as stalled" do
    test "stopped, tasked, parentless and rested — and only that", %{world: world} do
      now = 1_000_000

      # The one that should be picked up.
      {:ok, _} = Run.begin(world, "stopped", now - 400)
      {:ok, _} = World.append(world, [{"stopped", "task", "carry on", "stopped"}])

      # Ended: not stalled, however old.
      {:ok, _} = Run.begin(world, "finished", now - 400)
      {:ok, _} = World.append(world, [{"finished", "task", "was done", "finished"}])
      {:ok, _} = Run.finish(world, "finished", now - 300)

      # A delegation: its parent already took whatever answer there was.
      {:ok, _} = Run.begin(world, "child", now - 400)

      {:ok, _} =
        World.append(world, [
          {"child", "task", "sub-work", "child"},
          {"child", "asked_by", "stopped", "child"}
        ])

      # No task on record: nothing to continue it toward.
      {:ok, _} = Run.begin(world, "taskless", now - 400)

      # Still warm: it moved more recently than `rest`.
      {:ok, _} = Run.begin(world, "warm", now - 10)
      {:ok, _} = World.append(world, [{"warm", "task", "still going", "warm"}])

      assert Coding.stalled(snapshot(world), now, rest: 300) == ["stopped"]
    end

    test "a resume resets the clock, and enough of them end the matter", %{world: world} do
      now = 1_000_000

      # Resumed recently: rested-ness is measured from the resume, not the birth.
      {:ok, _} = Run.begin(world, "r", now - 900)
      {:ok, _} = World.append(world, [{"r", "task", "carry on", "r"}])
      {:ok, _} = World.append(world, [{"r", "resumed", now - 10, "r"}])
      assert Coding.stalled(snapshot(world), now, rest: 300) == []

      # Three resumes, all long rested — so only the count can say no, and it
      # does: a third resume is the last one anybody pays for.
      {:ok, _} = Run.begin(world, "s", now - 900)
      {:ok, _} = World.append(world, [{"s", "task", "still at it", "s"}])

      for at <- [now - 850, now - 800, now - 700] do
        {:ok, _} = World.append(world, [{"s", "resumed", at, "s"}])
      end

      assert Coding.stalled(snapshot(world), now, rest: 300, most: 3) == []
      assert Coding.stalled(snapshot(world), now, rest: 300, most: 5) == ["s"]
    end
  end

  describe "continuing is reading, then working" do
    test "picks the task off the record and finishes what it starts", %{world: world} do
      {:ok, "out of stretches", _} =
        Coding.work(world, "r", "finish the thing",
          asks: "openai:x",
          provider: &stalling/4,
          calls: 1,
          stretches: 1
        )

      assert {:ok, "all done", _} =
               Coding.continue(world, "r", asks: "openai:x", provider: &answering/4)

      at = snapshot(world)
      assert is_integer(Snapshot.value(at, "r", "ended"))
      # The resume is on the record, so "what continued this" is a query.
      assert [_] = Snapshot.find(at, id: "r", attribute: "resumed")
    end

    test "a run that never had a task is refused with the reason", %{world: world} do
      {:ok, _} = Run.begin(world, "bare")

      assert {:error, %{problem: :no_task, repair: repair}} =
               Coding.continue(world, "bare", asks: "openai:x", provider: &answering/4)

      assert repair =~ "never recorded a task"
    end
  end

  describe "the heartbeat is a job, and the runner is the pulse" do
    test "a stalled run is continued by a tick and nothing else", %{world: world} do
      {:ok, "out of stretches", _} =
        Coding.work(world, "r", "carry this over",
          asks: "openai:x",
          provider: &stalling/4,
          calls: 1,
          stretches: 1
        )

      {:ok, _} = World.append(world, Job.declare("heartbeat", every: 60))

      runner =
        start_supervised!(
          {Runner,
           world: world,
           jobs: [Coding.heartbeat(world, asks: "openai:x", provider: &answering/4, rest: 0)],
           name: :"beat_#{System.unique_integer([:positive])}"}
        )

      assert {:ok, ["heartbeat"]} = Runner.tick(runner, System.system_time(:second))

      Enum.reduce_while(1..200, nil, fn _, _ ->
        if Runner.in_flight(runner) == [], do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
      end)

      at = snapshot(world)
      assert is_integer(Snapshot.value(at, "r", "ended"))
      # The job ran and said so, the way every job does.
      assert Job.last_run(at, "heartbeat") != nil
    end

    test "a continuation that fails becomes a failed fact, not silence", %{world: world} do
      now = 1_000_000
      {:ok, _} = Run.begin(world, "r", now - 900)
      {:ok, _} = World.append(world, [{"r", "task", "doomed", "r"}])

      refusing = fn _r, _m, _t, _o ->
        {:error, %{problem: :refused, repair: "the provider is down for the demonstration"}}
      end

      job = Coding.heartbeat(world, asks: "openai:x", provider: refusing, rest: 0)
      {:ok, _} = Job.run(job, world, snapshot(world), now)

      # On the RUN, where Refinement.triggers/2 reads — a heartbeat hitting the
      # same wall twice becomes a trigger rather than a quiet loop.
      failures = snapshot(world) |> Snapshot.find(id: "r", attribute: "failed")
      assert Enum.any?(failures, &(&1.value =~ "down for the demonstration"))
    end
  end
end
