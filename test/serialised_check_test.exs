defmodule LazyRiver.SerialisedCheckTest do
  @moduledoc """
  A check is only a constraint if the thing that appends runs it.

  `Ledger.append/3`'s `check:` said the ledger applied it, and that the ledger
  holding the one serialized path every write goes through was the whole reason
  the check belonged there. It ran in the caller. Two writers both passed it and
  both appended, so a check that should admit one of them admitted both.

  Found by measuring write throughput rather than by a test, which is the point:
  every existing test wrote from one process, and one process cannot race
  itself. So these tests are all about two.

  The arity is now the difference, and it is load-bearing. An arity-2 check is
  handed the ledger's own facts inside the process that appends — what it
  checked is what it wrote. An arity-1 check still runs in the caller, kept
  because wanting to know before you ask is fair, and named advisory because
  that is what it is.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Fact, Ledger, Snapshot, TestLedger}

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
    %{ledger: ledger}
  end

  # Admits a write only if nothing already claims that id for this attribute.
  # The kind of check somebody would reach for, and the kind that was broken.
  defp only_once(assertions, facts) do
    taken =
      assertions
      |> Enum.filter(fn {_id, attribute, _v} -> attribute == "height" end)
      |> Enum.filter(fn {id, _a, _v} ->
        Enum.any?(facts, &Fact.matches?(&1, id: id, attribute: "height"))
      end)

    case taken do
      [] ->
        :ok

      [{id, _, _} | _] ->
        {:error, [%{problem: :taken, repair: "#{inspect(id)} already answers."}]}
    end
  end

  describe "two writers racing one ledger" do
    test "the serialised check admits exactly one", %{ledger: ledger} do
      results =
        1..24
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Ledger.append(ledger, [{"ada", "height", 180}], check: &only_once/2)
          end)
        end)
        |> Task.await_many(10_000)

      admitted = Enum.count(results, &match?({:ok, _}, &1))
      refused = Enum.count(results, &match?({:error, _}, &1))

      assert admitted == 1, "#{admitted} writers were admitted; the check did not serialize"
      assert refused == 23

      facts = Snapshot.find(Snapshot.open([ledger]), id: "ada", attribute: "height")
      assert length(facts) == 1
    end

    test "the advisory check admits more than one, which is why it is named that",
         %{ledger: ledger} do
      # Not a bug being asserted — a contract being made honest. An arity-1
      # check runs before the call and cannot see what lands during it.
      caller_side = fn assertions ->
        only_once(assertions, Snapshot.facts(Snapshot.open([ledger])))
      end

      results =
        1..24
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Ledger.append(ledger, [{"ada", "height", 180}], check: caller_side)
          end)
        end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) >= 1
    end
  end

  describe "a check that runs where the facts live" do
    test "sees the write it is about to allow, not one from before", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, [{"ada", "height", 180}])

      saw = self()

      check = fn _assertions, facts ->
        send(saw, {:facts, length(Enum.filter(facts, &Fact.matches?(&1, attribute: "height")))})
        :ok
      end

      {:ok, _} = Ledger.append(ledger, [{"grace", "height", 175}], check: check)

      assert_receive {:facts, 1}
    end

    test "raising is a refusal, not a dead ledger", %{ledger: ledger} do
      before = Ledger.tx(ledger)

      assert {:error, [refusal]} =
               Ledger.append(ledger, [{"ada", "height", 1}], check: fn _a, _f -> raise "boom" end)

      assert refusal.problem == :check_raised
      assert refusal.repair =~ "boom"
      assert refusal.repair =~ "Nothing was written"

      # Alive, unchanged, and still writable.
      assert Ledger.tx(ledger) == before
      assert {:ok, _} = Ledger.append(ledger, [{"ada", "height", 180}])
    end

    test "throwing is too", %{ledger: ledger} do
      assert {:error, [refusal]} =
               Ledger.append(ledger, [{"ada", "height", 1}], check: fn _a, _f -> throw(:nope) end)

      assert refusal.problem == :check_raised
      assert {:ok, _} = Ledger.append(ledger, [{"ada", "height", 180}])
    end

    test "a refusal writes nothing at all", %{ledger: ledger} do
      before = Ledger.tx(ledger)

      assert {:error, _} =
               Ledger.append(ledger, [{"ada", "height", 180}],
                 check: fn _a, _f -> {:error, [%{problem: :no, repair: "no"}]} end
               )

      assert Ledger.tx(ledger) == before
      assert Snapshot.find(Snapshot.open([ledger]), attribute: "height") == []
    end
  end

  describe "the vocabulary check, serialised" do
    test "two writers cannot both narrow an attribute past the facts", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define("tags", answers: "any"))
      {:ok, _} = Ledger.append(ledger, [{"post-1", "tags", 7}])

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Ledger.append(ledger, [{"tags", "answers", "name"}], check: &Attribute.check/2)
          end)
        end)
        |> Task.await_many(10_000)

      # 7 is an integer, not a name, so every one of them must be refused —
      # and refused against the facts, not against a snapshot from before.
      assert Enum.all?(results, &match?({:error, _}, &1))
      assert Attribute.answers(Snapshot.open([ledger]), "tags") == "any"
    end

    test "an undefined attribute is still refused", %{ledger: ledger} do
      assert {:error, [refusal | _]} =
               Ledger.append(ledger, [{"ada", "undeclared", 1}], check: &Attribute.check/2)

      assert refusal.problem == :undefined
    end

    test "and a legitimate write still lands", %{ledger: ledger} do
      assert {:ok, tx} =
               Ledger.append(ledger, [{"ada", "height", 180}], check: &Attribute.check/2)

      assert Snapshot.value(Snapshot.reopen(%{Ledger.name_of(ledger) => tx}), "ada", "height") ==
               180
    end
  end
end
