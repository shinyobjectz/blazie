defmodule Blazie.VitalsTest do
  @moduledoc """
  Observability is facts, which means it is a job.

  Reading the clock, the VM, or how many ledgers are open is reaching outside —
  the answer depends on when you ask. So vitals cannot be a formula, and being
  a job is not a workaround: it is the same line everything else obeys, and it
  buys the whole ledger's machinery for free. Vitals have provenance, a
  cadence, failure records, and history, without any of it being built twice.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Job, Ledger, Snapshot, TestLedger, Vitals}

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed() ++ Job.seed() ++ Vitals.seed())
    %{ledger: ledger}
  end

  describe "vitals are facts" do
    test "taking them writes facts naming the job", %{ledger: ledger} do
      {:ok, tx} = Job.run(Vitals.job(), ledger, Snapshot.open([ledger]), 1000)

      written = Ledger.facts_at(ledger, tx) |> Enum.filter(&(&1.tx == tx))

      assert written != []
      assert Enum.all?(written, &(&1.by == "vitals"))
    end

    test "they answer like anything else", %{ledger: ledger} do
      {:ok, _} = Job.run(Vitals.job(), ledger, Snapshot.open([ledger]), 1000)
      snapshot = Snapshot.open([ledger])

      assert is_integer(Snapshot.value(snapshot, "vitals", "open_ledgers"))
      assert is_integer(Snapshot.value(snapshot, "vitals", "memory_bytes"))
      assert is_binary(Snapshot.value(snapshot, "vitals", "node"))
    end

    test "taking them twice keeps both, so a trend is a query", %{ledger: ledger} do
      {:ok, _} = Job.run(Vitals.job(), ledger, Snapshot.open([ledger]), 1000)
      {:ok, _} = Job.run(Vitals.job(), ledger, Snapshot.open([ledger]), 2000)

      snapshot = Snapshot.open([ledger])
      readings = Snapshot.find(snapshot, id: "vitals", attribute: "memory_bytes")

      assert length(readings) == 2
      assert Enum.map(readings, & &1.tx) == Enum.sort(Enum.map(readings, & &1.tx))
    end
  end

  describe "it is a job, with everything that follows" do
    test "it has a cadence, and the runner picks it up", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Vitals.declare(every: 60))

      assert Job.due?(Snapshot.open([ledger]), "vitals", 0)

      runner =
        start_supervised!(
          {Job.Runner,
           ledger: ledger,
           jobs: [Vitals.job()],
           name: :"vitals_#{System.unique_integer([:positive])}"}
        )

      assert {:ok, ["vitals"]} = Job.Runner.tick(runner, 1000)
    end

    test "when it last ran is answerable, like any job", %{ledger: ledger} do
      {:ok, _} = Job.run(Vitals.job(), ledger, Snapshot.open([ledger]), 1000)

      assert Job.last_run(Snapshot.open([ledger]), "vitals") == 1000
    end
  end

  describe "the reading is of a moment, not of forever" do
    test "each reading is its own transaction, and the latest wins", %{ledger: ledger} do
      # Deliberately not comparing counts across readings: open_ledgers is
      # VM-wide and other async tests are opening and closing their own, so an
      # exact comparison measures the whole suite rather than this test.
      {:ok, first} = Job.run(Vitals.job(), ledger, Snapshot.open([ledger]), 1000)
      {:ok, second} = Job.run(Vitals.job(), ledger, Snapshot.open([ledger]), 2000)

      assert second > first

      snapshot = Snapshot.open([ledger])
      readings = Snapshot.find(snapshot, id: "vitals", attribute: "open_ledgers")

      assert length(readings) == 2
      assert Enum.map(readings, & &1.tx) == [first, second]
      assert Snapshot.value(snapshot, "vitals", "open_ledgers") == List.last(readings).value
    end

    test "a reading reflects a live system", %{ledger: ledger} do
      {:ok, _} = Job.run(Vitals.job(), ledger, Snapshot.open([ledger]), 1000)
      snapshot = Snapshot.open([ledger])

      # Our own ledger is open, so this cannot be zero however busy the suite is.
      assert Snapshot.value(snapshot, "vitals", "open_ledgers") >= 1
      assert Snapshot.value(snapshot, "vitals", "processes") > 0
      assert Snapshot.value(snapshot, "vitals", "memory_bytes") > 0
    end
  end
end
