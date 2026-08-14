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

  @type outcome :: %{tombstoned: non_neg_integer(), reclaimed: non_neg_integer()}

  @doc """
  Rewrite a world's file, tombstoning every sealed answer whose subject has
  been erased.

  `erased:` is the set of erased subjects (defaults to `Erasure.erased/0`, so
  a caller usually just names the store). The world at `name` must be closed.
  """
  @spec erased(term(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def erased(name, opts) do
    dir = Keyword.fetch!(opts, :dir)
    erased = Keyword.get(opts, :erased) || erased_set()
    path = Path.join(dir, Store.File.filename(name))

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
