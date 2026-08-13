defmodule Blazie.CompactionTest do
  @moduledoc """
  Replay was O(everything ever written).

  What compaction is allowed to be here is narrow, and the doctrine draws the
  line: nothing is rewritten, and the only destruction is erasure. So this
  cannot drop superseded facts — an old name would start answering differently,
  which is the one guarantee everything else rests on.

  It is a checkpoint instead. History stays whole; opening stops re-reading it
  record by record.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Ledger, Snapshot, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "blazie_compact_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: {:compact, System.unique_integer([:positive])}}
  end

  defp on_disk(name, dir, opts \\ []) do
    {:ok, ledger} = Ledger.open(name, store: {Store.File, [dir: dir] ++ opts})
    ledger
  end

  defp write(ledger, range) do
    for n <- range, do: {:ok, _} = Ledger.append(ledger, [{n, "height", n}])
  end

  defp time_appends(ledger, range) do
    started = System.monotonic_time(:microsecond)
    write(ledger, range)
    div(System.monotonic_time(:microsecond) - started, Enum.count(range))
  end

  describe "a checkpoint does not lose anything" do
    test "every fact is still there after reopening", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 20)
      write(ledger, 1..100)
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir, checkpoint_every: 20)
      assert length(Snapshot.find(Snapshot.open([reopened]), attribute: "height")) == 100
      assert Ledger.tx(reopened) == 100

      Ledger.close(ctx.name)
    end

    test "a superseded fact survives, because nothing is rewritten", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 5)
      for v <- [1, 2, 3], do: {:ok, _} = Ledger.append(ledger, [{42, "height", v}])
      # Deliberately clear of 42 — writing it again here would be a fourth fact
      # about the same entity, not a duplicate.
      write(ledger, 100..150)
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir, checkpoint_every: 5)
      snapshot = Snapshot.open([reopened])

      assert length(Snapshot.find(snapshot, id: 42, attribute: "height")) == 3
      assert Snapshot.value(snapshot, 42, "height") == 3

      Ledger.close(ctx.name)
    end

    test "an old transaction still answers what it always answered", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 10)
      write(ledger, 1..10)
      early = Snapshot.open([ledger])

      write(ledger, 11..100)
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir, checkpoint_every: 10)
      # Same transaction, after a reopen that went through a checkpoint.
      at_ten = Snapshot.reopen(%{reopened => 10})

      assert length(Snapshot.find(early, attribute: "height")) == 10
      assert length(Snapshot.find(at_ten, attribute: "height")) == 10

      Ledger.close(ctx.name)
    end
  end

  describe "keeping checkpoints does not cost more the longer you run" do
    # The bug this pins down: a checkpoint writes every fact again, so writing
    # one on a fixed count of transactions made the cost of keeping them grow
    # with history. Sixteen thousand single-fact appends wrote about 136MB of
    # checkpoints to keep 1.7MB of facts, and per-append cost doubled with every
    # doubling of the log — 8.6µs at two thousand facts, 47.2µs at sixteen
    # thousand. It was getting worse on the running box by the hour.
    #
    # etcd shipped this same design and ran it ten months, because on a single
    # node the symptom is invisible: nothing is wrong, it is only slow, and it
    # is only slow later.
    test "checkpoints fall geometrically further apart", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 10)
      write(ledger, 1..2_000)

      stats = Ledger.store_stats(ledger)

      # On the old policy this was exactly 200 — one per ten transactions,
      # each rewriting everything. Geometric spacing puts it near log(n).
      assert stats.checkpoints_written < 25,
             "wrote #{stats.checkpoints_written} checkpoints for 2000 appends"

      assert stats.checkpoints_written > 0, "wrote none at all, which proves nothing"

      Ledger.close(ctx.name)
    end

    test "and the tail left unwritten stays a bounded fraction of the log", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 10)
      write(ledger, 1..2_000)

      stats = Ledger.store_stats(ledger)
      tail = stats.bytes - stats.checkpoint_bytes

      # Whatever is not in the checkpoint is what a reopen must scan. The point
      # of amortising is that this stays a fraction rather than growing.
      assert tail <= stats.bytes * 0.6,
             "tail is #{tail} of #{stats.bytes} bytes, which a reopen would have to scan"

      Ledger.close(ctx.name)
    end

    test "a longer log does not cost more per append", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 50)

      write(ledger, 1..2_000)
      early = time_appends(ledger, 2_001..3_000)

      write(ledger, 3_001..12_000)
      late = time_appends(ledger, 12_001..13_000)

      # Quadratic put this near 6x. A generous bound: the fix measured flat,
      # so anything under 3x is a comfortable pass and a real regression still
      # fails. Timing in a test is a blunt instrument, which is why the
      # deterministic checkpoint count above is the primary guard.
      assert late < early * 3,
             "appending after 12k facts took #{late}µs vs #{early}µs after 2k — cost is growing with history"

      Ledger.close(ctx.name)
    end
  end

  describe "the order facts come back in" do
    test "replay is oldest first, whatever the store does internally", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 7)
      write(ledger, 1..40)
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir, checkpoint_every: 7)
      found = Snapshot.find(Snapshot.open([reopened]), attribute: "height")

      # The store keeps its facts newest-first so appending is cheap. That is an
      # implementation detail and must not reach an answer.
      assert Enum.map(found, & &1.value) == Enum.to_list(1..40)
      assert Enum.map(found, & &1.tx) == Enum.sort(Enum.map(found, & &1.tx))

      Ledger.close(ctx.name)
    end
  end

  describe "opening stops re-reading the whole log" do
    test "a checkpointed reopen reads far fewer records", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 200)
      write(ledger, 1..500)
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir, checkpoint_every: 200)
      stats = Ledger.store_stats(reopened)

      assert stats.checkpoint_at > 0
      assert stats.records_scanned < 200, "scanned #{stats.records_scanned} records"

      Ledger.close(ctx.name)
    end

    test "with no checkpoint it reads everything, as it always did", ctx do
      ledger = on_disk(ctx.name, ctx.dir)
      write(ledger, 1..50)
      :ok = Ledger.close(ctx.name)

      reopened = on_disk(ctx.name, ctx.dir)
      stats = Ledger.store_stats(reopened)

      assert stats.checkpoint_at == 0
      assert stats.records_scanned == 50

      Ledger.close(ctx.name)
    end
  end

  describe "a checkpoint does not break recovery" do
    test "a torn tail after a checkpoint still loses only the torn write", ctx do
      ledger = on_disk(ctx.name, ctx.dir, checkpoint_every: 10)
      write(ledger, 1..30)
      :ok = Ledger.close(ctx.name)

      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      File.write!(path, <<999_999::32, 0::32, "half a record">>, [:append])

      reopened = on_disk(ctx.name, ctx.dir, checkpoint_every: 10)

      assert Ledger.tx(reopened) == 30
      assert length(Snapshot.find(Snapshot.open([reopened]), attribute: "height")) == 30

      Ledger.close(ctx.name)
    end
  end
end
