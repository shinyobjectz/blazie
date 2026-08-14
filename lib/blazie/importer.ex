defmodule Blazie.Importer do
  @moduledoc """
  How a customer's existing data arrives: in bulk, resumably, exactly once.

  The refusal is the migration engine for schema; this is the engine for
  ARRIVAL — customer zero shows up with Postgres tables, a vector namespace
  and a bucket, and needs millions of facts landed in the right worlds. The
  shape is the sweep reader's, copied deliberately (it is the design socialite
  already paid to learn): a READER answers separated rows and never writes;
  the importer decides where each row goes and owns every write.

  ## The contract

  A reader is a function of a cursor:

      reader.(cursor) -> {:batch, rows, next_cursor} | :done

  `cursor` is `nil` on the first call and whatever the reader last answered
  after that — the reader picks the shape (an offset, a primary key, an
  opaque token) and the importer only stores it. Rows are
  `{world_name, canonical_ref, [assertion]}`: which world, which entity this
  IS (the id everything idempotent keys on), and the facts to land.

  ## Exactly-once effect, from at-least-once plus idempotency

  The cursor is written AFTER a batch's appends land — the sweep rule. A
  crash between the two replays the batch, and the replay lands nothing:
  every row whose canonical ref already exists in its destination world is
  skipped. The seen-set is read from each world ONCE at start (ids only,
  off the index) and carried forward in memory, so idempotency costs one
  query per world per run rather than one per row.

  ## What this deliberately is not

  Not a transformer — the reader shapes rows, because the reader knows the
  source. Not parallel across a world — appends serialize per world anyway
  (the topology rules in docs/customer-zero.md), and a parallel importer
  would be a queue in front of a lane.

  ## The vocabulary check, carried rather than asked for

  The serialized check the wire runs is handed the world's whole history per
  append — right for a conversation, and O(world) per call, which at a
  million facts made arrival quadratic (measured: the gate test timed out at
  35k facts). So the importer IS its own check: it reads each world's
  attribute definitions once, carries them forward with whatever a batch
  declares, and runs `Attribute.check/2` against exactly those — which is
  sufficient because the shape checks read only attribute meta, and the one
  check that needs data facts fires only on REDECLARATION. An import that
  redeclares a live attribute is refused outright: narrowing vocabulary
  under a backfill is a deliberate write, not a side effect of one.

  The contract this rests on is the topology rule already written: an import
  lane is its world's only writer while it runs.
  """

  alias Blazie.{Attribute, Snapshot, World}

  @type row :: {World.name(), term(), [World.assertion()]}
  @type reader :: (term() -> {:batch, [row()], term()} | :done)
  @type refusal :: %{problem: atom(), repair: String.t()}

  @cursor "import_cursor"
  @doc "The attributes an import records itself with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define(@cursor, answers: "any") ++
      Attribute.define("imported", answers: "integer", cardinality: "many")
  end

  @doc """
  Run an import to completion, or to the first refusal.

  Options: `journal:` `{world, id}` — where the cursor lives, so a re-run
  resumes instead of starting over (the journal world's vocabulary must
  include `seed/0`); `ref:` the attribute a canonical ref is asserted under
  (`"ref"` unless told) — every row's facts should include it, and the
  importer refuses a row that does not, because a row without its ref cannot
  be skipped next time and would import twice.

  Answers what happened: how many landed, how many were already there, and
  how many batches it took.
  """
  @spec run(reader(), keyword()) ::
          {:ok,
           %{imported: non_neg_integer(), skipped: non_neg_integer(), batches: non_neg_integer()}}
          | {:error, refusal()}
  def run(reader, opts) when is_function(reader, 1) do
    {journal_world, journal_id} = Keyword.fetch!(opts, :journal)
    ref = Keyword.get(opts, :ref, "ref")

    cursor = Snapshot.value(Snapshot.open([World.via(journal_world)]), journal_id, @cursor)

    walk(reader, cursor, %{
      journal: {journal_world, journal_id},
      ref: ref,
      seen: %{},
      defs: %{},
      imported: 0,
      skipped: 0,
      batches: 0
    })
  end

  defp walk(reader, cursor, state) do
    case reader.(cursor) do
      :done ->
        {:ok, Map.take(state, [:imported, :skipped, :batches])}

      {:batch, rows, next} ->
        case land(rows, state) do
          {:ok, state} ->
            # The cursor lands after the batch — a crash in between replays
            # the batch, and the replay is skipped row by row.
            {journal_world, journal_id} = state.journal

            {:ok, _} =
              World.append(World.via(journal_world), [
                {journal_id, @cursor, next, journal_id},
                {journal_id, "imported", state.imported, journal_id}
              ])

            walk(reader, next, %{state | batches: state.batches + 1})

          {:error, refusal} ->
            {:error, refusal}
        end
    end
  end

  defp land(rows, state) do
    rows
    |> Enum.group_by(fn {world, _ref, _assertions} -> world end)
    |> Enum.reduce_while({:ok, state}, fn {world, batch}, {:ok, state} ->
      case land_in(world, batch, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, refusal} -> {:halt, {:error, refusal}}
      end
    end)
  end

  defp land_in(world, batch, state) do
    with {:ok, state} <- known_refs(world, state),
         :ok <- refs_present(batch, state.ref) do
      seen = state.seen[world]

      {fresh, skipped} =
        Enum.split_with(batch, fn {_w, ref, _a} -> not MapSet.member?(seen, ref) end)

      assertions = Enum.flat_map(fresh, fn {_w, _ref, facts} -> facts end)
      defs = state.defs[world]

      with :ok <- no_redeclarations(assertions, defs),
           :ok <- checked(assertions, defs),
           {:ok, _} <- appended(world, assertions) do
        now_seen = Enum.reduce(fresh, seen, fn {_w, ref, _a}, acc -> MapSet.put(acc, ref) end)

        {:ok,
         %{
           state
           | seen: Map.put(state.seen, world, now_seen),
             defs: Map.put(state.defs, world, defs ++ meta_in(assertions)),
             imported: state.imported + length(fresh),
             skipped: state.skipped + length(skipped)
         }}
      else
        {:error, [refusal | _]} -> {:error, refusal}
        {:error, refusal} -> {:error, refusal}
      end
    end
  end

  defp appended(_world, []), do: {:ok, :nothing}

  defp appended(world, assertions) do
    # Unchecked at the world, because the check already ran here against the
    # carried vocabulary — and with a call timeout sized for a batch that is
    # working, not hung.
    World.append(World.via(world), assertions, timeout: 60_000)
  end

  defp checked(assertions, defs) do
    case Attribute.check(assertions, defs) do
      :ok -> :ok
      {:error, _refusals} = refused -> refused
    end
  end

  @meta ~w(is answers cardinality one_of)

  defp meta_in(assertions) do
    Enum.filter(assertions, fn
      {_id, attribute, _value} -> attribute in @meta
      {_id, attribute, _value, _by} -> attribute in @meta
    end)
    |> Enum.map(fn
      {id, attribute, value} ->
        %Blazie.Fact{id: id, attribute: attribute, value: value, tx: 0}

      {id, attribute, value, by} ->
        %Blazie.Fact{id: id, attribute: attribute, value: value, tx: 0, by: by}
    end)
  end

  # An import declares vocabulary; it never changes it. A batch that answers
  # differently than the carried definition for the same attribute is trying
  # to narrow live words under a backfill, and `Attribute.check`'s narrowing
  # rules need the data facts this importer deliberately does not carry — so
  # the answer is a refusal, not a slower import.
  defp no_redeclarations(assertions, defs) do
    declared =
      Map.new(defs, fn %{id: id, attribute: attribute, value: value} ->
        {{id, attribute}, value}
      end)

    conflict =
      Enum.find(meta_in(assertions), fn %{id: id, attribute: attribute, value: value} ->
        case Map.fetch(declared, {id, attribute}) do
          {:ok, held} -> held != value
          :error -> false
        end
      end)

    case conflict do
      nil ->
        :ok

      %{id: id, attribute: attribute, value: value} ->
        {:error,
         %{
           problem: :redeclaration,
           repair:
             "This batch declares #{inspect(id)}.#{attribute} = #{inspect(value)} but the world " <>
               "already says otherwise. An import declares vocabulary once; narrowing a live " <>
               "attribute is a deliberate write made outside the backfill, where the narrowing " <>
               "check can see the data."
         }}
    end
  end

  # One ids query and one vocabulary read per world per run — the whole cost
  # of idempotency and of checking. Ids come off the index without revealing
  # values, so a large world answers this cheaply and an erased one answers
  # it at all.
  defp known_refs(world, state) do
    case state.seen do
      %{^world => _already} ->
        {:ok, state}

      seen ->
        {:ok, _ref} = World.open(world)
        snapshot = Snapshot.open([World.via(world)])
        ids = Snapshot.ids(snapshot, attribute: state.ref)
        defs = Enum.flat_map(@meta, &Snapshot.find(snapshot, attribute: &1))

        {:ok,
         %{
           state
           | seen: Map.put(seen, world, MapSet.new(ids)),
             defs: Map.put(state.defs, world, defs)
         }}
    end
  end

  defp refs_present(batch, ref) do
    case Enum.find(batch, fn {_world, canonical, assertions} ->
           not has_ref?(assertions, canonical, ref)
         end) do
      nil ->
        :ok

      {_world, canonical, _assertions} ->
        {:error,
         %{
           problem: :ref_missing,
           repair:
             "Row #{inspect(canonical)} does not assert its own canonical ref, so a re-run " <>
               "could not skip it and it would import twice. Every row's facts must include " <>
               "{id, #{inspect(ref)}, value} for its own id."
         }}
    end
  end

  defp has_ref?(assertions, canonical, ref) do
    Enum.any?(assertions, fn
      {^canonical, ^ref, _value} -> true
      {^canonical, ^ref, _value, _by} -> true
      _other -> false
    end)
  end
end
