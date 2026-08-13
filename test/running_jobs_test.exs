defmodule LazyRiver.RunningJobsTest do
  @moduledoc """
  Jobs that are built and never started are jobs that do not run.

  This exists because the deployment kept finding the same shape of bug: a
  component written, tested, configured — and absent from the supervision tree,
  so production had none of it. A ledger with no store, a job runner nobody
  started. The test is whether the thing is *running*, not whether it exists.
  """
  use ExUnit.Case, async: false

  alias LazyRiver.{Attribute, Job, Ledger, Snapshot, Vitals}

  test "the vitals job is running and taking readings" do
    assert pid = Process.whereis(LazyRiver.Vitals.Runner),
           "nothing is running the vitals job"

    assert Process.alive?(pid)
  end

  test "its ledger is seeded, so a reading has somewhere to go" do
    {:ok, ledger} = Ledger.open(Vitals.ledger())
    snapshot = Snapshot.open([ledger])

    assert Attribute.defined?(snapshot, "open_ledgers")
    assert Attribute.defined?(snapshot, "every")
  end

  test "vitals is declared as a job with a cadence" do
    {:ok, ledger} = Ledger.open(Vitals.ledger())
    snapshot = Snapshot.open([ledger])

    assert Snapshot.answer(snapshot, "vitals", "is") == "job"
    assert is_integer(Snapshot.answer(snapshot, "vitals", "every"))
  end

  test "ticking the running runner actually writes a reading" do
    {:ok, ledger} = Ledger.open(Vitals.ledger())
    before = length(Snapshot.find(Snapshot.open([ledger]), id: "vitals", attribute: "node"))

    {:ok, ran} = Job.Runner.tick(LazyRiver.Vitals.Runner, System.system_time(:second) + 100_000)
    assert "vitals" in ran

    Enum.reduce_while(1..100, nil, fn _, _ ->
      now = length(Snapshot.find(Snapshot.open([ledger]), id: "vitals", attribute: "node"))
      if now > before, do: {:halt, :ok}, else: {:cont, Process.sleep(20)}
    end)

    assert length(Snapshot.find(Snapshot.open([ledger]), id: "vitals", attribute: "node")) >
             before
  end
end
