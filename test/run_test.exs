defmodule Blazie.RunTest do
  @moduledoc """
  A run survives the process that made it, and can be branched.

  These are the two claims P2 rests on, and neither needed machinery: a run's
  turns are facts, so resuming is a query and forking is a snapshot. What is
  tested here is that those two sentences are actually true, because "the
  substrate gives it to us for free" is exactly the kind of claim that turns out
  to have a catch.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Model, Run, Snapshot, Spend, World}

  setup do
    {:ok, world} = World.open("run-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++ Spend.seed() ++ Model.seed() ++ Run.seed()
      )

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  defp said(answer) do
    fn _r, _m, _t, _o -> {:ok, {:said, answer}, %{in: 1, out: 1}} end
  end

  defp turn(world, id, prompt, answer) do
    {:ok, _, _} =
      Model.converse("openai:gpt-4o-mini", prompt, [], fn _ -> {:ok, %{}} end,
        provider: said(answer),
        into: world,
        by: id
      )
  end

  describe "a run outlives whatever was running it" do
    test "its turns are read back from facts, in order", %{world: world} do
      {:ok, _} = Run.begin(world, "r1")
      turn(world, "r1", "first", "one")
      turn(world, "r1", "second", "two")

      assert [%{asked: "first", answered: "one"}, %{asked: "second", answered: "two"}] =
               Run.turns(snapshot(world), "r1")
    end

    test "and come back as messages converse can be handed", %{world: world} do
      {:ok, _} = Run.begin(world, "r1")
      turn(world, "r1", "first", "one")

      messages = Run.messages(snapshot(world), "r1")

      assert [
               %{"role" => "user", "content" => "first"},
               %{"role" => "assistant", "content" => "one"}
             ] = messages

      # The proof that resuming needs nothing restored: the messages read out of
      # the world go straight back in as the prompt.
      assert {:ok, "three", _} =
               Model.converse(
                 "openai:gpt-4o-mini",
                 messages ++ [%{"role" => "user", "content" => "next"}],
                 [],
                 fn _ -> {:ok, %{}} end,
                 provider: said("three"),
                 into: world,
                 by: "r1"
               )

      assert length(Run.turns(snapshot(world), "r1")) == 2
    end

    test "a run that stopped is distinguishable from one that ended", %{world: world} do
      {:ok, _} = Run.begin(world, "stopped")
      {:ok, _} = Run.begin(world, "ended")
      {:ok, _} = Run.finish(world, "ended")

      assert Snapshot.value(snapshot(world), "ended", "ended") != nil
      assert Snapshot.value(snapshot(world), "stopped", "ended") == nil
    end
  end

  describe "a run outlives the process, and not only the loop" do
    @tag :tmp_dir
    test "its turns come back from disk after the world is closed", %{tmp_dir: dir} do
      # The stronger claim, and the one that needed checking. The tests above
      # keep a world alive for their duration, which proves the facts outlive
      # the LOOP. This closes the world — dropping the process that held it —
      # and reopens it, so what comes back came off disk.
      #
      # Measured the honest way first: run twice in two VMs with no
      # `:ledger_dir` and nothing came back, because the default store is memory
      # and every world was in it. That is not a defect in a run; it is the
      # difference between a world configured to survive and one not.
      name = "durable-#{System.unique_integer([:positive])}"
      store = {Blazie.Store.File, dir: dir}

      {:ok, world} = World.open(name, store: store)

      {:ok, _} =
        World.append(world, Attribute.seed() ++ Spend.seed() ++ Model.seed() ++ Run.seed())

      {:ok, _} = Run.begin(world, "r")
      turn(world, "r", "capital of france", "paris")
      World.close(world)

      {:ok, reopened} = World.open(name, store: store)
      on_exit(fn -> World.close(reopened) end)

      assert [%{asked: "capital of france", answered: "paris"}] =
               Run.turns(Snapshot.open([reopened]), "r")
    end
  end

  describe "forking" do
    test "the child carries where it came from and at what name", %{world: world} do
      {:ok, _} = Run.begin(world, "parent")
      turn(world, "parent", "shared", "beginning")

      at = snapshot(world)
      {:ok, _} = Run.fork(world, "child", "parent", at)

      assert Snapshot.value(snapshot(world), "child", "forked_from") == "parent"
      assert Snapshot.value(snapshot(world), "child", "forked_at") != nil
    end

    test "the parent still answers what it always answered", %{world: world} do
      {:ok, _} = Run.begin(world, "parent")
      turn(world, "parent", "shared", "beginning")

      at = snapshot(world)
      {:ok, _} = Run.fork(world, "child", "parent", at)

      turn(world, "child", "diverged", "differently")
      turn(world, "parent", "carried on", "as before")

      # Two runs that share a beginning, not two versions of one. Nothing was
      # copied to make the child and nothing overwritten to keep the parent.
      assert [%{answered: "beginning"}, %{answered: "as before"}] =
               Run.turns(snapshot(world), "parent")

      assert [%{answered: "differently"}] = Run.turns(snapshot(world), "child")
    end

    test "the parent at the fork point is unchanged by what came after", %{world: world} do
      {:ok, _} = Run.begin(world, "parent")
      turn(world, "parent", "shared", "beginning")

      at = snapshot(world)
      turn(world, "parent", "later", "afterwards")

      # The whole reason a fork needs no copy: the old name still answers.
      assert [%{answered: "beginning"}] = Run.turns(at, "parent")
      assert length(Run.turns(snapshot(world), "parent")) == 2
    end
  end

  describe "compaction" do
    test "shortens what is sent and keeps what was said", %{world: world} do
      {:ok, _} = Run.begin(world, "long")
      for n <- 1..4, do: turn(world, "long", "ask #{n}", "answer #{n}")

      assert length(Run.messages(snapshot(world), "long")) == 8

      {:ok, _} = Run.compact(world, "long", 3, "we discussed asks one to three")

      messages = Run.messages(snapshot(world), "long")

      # Three turns became one summary; the fourth is still itself.
      assert length(messages) == 3
      assert hd(messages)["content"] =~ "we discussed asks one to three"

      # And nothing was destroyed to achieve it. A compaction that deleted what
      # it summarised would be the one irreversible act in a database whose
      # claim is that corrections are later facts.
      assert length(Run.turns(snapshot(world), "long")) == 4
    end
  end

  test "every run is findable", %{world: world} do
    {:ok, _} = Run.begin(world, "a")
    {:ok, _} = Run.begin(world, "b")

    assert Enum.sort(Run.all(snapshot(world))) == ["a", "b"]
  end
end
