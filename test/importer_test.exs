defmodule Blazie.ImporterTest do
  @moduledoc """
  Arrival: bulk, resumable, exactly once.

  The properties, each with the failure it prevents: the cursor lands after
  the batch (a crash between them replays, and the replay lands nothing);
  idempotency keys on the canonical ref (a re-run of everything produces
  zero new facts); the reader never writes (separated outputs — the sweep
  contract); and a row that cannot be skipped next time is refused now.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Importer, Snapshot, TestLedger, World}

  # A source of `count` people, split between a shared world and an org
  # world — the Graph/Atlas shape in miniature. Batches by offset.
  defp reader(shared, org, count, batch) do
    fn cursor ->
      from = cursor || 0

      if from >= count do
        :done
      else
        rows =
          for i <- from..min(from + batch - 1, count - 1) do
            id = "person-#{i}"
            world = if rem(i, 2) == 0, do: shared, else: org

            {world, id,
             [
               {id, "ref", id},
               {id, "height", 100 + i}
             ]}
          end

        {:batch, rows, min(from + batch, count)}
      end
    end
  end

  setup do
    shared = TestLedger.open()
    org = TestLedger.open()
    journal = TestLedger.open()

    for world <- [shared, org] do
      {:ok, _} = World.append(world, Attribute.seed())
      {:ok, _} = World.append(world, Attribute.define("ref", answers: "name"))
      {:ok, _} = World.append(world, Attribute.define("height", answers: "integer"))
    end

    {:ok, _} = World.append(journal, Attribute.seed() ++ Importer.seed())

    %{
      shared: World.name_of(shared),
      org: World.name_of(org),
      journal: World.name_of(journal)
    }
  end

  defp counted(world) do
    length(Snapshot.ids(Snapshot.open([World.via(world)]), attribute: "ref"))
  end

  test "everything lands where its row said, once", ctx do
    source = reader(ctx.shared, ctx.org, 100, 7)

    assert {:ok, %{imported: 100, skipped: 0, batches: 15}} =
             Importer.run(source, journal: {ctx.journal, "import-1"})

    assert counted(ctx.shared) == 50
    assert counted(ctx.org) == 50

    # The whole thing again — a crashed orchestrator's retry, the blunt kind
    # that lost the cursor. Zero new facts, and it says so.
    assert {:ok, %{imported: 0, skipped: 100}} =
             Importer.run(source, journal: {ctx.journal, "import-2"})

    assert counted(ctx.shared) == 50
  end

  test "a crash mid-import resumes from the cursor and duplicates nothing", ctx do
    count = 60
    batch = 10

    # A reader that dies on its fourth batch — after three landed and their
    # cursors were written.
    dying = fn cursor ->
      from = cursor || 0

      if from >= 30,
        do: raise("the source went away"),
        else: reader(ctx.shared, ctx.org, count, batch).(cursor)
    end

    assert_raise RuntimeError, fn ->
      Importer.run(dying, journal: {ctx.journal, "import-3"})
    end

    landed_before = counted(ctx.shared) + counted(ctx.org)
    assert landed_before == 30

    # The re-run RESUMES: the reader is asked from the recorded cursor, not
    # from nil — asserted by recording what it was asked.
    asked = :ets.new(:asked, [:public])

    watching = fn cursor ->
      :ets.insert(asked, {cursor, true})
      reader(ctx.shared, ctx.org, count, batch).(cursor)
    end

    assert {:ok, %{imported: 30, skipped: 0}} =
             Importer.run(watching, journal: {ctx.journal, "import-3"})

    refute :ets.member(asked, nil), "the importer started over instead of resuming"
    assert counted(ctx.shared) + counted(ctx.org) == 60
  end

  test "a replayed batch is skipped row by row, not re-landed", ctx do
    # The sharper crash: the batch LANDED and the cursor did not. The journal
    # says batch one never happened; the world says it did. The world wins,
    # row by row.
    source = reader(ctx.shared, ctx.org, 20, 20)
    {:batch, rows, _next} = source.(nil)

    for {world, _ref, assertions} <- rows do
      {:ok, _} = World.append(World.via(world), assertions, check: &Attribute.check/2)
    end

    assert {:ok, %{imported: 0, skipped: 20, batches: 1}} =
             Importer.run(source, journal: {ctx.journal, "import-4"})

    assert counted(ctx.shared) == 10
  end

  @tag :load
  @tag timeout: 600_000
  test "the gate: a graph-scale corpus arrives within budget", ctx do
    # Half of Phase 2's gate, measured rather than promised: a million facts
    # through the importer, batched the way a real backfill batches. The
    # numbers land in the epic's note when this runs.
    rows = 500_000

    t0 = System.monotonic_time(:millisecond)

    assert {:ok, %{imported: ^rows, skipped: 0}} =
             Importer.run(reader(ctx.shared, ctx.org, rows, 5_000),
               journal: {ctx.journal, "import-load"}
             )

    elapsed = System.monotonic_time(:millisecond) - t0
    memory_mb = div(:erlang.memory(:total), 1024 * 1024)

    IO.puts(
      "\nimporter gate: #{rows} rows (#{rows * 2} facts) in #{elapsed}ms " <>
        "(#{div(rows * 2 * 1000, max(elapsed, 1))} facts/s), node memory #{memory_mb}MB"
    )

    # Generous on purpose: the assertion is that bulk arrival is minutes,
    # not hours, on one lane per world.
    assert elapsed < 300_000
  end

  test "a row without its own ref is refused, because it would import twice", ctx do
    source = fn
      nil -> {:batch, [{ctx.shared, "p-1", [{"p-1", "height", 180}]}], 1}
      _ -> :done
    end

    assert {:error, %{problem: :ref_missing, repair: repair}} =
             Importer.run(source, journal: {ctx.journal, "import-5"})

    assert repair =~ "import twice"
    assert counted(ctx.shared) == 0
  end

  test "a source that disagrees with the vocabulary is refused with the repair", ctx do
    source = fn
      nil ->
        {:batch,
         [{ctx.shared, "p-1", [{"p-1", "ref", "p-1"}, {"p-1", "height", "not a number"}]}], 1}

      _ ->
        :done
    end

    assert {:error, %{repair: repair}} = Importer.run(source, journal: {ctx.journal, "import-6"})
    assert String.length(repair) > 20
  end
end
