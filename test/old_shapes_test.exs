defmodule Blazie.OldShapesTest do
  @moduledoc """
  An append-only store must read every shape it has ever written, forever.

  Nothing here is ever rewritten, so a fact recorded under an older row shape is
  still on disk and still has to answer. There is no migration that could fix
  it, because a migration is a rewrite and a rewrite is the one thing this
  database does not do.

  ## Why this file exists

  Renaming the third slot of a fact from `answer` to `value` made every ledger
  already on the production box unreadable. `term_to_binary` stores a struct's
  keys, `binary_to_term` hands them straight back, and the index then asked a
  fact from last week for a key it was never written with.

  The whole suite passed. It passed because every test wrote its facts with the
  same code that read them, so no test ever held a record older than itself. A
  deployment found it in fourteen seconds.

  So these tests write the bytes by hand, in the shape a previous version wrote
  them, and never construct them with today's struct.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Fact, Ledger, Snapshot, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "lr_shapes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: {:shapes, System.unique_integer([:positive])}}
  end

  # A fact exactly as a previous version of this code wrote it: the third slot
  # called `answer`, and no `value` key at all. Built as a bare map with the
  # struct tag so today's compiler cannot quietly correct it.
  defp older_fact(id, attribute, value, tx) do
    %{__struct__: Fact, id: id, attribute: attribute, answer: value, tx: tx, by: nil}
  end

  # A fact as the project wrote it when it was called something else. The struct
  # tag is a literal atom because that module does not exist any more — which is
  # the whole point, and why `term_to_binary` keeping it matters.
  defp renamed_fact(id, attribute, value, tx, key \\ :value) do
    Map.merge(
      %{__struct__: :"Elixir.LazyRiver.Fact", id: id, attribute: attribute, tx: tx, by: nil},
      %{key => value}
    )
  end

  defp record(facts) do
    payload = :erlang.term_to_binary(facts)
    <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  defp write_older_log(ctx, transactions) do
    path = Path.join(ctx.dir, Store.File.filename(ctx.name))
    bytes = transactions |> Enum.map(&record/1) |> IO.iodata_to_binary()
    File.write!(path, bytes)
    path
  end

  describe "a log written by an older version" do
    test "still opens", ctx do
      write_older_log(ctx, [
        [older_fact("is", "is", "attribute", 1)],
        [older_fact("height", "is", "attribute", 2)]
      ])

      {:ok, store} = Store.File.open(ctx.name, dir: ctx.dir)
      facts = Store.File.replay(store)
      Store.File.close(store)

      assert length(facts) == 2
      assert Enum.all?(facts, &match?(%Fact{}, &1))
    end

    test "and every fact answers under the name it has now", ctx do
      write_older_log(ctx, [[older_fact("ada", "height", 180, 1)]])

      {:ok, store} = Store.File.open(ctx.name, dir: ctx.dir)
      [fact] = Store.File.replay(store)
      Store.File.close(store)

      assert fact.value == 180
      assert fact.id == "ada"
      assert fact.attribute == "height"
      refute Map.has_key?(fact, :answer)
    end

    test "a whole ledger of them opens and can be asked", ctx do
      write_older_log(ctx, [
        [older_fact("is", "is", "attribute", 1)],
        [older_fact("height", "is", "attribute", 2)],
        [older_fact("ada", "height", 180, 3)],
        [older_fact("grace", "height", 175, 4)]
      ])

      {:ok, ledger} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.dir})
      on_exit(fn -> Ledger.close(ctx.name) end)

      snapshot = Snapshot.open([ledger])
      assert Snapshot.value(snapshot, "ada", "height") == 180
      assert length(Snapshot.find(snapshot, attribute: "height")) == 2
    end

    test "the index is built over them, so a value lookup works", ctx do
      write_older_log(ctx, [
        [older_fact("is", "is", "attribute", 1)],
        [older_fact("ada", "height", 180, 2)]
      ])

      {:ok, ledger} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.dir})
      on_exit(fn -> Ledger.close(ctx.name) end)

      # The badkey crash that took production down came from the index, which
      # reads the third slot of every fact as it is built.
      assert [%Fact{id: "ada"}] = Ledger.find_at(ledger, 2, value: 180)
    end

    test "and writing to it afterwards works, old and new shapes side by side", ctx do
      write_older_log(ctx, [
        [older_fact("is", "is", "attribute", 1)],
        [older_fact("ada", "height", 180, 2)]
      ])

      {:ok, ledger} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.dir})
      on_exit(fn -> Ledger.close(ctx.name) end)

      {:ok, _} = Ledger.append(ledger, [{"grace", "height", 175}])

      snapshot = Snapshot.open([ledger])
      assert Snapshot.value(snapshot, "ada", "height") == 180
      assert Snapshot.value(snapshot, "grace", "height") == 175
    end
  end

  describe "a checkpoint written by an older version" do
    test "is read in the old shape too", ctx do
      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      olds = [older_fact("ada", "height", 180, 1), older_fact("grace", "height", 175, 2)]

      # A checkpoint holds facts and the byte offset it had reached. An empty
      # log with a checkpoint covering it is exactly what a reopen after
      # checkpointing looks like.
      payload = :erlang.term_to_binary({2, 0, olds})

      File.write!(
        path <> ".checkpoint",
        <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
      )

      File.write!(path, <<>>)

      {:ok, store} = Store.File.open(ctx.name, dir: ctx.dir)
      facts = Store.File.replay(store)
      Store.File.close(store)

      assert length(facts) == 2
      assert Enum.map(facts, & &1.value) == [180, 175]
    end
  end

  describe "translating a shape" do
    test "an older fact becomes a current one", _ctx do
      assert %Fact{id: "ada", attribute: "height", value: 180, tx: 3, by: nil} =
               Fact.from_stored(older_fact("ada", "height", 180, 3))
    end

    test "a current fact is left exactly alone", _ctx do
      current = %Fact{id: "ada", attribute: "height", value: 180, tx: 3}
      assert Fact.from_stored(current) === current
    end

    test "provenance survives the translation", _ctx do
      older = %{
        __struct__: Fact,
        id: "ada",
        attribute: "doubled",
        answer: 360,
        tx: 4,
        by: "doubling"
      }

      assert %Fact{by: "doubling", value: 360} = Fact.from_stored(older)
    end

    test "anything that is not a fact passes through untouched", _ctx do
      assert Fact.from_stored(:not_a_fact) == :not_a_fact
      assert Fact.from_stored(%{id: "x"}) == %{id: "x"}
    end
  end

  describe "a checkpoint that cannot be about this log" do
    # It reaches past the end when the log is shorter than the checkpoint says:
    # a restore that brought back the facts but not the sidecar, a log replaced
    # while its checkpoint survived, a copy truncated somewhere. Believing it
    # asked for a negative number of bytes and raised from inside `init/1` —
    # after the careful fallback in `read_checkpoint/1` had already returned, so
    # the ledger simply would not open.
    test "is dropped, and the log is read from the start", ctx do
      write_older_log(ctx, [
        [older_fact("is", "is", "attribute", 1)],
        [older_fact("ada", "height", 180, 2)]
      ])

      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      size = File.stat!(path).size

      # A checkpoint claiming the log reaches far past where it actually does.
      payload = :erlang.term_to_binary({99, size * 10, []})

      File.write!(
        path <> ".checkpoint",
        <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
      )

      {:ok, store} = Store.File.open(ctx.name, dir: ctx.dir)
      facts = Store.File.replay(store)
      Store.File.close(store)

      assert length(facts) == 2
      assert Enum.map(facts, & &1.id) == ["is", "ada"]
    end

    test "and the ledger opens rather than refusing to start", ctx do
      write_older_log(ctx, [[older_fact("ada", "height", 180, 1)]])
      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      payload = :erlang.term_to_binary({50, 1_000_000, []})

      File.write!(
        path <> ".checkpoint",
        <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
      )

      {:ok, ledger} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.dir})
      on_exit(fn -> Ledger.close(ctx.name) end)

      assert Snapshot.value(Snapshot.open([ledger]), "ada", "height") == 180
    end

    test "a checkpoint that does describe the log is still believed", ctx do
      write_older_log(ctx, [[older_fact("ada", "height", 180, 1)]])
      path = Path.join(ctx.dir, Store.File.filename(ctx.name))
      size = File.stat!(path).size
      olds = [older_fact("ada", "height", 180, 1)]
      payload = :erlang.term_to_binary({1, size, olds})

      File.write!(
        path <> ".checkpoint",
        <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
      )

      {:ok, store} = Store.File.open(ctx.name, dir: ctx.dir)
      stats = Store.File.stats(store)
      assert Store.File.replay(store) |> length() == 1
      Store.File.close(store)

      # Believed: it covered the whole log, so nothing was rescanned.
      assert stats.checkpoint_at == 1
      assert stats.records_scanned == 0
    end
  end

  describe "a log written when the project had another name" do
    # `term_to_binary` stores which struct a map is, so renaming the project
    # renamed the row. Every fact written as LazyRiver.Fact is still on disk
    # under that name and always will be.
    test "opens, and every fact answers under the name it has now", ctx do
      write_older_log(ctx, [
        [renamed_fact("is", "is", "attribute", 1)],
        [renamed_fact("ada", "height", 180, 2)]
      ])

      {:ok, store} = Store.File.open(ctx.name, dir: ctx.dir)
      facts = Store.File.replay(store)
      Store.File.close(store)

      assert length(facts) == 2
      assert Enum.all?(facts, &match?(%Fact{}, &1))
      assert List.last(facts).value == 180
    end

    test "even when it also predates the value rename", ctx do
      # Both renames at once: the oldest shape there is.
      write_older_log(ctx, [[renamed_fact("ada", "height", 180, 1, :answer)]])

      {:ok, ledger} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.dir})
      on_exit(fn -> Ledger.close(ctx.name) end)

      assert Snapshot.value(Snapshot.open([ledger]), "ada", "height") == 180
    end

    test "a value of nil or false survives, which a default would have eaten", ctx do
      write_older_log(ctx, [
        [renamed_fact("a", "flag", false, 1, :answer)],
        [renamed_fact("b", "flag", nil, 2)]
      ])

      {:ok, store} = Store.File.open(ctx.name, dir: ctx.dir)
      [first, second] = Store.File.replay(store)
      Store.File.close(store)

      assert first.value == false
      assert second.value == nil
    end

    test "and the index is built over them", ctx do
      write_older_log(ctx, [
        [renamed_fact("is", "is", "attribute", 1)],
        [renamed_fact("ada", "height", 180, 2)]
      ])

      {:ok, ledger} = Ledger.open(ctx.name, store: {Store.File, dir: ctx.dir})
      on_exit(fn -> Ledger.close(ctx.name) end)

      assert [%Fact{id: "ada"}] = Ledger.find_at(ledger, 2, value: 180)
    end

    test "translating one directly", _ctx do
      assert %Fact{id: "ada", attribute: "height", value: 180, tx: 3, by: nil} =
               Fact.from_stored(renamed_fact("ada", "height", 180, 3))

      assert %Fact{by: "doubling", value: 360} =
               Fact.from_stored(%{
                 __struct__: :"Elixir.LazyRiver.Fact",
                 id: "ada",
                 attribute: "doubled",
                 answer: 360,
                 tx: 4,
                 by: "doubling"
               })
    end
  end
end
