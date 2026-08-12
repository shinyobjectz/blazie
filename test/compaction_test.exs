defmodule LazyRiver.CompactionTest do
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

  alias LazyRiver.{Ledger, Snapshot, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "lazyriver_compact_#{System.unique_integer([:positive])}")
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
      assert Snapshot.answer(snapshot, 42, "height") == 3

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
