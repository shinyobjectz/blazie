defmodule Blazie.Store.Paged do
  @moduledoc """
  The store that seeks — the same files, read back instead of held.

  `Store.File` is a memory store that also persists: everything it replays
  stays resident, 241 bytes per fact, and a million facts per world is where
  stalls begin. This is the module its own moduledoc promised — "an offset
  index per transaction, reads that go back to the file, and a cache with a
  policy" — behind the same seam and over the same bytes, because the format
  lives in `Store.Record` and both stores speak it.

  ## What is held, and what is not

  Held: an offset per transaction (where its record starts), postings per
  indexable key (which transactions mention this id, this attribute, this
  value — transaction NUMBERS, not facts), and a bounded cache of decoded
  transactions in an ETS table that dies with the world's process. Not held:
  the facts. A million-fact world costs the index, not the data.

  ## The three extra callbacks

  `seek/3`, `tail/2` and `last_tx/1` are what make a world able to keep only
  a working set: the world holds its resident tail and asks the store for
  anything older, by pattern, and the store answers from the index plus a
  pread — never a full rescan, which was the measured thousand-x penalty
  this module exists to close. A store without them still works; the world
  falls back to replay-and-filter exactly as before.

  ## What this deliberately is not, yet

  The postings live in memory, so the index grows with the log even though
  the data does not — the honest fraction, measured in the gate test, not
  hidden. Spilling the index itself (the LSM half) is the seam's next
  module; readings-scale worlds should shard by time window meanwhile
  (docs/customer-zero.md, topology rule 2). And there are no checkpoints:
  open is one walk of the file to build the index, and a sidecar for the
  index can come when a measurement says to.
  """

  @behaviour Blazie.Store

  alias Blazie.Fact
  alias Blazie.Store.Record

  # Decoded transactions kept warm. Generational on purpose: when the table
  # exceeds twice this, it is cleared whole — an LRU needs an order nobody
  # else pays for, and a re-warm is one pread per miss.
  @cached 512

  @impl true
  def open(name, opts) do
    dir = Keyword.get(opts, :dir, "priv/ledgers")
    File.mkdir_p!(dir)
    path = Path.join(dir, Blazie.Store.File.filename(name))

    binary =
      case File.read(path) do
        {:ok, bytes} -> bytes
        {:error, :enoent} -> <<>>
      end

    mode = Record.mode_of(binary)

    {{offsets, postings, last}, valid_end} =
      Record.walk(binary, Record.base_of(mode), mode, {%{}, %{}, 0}, fn
        transaction, offset, bytes, {offsets, postings, _last} ->
          tx = tx_of(transaction)

          {Map.put(offsets, tx, {offset, bytes}), noted(postings, tx, transaction), tx}
      end)

    # The same tear rule as Store.File: damage past the valid end is cut so
    # a later append cannot land beyond it and vanish.
    if byte_size(binary) > valid_end do
      {:ok, rw} = :file.open(path, [:read, :write, :binary, :raw])
      {:ok, _} = :file.position(rw, valid_end)
      :ok = :file.truncate(rw)
      :ok = :file.close(rw)
    end

    {:ok, io} = :file.open(path, [:append, :binary, :raw])

    {mode, bytes} =
      case mode do
        :new ->
          {header, generation} = Record.header()
          :ok = :file.write(io, header)
          {{:v2, generation}, Record.header_bytes()}

        mode ->
          {mode, valid_end}
      end

    {:ok, reader} = :file.open(path, [:read, :binary, :raw])

    {:ok,
     %{
       path: path,
       io: io,
       reader: reader,
       mode: mode,
       bytes: bytes,
       sync: Keyword.get(opts, :sync, Application.get_env(:blazie, :ledger_sync, false)),
       offsets: offsets,
       postings: postings,
       last_tx: last,
       # Owned by whoever opened the store — the world's process — so the
       # cache dies exactly when the world does.
       cache: :ets.new(__MODULE__.Cache, [:set, :private])
     }}
  end

  @impl true
  def append(state, facts) do
    tx = tx_of(facts)
    payload = :erlang.term_to_binary(facts)
    record = Record.encode(state.mode, state.bytes, payload)

    :ok = :file.write(state.io, record)
    if state.sync, do: :ok = :file.sync(state.io)

    warm(state.cache, tx, facts)

    {:ok,
     %{
       state
       | bytes: state.bytes + byte_size(record),
         offsets: Map.put(state.offsets, tx, {state.bytes, byte_size(record)}),
         postings: noted(state.postings, tx, facts),
         last_tx: max(state.last_tx, tx)
     }}
  end

  @impl true
  def replay(state) do
    # Every fact, oldest first — the compatibility path, one streamed pass.
    # Nothing above should call this on the hot path; `seek/3` is the point.
    state.offsets
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(&load(state, &1))
  end

  @impl true
  def close(state) do
    :file.close(state.io)
    :file.close(state.reader)
    :ets.delete(state.cache)
    :ok
  end

  @doc "The transaction this store has reached."
  @impl true
  @spec last_tx(map()) :: non_neg_integer()
  def last_tx(state), do: state.last_tx

  @doc """
  The facts matching a pattern at or before `upto`, oldest first, from disk.

  Candidate transactions come from the postings — never a scan — and each is
  one pread plus a decode, cached. An empty pattern is every transaction,
  which is `replay/1` with a ceiling; callers with a pattern pay only for
  what mentions it.
  """
  @impl true
  @spec seek(map(), keyword(), non_neg_integer()) :: [Fact.t()]
  def seek(state, pattern, upto) do
    state
    |> candidates(pattern, upto)
    |> Enum.flat_map(&load(state, &1))
    |> Enum.filter(&(&1.tx <= upto and Fact.matches?(&1, pattern)))
  end

  @doc "The last `count` transactions' facts, oldest first — a world's resident tail."
  @impl true
  @spec tail(map(), pos_integer()) :: [Fact.t()]
  def tail(state, count) do
    state.offsets
    |> Map.keys()
    |> Enum.sort(:desc)
    |> Enum.take(count)
    |> Enum.reverse()
    |> Enum.flat_map(&load(state, &1))
  end

  @doc "What opening had to build, and what the index weighs."
  @spec stats(map()) :: map()
  def stats(state) do
    %{
      transactions: map_size(state.offsets),
      postings: map_size(state.postings),
      cached: :ets.info(state.cache, :size),
      bytes: state.bytes
    }
  end

  # ── the index ──────────────────────────────────────────────────────────────

  defp tx_of([%Fact{tx: tx} | _rest]), do: tx

  defp noted(postings, tx, facts) do
    facts
    |> Enum.flat_map(fn fact ->
      [{:id, fact.id}, {:attribute, fact.attribute}] ++
        case indexable(fact.value) do
          nil -> []
          value -> [{:value, value}]
        end
    end)
    |> Enum.uniq()
    |> Enum.reduce(postings, fn key, acc ->
      Map.update(acc, key, [tx], fn
        [^tx | _rest] = held -> held
        held -> [tx | held]
      end)
    end)
  end

  # The same judgement the world's value index makes: only values that can be
  # looked up cheaply get an entry, and nobody asks for a fact by its vector.
  defp indexable(value) when is_integer(value) or is_binary(value) or is_atom(value), do: value
  defp indexable(_value), do: nil

  defp candidates(state, pattern, upto) do
    txs =
      cond do
        id = pattern[:id] ->
          Map.get(state.postings, {:id, id}, [])

        (value = pattern[:value]) && indexable(value) != nil ->
          Map.get(state.postings, {:value, value}, [])

        attribute = pattern[:attribute] ->
          Map.get(state.postings, {:attribute, attribute}, [])

        true ->
          Map.keys(state.offsets)
      end

    txs |> Enum.filter(&(&1 <= upto)) |> Enum.sort()
  end

  # ── reading back ───────────────────────────────────────────────────────────

  defp load(state, tx) do
    case :ets.lookup(state.cache, tx) do
      [{^tx, facts}] ->
        facts

      [] ->
        {offset, bytes} = Map.fetch!(state.offsets, tx)
        {:ok, <<_size::32, _crc::32, payload::binary>>} = :file.pread(state.reader, offset, bytes)

        # The CRC was verified when the index was built or the record written;
        # what pread hands back is re-gated by the decode, which is the check
        # that matters for bytes that could have changed under our feet.
        case Record.decode(payload) do
          {:ok, facts} ->
            warm(state.cache, tx, facts)
            facts

          :torn ->
            []
        end
    end
  end

  defp warm(cache, tx, facts) do
    if :ets.info(cache, :size) > @cached * 2, do: :ets.delete_all_objects(cache)
    :ets.insert(cache, {tx, facts})
  end
end
