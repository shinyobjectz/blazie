defmodule Blazie.Compact do
  @moduledoc """
  Making the file smaller — the half that is safe because it only touches
  what was already destroyed.

  `Store.File`'s moduledoc names the tension: nothing is rewritten, so
  superseded facts cannot be dropped, because an old snapshot name would
  start answering differently and that is the guarantee everything rests on.
  That rules out cardinality-aware shrinking without a horizon (a decision to
  stop answering names below some transaction — recorded as remaining scope
  in bla-pp24, with its doctrine cost).

  What it does NOT rule out is reclaiming erased content. When a subject is
  erased its key is gone and its sealed answers are noise that already reads
  as `:erased`. Replacing that noise with the `:erased` tombstone it already
  resolves to changes no answer, refuses no name, and shrinks the file by the
  ciphertext — which for a subject holding blobs or long text is most of what
  they occupied. This is not a violation of immutability; it is the space
  bookkeeping of the one destruction the system already performs (doctrine
  16), finished.

  ## Offline, and atomic

  Compaction reads a closed world's file, writes a new-generation file beside
  it, and renames it in — a crash leaves the original untouched (the same
  write-beside-rename every durable write here uses). The world must be
  closed: a live writer and a rewriter racing on one file is the one thing
  this must not be. Returns how many transactions were rewritten and how many
  bytes came back.
  """

  alias Blazie.{Erasure, Fact, Store}
  alias Blazie.Store.Record
  alias Exqlite.Sqlite3

  @type outcome :: %{tombstoned: non_neg_integer(), reclaimed: non_neg_integer()}

  @doc """
  Rewrite a world's storage, tombstoning every sealed answer whose subject
  has been erased.

  `erased:` is the set of erased subjects (defaults to `Erasure.erased/0`, so
  a caller usually just names the store). The world at `name` must be closed.

  Both layouts are compacted by what is on disk: a `.sqlite` as
  UPDATE-then-VACUUM, a `.ledger` as the walk-and-rewrite it always was, and
  a migrated world (both files present) as both — the ledger is the legacy
  record and its erased ciphertext is still bytes on a disk somebody pays
  for. The outcome sums.
  """
  @spec erased(term(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def erased(name, opts) do
    dir = Keyword.fetch!(opts, :dir)
    erased = Keyword.get(opts, :erased) || erased_set()
    sqlite = Path.join(dir, Store.SQLite.filename(name))
    ledger = Path.join(dir, Store.File.filename(name))

    case {File.exists?(sqlite), File.exists?(ledger)} do
      {true, true} ->
        with {:ok, a} <- erased_sqlite(sqlite, erased),
             {:ok, b} <- erased_ledger(ledger, erased) do
          {:ok, %{tombstoned: a.tombstoned + b.tombstoned, reclaimed: a.reclaimed + b.reclaimed}}
        end

      {true, false} ->
        erased_sqlite(sqlite, erased)

      {false, _} ->
        erased_ledger(ledger, erased)
    end
  end

  # ── the SQLite half: UPDATE, then VACUUM ────────────────────────────────────
  #
  # `Store.SQLite`'s discipline is that INSERT is the only statement it ever
  # issues; this UPDATE lives here, outside the store, the same place the
  # file rewriter always lived — compaction is the one sanctioned rewrite,
  # and it touches only what was already destroyed. Values are opaque blobs,
  # so the erased set is found by decoding in Elixir ([:safe], shape-gated,
  # anything undecodable left alone), never by searching values in SQL —
  # sealed values stay value-unsearchable, even here.
  defp erased_sqlite(path, erased) do
    before = File.stat!(path).size
    {:ok, db} = Sqlite3.open(path)

    try do
      {:ok, stmt} = Sqlite3.prepare(db, "SELECT seq, value FROM facts")
      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      :ok = Sqlite3.release(db, stmt)

      hits = for [seq, blob] <- rows, erased_sealed?(blob, erased), do: seq

      tombstone = :erlang.term_to_binary(:erased)
      :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

      {:ok, update} = Sqlite3.prepare(db, "UPDATE facts SET value = ?1 WHERE seq = ?2")

      for seq <- hits do
        :ok = Sqlite3.bind(update, [{:blob, tombstone}, seq])
        :done = Sqlite3.step(db, update)
        :ok = Sqlite3.reset(update)
      end

      :ok = Sqlite3.release(db, update)
      :ok = Sqlite3.execute(db, "COMMIT")

      # VACUUM rewrites the file without the reclaimed pages; the checkpoint
      # folds the WAL back in so the size measured is the size on disk.
      :ok = Sqlite3.execute(db, "VACUUM")
      :ok = Sqlite3.execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")

      {:ok, %{tombstoned: length(hits), reclaimed: max(before - File.stat!(path).size, 0)}}
    after
      Sqlite3.close(db)
    end
  end

  defp erased_sealed?(blob, erased) do
    case :erlang.binary_to_term(blob, [:safe]) do
      {:sealed, subject, _wrapped, _iv, _tag, _cipher} -> is_map_key(erased, subject)
      {:sealed, subject, _wrapped, _iv, _tag, _cipher, :bound} -> is_map_key(erased, subject)
      _ -> false
    end
  rescue
    # Bytes that do not decode are not this function's to judge — the store's
    # own read gate refuses them at open; compaction leaves them untouched.
    _ -> false
  end

  # ── the ledger half: the walk-and-rewrite it always was ─────────────────────

  defp erased_ledger(path, erased) do
    with {:ok, binary} <- File.read(path) do
      mode = Record.mode_of(binary)
      base = Record.base_of(mode)

      # A compacted file is always a fresh generation — its records carry new
      # offset-and-generation CRCs, and the old checkpoint (which described the
      # old bytes) must not be trusted against them.
      {header, generation} = Record.header()
      new_mode = {:v2, generation}

      {{rewritten, tombstoned}, _ended} =
        Record.walk(binary, base, mode, {[], 0}, fn transaction, _offset, _bytes, {acc, n} ->
          {rewrite, hit} = tombstone(transaction, erased)
          {[rewrite | acc], n + hit}
        end)

      transactions = Enum.reverse(rewritten)

      {bytes, out} =
        Enum.reduce(transactions, {byte_size(header), [header]}, fn facts, {at, chunks} ->
          payload = :erlang.term_to_binary(facts)
          record = Record.encode(new_mode, at, payload)
          {at + byte_size(record), [record | chunks]}
        end)

      new_bytes = out |> Enum.reverse() |> IO.iodata_to_binary()

      tmp = path <> ".compacting"
      File.write!(tmp, new_bytes)
      File.rename!(tmp, path)
      # The old checkpoint describes bytes that no longer exist.
      File.rm(path <> ".checkpoint")

      {:ok, %{tombstoned: tombstoned, reclaimed: max(byte_size(binary) - bytes, 0)}}
    end
  end

  # Replace every sealed value whose subject is erased with the `:erased`
  # tombstone it already reveals as. The fact keeps its id, attribute and tx,
  # so every entity still answers and every snapshot name still resolves —
  # only the unreadable ciphertext goes.
  defp tombstone(transaction, erased) do
    Enum.map_reduce(transaction, 0, fn %Fact{} = fact, hit ->
      case fact.value do
        {:sealed, subject, _wrapped, _iv, _tag, _cipher} when is_map_key(erased, subject) ->
          {%{fact | value: :erased}, hit + 1}

        {:sealed, subject, _wrapped, _iv, _tag, _cipher, :bound}
        when is_map_key(erased, subject) ->
          {%{fact | value: :erased}, hit + 1}

        _ ->
          {fact, hit}
      end
    end)
  end

  defp erased_set do
    Erasure.erased() |> Map.new(&{&1, true})
  end
end
