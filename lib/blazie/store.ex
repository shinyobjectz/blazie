defmodule Blazie.Store do
  @moduledoc """
  Where a world's facts actually live.

  A world is an append-only sequence, so a store only has to do three things:
  take a transaction's facts, hand them all back in order, and close. That is a
  small enough surface that a file on disk and an LSM on object storage
  implement the same three functions, which is what keeps the storage decision
  a configuration line rather than a rewrite.

  Nothing above this line knows which one is in use. The world is the seam.
  """

  alias Blazie.Fact

  @type state :: term()

  @doc "Open storage for a world, replaying whatever is already there."
  @callback open(name :: term(), opts :: keyword()) :: {:ok, state()}

  @doc "Record one transaction's facts. Returning means recorded."
  @callback append(state(), [Fact.t()]) :: {:ok, state()}

  @doc "Every fact ever recorded, oldest first."
  @callback replay(state()) :: [Fact.t()]

  @doc "Release whatever was held. Not erasure — erasure destroys a key."
  @callback close(state()) :: :ok
end

defmodule Blazie.Store.Memory do
  @moduledoc """
  Facts in the process holding them. Fast, isolated, and gone on close.

  Right for tests and for a world nobody needs to survive a restart. Wrong for
  anything else, which is why closing one is erasure by accident.
  """

  @behaviour Blazie.Store

  @impl true
  def open(_name, _opts), do: {:ok, []}

  # Newest first, so appending is O(batch) rather than O(everything). `++`
  # copies its left operand, so the obvious `facts ++ new` re-copies the whole
  # history on every write and makes a world quadratic in its own length.
  @impl true
  def append(facts, new), do: {:ok, Enum.reverse(new) ++ facts}

  @impl true
  def replay(facts), do: Enum.reverse(facts)

  @impl true
  def close(_facts), do: :ok
end

defmodule Blazie.Store.File do
  @moduledoc """
  An append-only file, which is what a world already is.

  One record per transaction, so atomicity is real rather than implied. A file
  born under this code starts with `"BLZ2"` and a random generation, and each
  record is

      <<size::32, crc::32, payload::binary-size(size)>>

  where the CRC covers the generation, the record's own byte offset, and the
  payload — so a record moved, duplicated, zero-filled or carried over from a
  previous life of the file fails its checksum instead of parsing. A file
  without the magic predates this and is read under the old payload-only CRC
  forever, because nothing here is rewritten, including the encoding of what
  was already written.

  The payload is one transaction's facts, decoded with `:safe` and checked
  against the fact shape before anything trusts it. On replay the file is
  scanned forward, and a record whose length runs past the end, whose checksum
  does not match, whose size is zero, or whose payload is not a transaction is
  where reading stops — a process killed mid-write leaves a torn tail, and
  everything after a torn record is unreadable by definition. Discarding it
  loses exactly the transaction that never completed.

  ## Durability, stated plainly

  `append/2` writes but does not `fsync` by default, so a returned transaction
  survives the process dying and does not survive the machine losing power.
  Pass `sync: true` to fsync every transaction, which is genuinely durable and
  genuinely slow. There is no third option that is both.

  ## Checkpoints, and what compaction is allowed to be

  Replay was O(everything ever written). What could be done about that is
  narrow, because nothing is rewritten and the only destruction is erasure — so
  superseded facts cannot be dropped. An old name would start answering
  differently, and that is the guarantee everything else rests on.

  So `checkpoint_every: n` writes a sidecar holding every fact up to a
  transaction, plus the byte offset it had reached. Opening loads that in one
  decode and scans the log only from the offset. The log is untouched: history
  stays whole, and only the cost of re-reading it record by record goes away.

  This makes opening cheaper, not the file smaller. Making it smaller means
  knowing which facts may be dropped, which is cardinality and erasure, and
  neither of those is here yet.

  ## What this is not, and it is worth being blunt

  **The file is never read again after `open/2`.** Everything is held in the
  process, `replay/1` hands back what is held, and the writes go to disk so a
  restart can rebuild that. So this is a memory store that also persists,
  rather than a store that reads from disk — and three measured consequences
  follow, none of which the shape above admits to.

  Memory is the binding limit: 241 bytes per fact live, 87% of it the world's
  three sort orders. About a million facts per world before stalls bite, six
  million before a 4GB box does.

  `resident:` therefore bounds what the *world* keeps and not what the store
  keeps, so a bound of a thousand on a hundred thousand facts still holds a
  hundred thousand here — it saves 63% of the bytes rather than 99%.

  And a fact the world evicted is answered by re-scanning this list with no
  index, which measured a thousand times slower than an indexed read. The one
  lever against the memory wall is the lever that breaks reads.

  Fixing it means a store that seeks: an offset index per transaction, reads
  that go back to the file, and a cache with a policy. That is a different
  module rather than a change to this one, which is why the seam exists.
  """

  @behaviour Blazie.Store

  alias Blazie.Fact

  # How much of the log may be un-checkpointed before writing another one:
  # half of what is already checkpointed. Lower means opening scans less and
  # more total bytes are written; higher is the reverse. Both are constant
  # factors — the point is that neither grows with the length of the log.
  @growth 0.5

  # A file written from here on begins with this and a random per-file
  # generation, and every record's CRC covers the generation, the record's own
  # byte offset, and the payload. That is SQLite's WAL-salt idea, and it is
  # what makes three different corruptions invalid at once: a zero-filled tail
  # (crc32 of empty is 0, so eight zero bytes used to be a VALID record whose
  # empty payload then raised — C12), a record duplicated or moved to another
  # offset (which is how an overlapping restore corrupts silently — C8), and
  # a record from a previous life of the file. A file without the magic is
  # read under the old rules forever — nothing is rewritten, including the
  # storage encoding of what was already written.
  @magic "BLZ2"
  @header_bytes 12

  @impl true
  def open(name, opts) do
    dir = Keyword.get(opts, :dir, "priv/ledgers")
    File.mkdir_p!(dir)
    path = Path.join(dir, filename(name))

    binary =
      case File.read(path) do
        {:ok, bytes} -> bytes
        {:error, :enoent} -> <<>>
      end

    mode = mode_of(binary)

    {checkpoint, at, offset} =
      (path <> ".checkpoint") |> read_checkpoint() |> describing(binary)

    {facts, scanned, at, offset, valid_end} = read(binary, mode, checkpoint, at, offset)

    # A torn tail is discarded from the FILE, not just from the replay. The
    # scan already refuses to read past it; leaving the bytes meant the next
    # append landed beyond the tear, returned a transaction, and lost it on
    # the next replay — committed data silently gone, which is worse than the
    # tear it hid behind.
    if byte_size(binary) > valid_end do
      {:ok, rw} = :file.open(path, [:read, :write, :binary, :raw])
      {:ok, _} = :file.position(rw, valid_end)
      :ok = :file.truncate(rw)
      :ok = :file.close(rw)
    end

    {:ok, io} = :file.open(path, [:append, :binary, :raw])
    {mode, bytes, log_crc} = ensure_header(io, mode, binary, valid_end)

    {:ok,
     %{
       path: path,
       io: io,
       mode: mode,
       # Newest first. See `append/2`.
       facts: Enum.reverse(facts),
       sync: Keyword.get(opts, :sync, false),
       every: Keyword.get(opts, :checkpoint_every),
       growth: Keyword.get(opts, :checkpoint_growth, @growth),
       # Tracked rather than asked for: a file opened in :append mode does not
       # move its position pointer on write, so position(:cur) is not where the
       # bytes went. Getting that wrong made a reopen read the tail twice.
       bytes: bytes,
       # A running CRC of every byte the log validly holds, continued on each
       # append. A checkpoint records it, and on open the recorded value is
       # checked against the actual prefix — which is how a checkpoint that
       # describes a log this file no longer is gets caught (C3's other half:
       # equal length, different bytes).
       log_crc: log_crc,
       since: scanned,
       checkpoint_at: at,
       checkpoint_bytes: offset,
       checkpoints_written: 0,
       records_scanned: scanned
     }}
  end

  # What the log holds: the checkpoint's facts plus the scanned tail, or —
  # when the checkpoint cannot be trusted about where the tail starts — a full
  # scan from the base. The log is the record and the checkpoint is an
  # optimisation, so every doubt resolves toward the log. Slower, and always
  # right. The v2 offset-bound CRC is what makes a wrong boundary detectable
  # at all: scanning from the wrong place fails the first record instead of
  # misparsing it.
  defp read(binary, mode, checkpoint, at, offset) do
    base = base_of(mode)
    start = max(offset, base)
    {tail, scanned, consumed} = scan_from(binary, start, mode)

    if tail == [] and offset > base and byte_size(binary) - start >= 9 do
      # A checkpoint that says there is a tail it cannot find is not trusted
      # about anything else either.
      {full, rescanned, reconsumed} = scan_from(binary, base, mode)
      {List.flatten(full), rescanned, 0, base, base + reconsumed}
    else
      {checkpoint ++ List.flatten(tail), scanned, at, offset, start + consumed}
    end
  end

  defp base_of({:v2, _generation}), do: @header_bytes
  defp base_of(_mode), do: 0

  # Which rules this file is read and written under. Decided once, by the
  # file's first bytes: the magic means v2, anything else means the shape
  # every deployed ledger already has. An empty or absent file is born v2.
  defp mode_of(<<>>), do: :new
  defp mode_of(<<@magic, generation::64, _::binary>>), do: {:v2, generation}
  defp mode_of(_existing), do: :legacy

  defp ensure_header(io, :new, _binary, _valid_end) do
    generation = :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()
    header = <<@magic, generation::64>>
    :ok = :file.write(io, header)
    {{:v2, generation}, @header_bytes, :erlang.crc32(header)}
  end

  defp ensure_header(_io, mode, binary, valid_end),
    do: {mode, valid_end, :erlang.crc32(binary_part(binary, 0, valid_end))}

  @doc "What opening this store had to do, and what it has done since."
  @spec stats(map()) :: map()
  def stats(state) do
    %{
      checkpoint_at: state.checkpoint_at,
      records_scanned: state.records_scanned,
      checkpoint_bytes: state.checkpoint_bytes,
      checkpoints_written: state.checkpoints_written,
      bytes: state.bytes
    }
  end

  @impl true
  def append(state, facts) do
    payload = :erlang.term_to_binary(facts)

    record =
      <<byte_size(payload)::32, crc(state.mode, state.bytes, payload)::32, payload::binary>>

    :ok = :file.write(state.io, record)
    if state.sync, do: :ok = :file.sync(state.io)

    state = %{
      state
      | # Newest first, and prepended. `++` copies its left operand, so the
        # obvious `state.facts ++ facts` re-copies every fact ever written on
        # every single write — measured at 8.6µs per append at two thousand
        # facts and 47.2µs at sixteen thousand, which is quadratic and was
        # getting worse on the running box by the hour.
        facts: Enum.reverse(facts) ++ state.facts,
        since: state.since + 1,
        bytes: state.bytes + byte_size(record),
        log_crc: :erlang.crc32(state.log_crc, record)
    }

    {:ok, maybe_checkpoint(state)}
  end

  @impl true
  def replay(state), do: Enum.reverse(state.facts)

  @impl true
  def close(state), do: :file.close(state.io)

  @doc """
  How many bytes past `from` this file is whole records.

  What an incremental copier may take: everything up to here survives the
  scan `open/2` replays by, and everything past it is a tear in progress.
  Answered BY the store because the answer depends on the file's format —
  a copier that kept its own scan had the payload-only CRC, and the day the
  format grew a header it silently found nothing readable at all. `from`
  must be a record boundary this store previously reported, or zero.
  """
  @spec readable(Path.t(), non_neg_integer()) :: non_neg_integer()
  def readable(path, from) do
    case File.read(path) do
      {:ok, binary} ->
        mode = mode_of(binary)
        start = max(from, base_of(mode))
        {_records, _count, consumed} = scan_from(binary, start, mode)

        # From zero the header is part of what must travel — a restored v2
        # file without its first twelve bytes is not a v2 file.
        max(start + consumed - from, 0)

      _absent ->
        0
    end
  end

  @doc "Where a world's facts are kept, for a name that may be any term."
  @spec filename(term()) :: String.t()
  def filename(name) do
    # `.ledger`, not `.world`. The word moved; this suffix is the name of a file
    # that already exists on every deployed disk, so renaming it does not rename
    # anything — it makes the node look past 791KB of facts at an empty
    # directory and call itself healthy. The rename to `world` did exactly that
    # for one restart, and nothing failed: the suite was green, the node came
    # up, and the data was simply invisible. A filename is storage layout.
    name |> :erlang.term_to_binary() |> Base.url_encode64(padding: false) |> Kernel.<>(".ledger")
  end

  # The record's CRC. Under v2 it covers the file's generation and the
  # record's own byte offset, so the same bytes at a different place — or in a
  # different life of the file — are not a record.
  defp crc({:v2, generation}, offset, payload),
    do: :erlang.crc32([<<generation::64, offset::64>>, payload])

  defp crc(_legacy, _offset, payload), do: :erlang.crc32(payload)

  # `size > 0` before anything else: crc32 of the empty binary is 0, so eight
  # zero bytes — the tail ext4's delayed allocation is famous for leaving —
  # used to parse as a VALID empty record whose decode then raised, and the
  # ledger would not open at all (C12). A zero-size record is not a record.
  # Answers the accepted transactions and the byte position reading stopped
  # at, which is where the log validly ENDS — whatever damage lies past it.
  defp scan(<<size::32, crc::32, payload::binary-size(size), rest::binary>>, mode, at, acc)
       when size > 0 do
    with true <- crc(mode, at, payload) == crc,
         {:ok, transaction} <- decode_transaction(payload) do
      scan(rest, mode, at + 8 + size, [transaction | acc])
    else
      # A torn record. Everything past it is unreadable, so this is the end.
      _ -> {Enum.reverse(acc), at}
    end
  end

  defp scan(_incomplete_tail, _mode, at, acc), do: {Enum.reverse(acc), at}

  # A payload is one transaction: a list of facts, in a shape some version of
  # this code wrote. Decoded with `:safe` and then checked against that shape,
  # because these bytes can arrive from a backup bucket: without `:safe` a
  # crafted record minted atoms during open — 50k from one record, node-killing
  # from twenty-one — and `:safe` alone still decodes function terms, so the
  # real assertion is conformance (C7). A payload that is not a list of facts
  # whose terms are data is not a transaction, it is damage, and damage is
  # where reading stops.
  defp decode_transaction(payload) do
    rows = :erlang.binary_to_term(payload, [:safe])

    with true <- is_list(rows),
         facts = Enum.map(rows, &Fact.from_stored/1),
         true <- Enum.all?(facts, &stored_fact?/1) do
      {:ok, facts}
    else
      _ -> :torn
    end
  rescue
    # Anything a hostile payload can make raise — an unknown atom under
    # `:safe`, an improper list under the walk — is the same answer: damage.
    _error -> :torn
  end

  defp stored_fact?(%Fact{} = fact) do
    is_binary(fact.attribute) and is_integer(fact.tx) and
      harmless?(fact.id) and harmless?(fact.value) and harmless?(fact.by)
  end

  defp stored_fact?(_other), do: false

  # Data, all the way down. A fun decodes under `:safe` and executes when
  # somebody calls it; a pid or port names something alive on this node. None
  # of them is a value a fact was ever legitimately written with, and all of
  # them are what a crafted payload smuggles.
  defp harmless?(term)
       when is_function(term) or is_pid(term) or is_port(term) or is_reference(term),
       do: false

  defp harmless?([head | tail]), do: harmless?(head) and harmless?(tail)
  defp harmless?([]), do: true

  defp harmless?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.all?(&harmless?/1)

  defp harmless?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> harmless?(key) and harmless?(value) end)
  end

  defp harmless?(_term), do: true

  # ── checkpoints ────────────────────────────────────────────────────────────

  defp maybe_checkpoint(%{every: nil} = state), do: state

  defp maybe_checkpoint(state) when state.since < state.every, do: state

  defp maybe_checkpoint(state) do
    if worth_writing?(state), do: write_checkpoint(state), else: state
  end

  # A checkpoint writes every fact again, so writing one on a fixed count of
  # transactions makes the cost of keeping them grow with history: at a million
  # facts and `checkpoint_every: 1000`, a million facts are serialised every
  # thousand writes, forever. Measured before this changed — sixteen thousand
  # single-fact appends wrote about 136MB of checkpoints to keep 1.7MB of facts.
  #
  # Requiring the unwritten tail to be a fraction of what is already
  # checkpointed makes the total work linear in the log instead. Checkpoints
  # then fall geometrically further apart, each one costs what it saves, and
  # opening still scans no more than that same fraction.
  #
  # It degenerates to the old behaviour while a log is small, which is what a
  # test with `checkpoint_every: 5` expects and is also correct: nothing is
  # ever a large fraction of nothing, so the first checkpoint is not delayed.
  defp worth_writing?(state) do
    state.bytes - state.checkpoint_bytes >= trunc(state.checkpoint_bytes * state.growth)
  end

  defp write_checkpoint(state) do
    facts = Enum.reverse(state.facts)
    at = facts |> Enum.map(& &1.tx) |> Enum.max(fn -> 0 end)
    # The running CRC of the prefix this checkpoint describes travels with it,
    # so a checkpoint can be checked against the log it claims to summarise —
    # same length, different bytes is a restore or a corruption, and either
    # way the log wins.
    payload = :erlang.term_to_binary({at, state.bytes, state.log_crc, facts})

    # Written beside the log and swapped in, so a crash mid-write leaves the
    # previous checkpoint rather than a torn one. The log is never touched.
    tmp = state.path <> ".checkpoint.writing"
    File.write!(tmp, <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>)
    File.rename!(tmp, state.path <> ".checkpoint")

    %{
      state
      | since: 0,
        checkpoint_at: at,
        checkpoint_bytes: state.bytes,
        checkpoints_written: state.checkpoints_written + 1
    }
  end

  defp read_checkpoint(path) do
    with {:ok, <<size::32, crc::32, payload::binary-size(size)>>} <- File.read(path),
         true <- size > 0,
         true <- :erlang.crc32(payload) == crc,
         {at, offset, prefix_crc, facts} <- shaped_checkpoint(payload),
         # A checkpoint is as old as the log it summarises, so it carries old
         # shapes too — and it crosses the same trust boundary the log does,
         # so it clears the same conformance bar (C7).
         mapped = Enum.map(facts, &Fact.from_stored/1),
         true <- Enum.all?(mapped, &stored_fact?/1) do
      {mapped, at, offset, prefix_crc}
    else
      # No checkpoint, or one that did not survive. The log is whole either
      # way, so reading from the start is always correct — just slower.
      _ -> {[], 0, 0, :none}
    end
  rescue
    _error -> {[], 0, 0, :none}
  end

  # A checkpoint written by this code carries the prefix CRC; one written
  # before does not, and is trusted the way it always was — length-checked
  # and boundary-probed, never byte-verified. Nothing rewritten, including
  # sidecars.
  defp shaped_checkpoint(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      {at, offset, prefix_crc, facts}
      when is_integer(at) and is_integer(offset) and is_integer(prefix_crc) and is_list(facts) ->
        {at, offset, prefix_crc, facts}

      {at, offset, facts} when is_integer(at) and is_integer(offset) and is_list(facts) ->
        {at, offset, :none, facts}

      _other ->
        :torn
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, :enoent} -> 0
    end
  end

  # Is this checkpoint describing THIS log?
  #
  # Three ways it cannot be, each found the hard way. It reaches past the end
  # when the log is shorter than the checkpoint says — believing that asked
  # for a negative number of bytes and raised from inside `init/1`, a
  # crash-loop only an operator could end (C3). Its prefix CRC disagrees with
  # the bytes actually on disk — same length, different log: a restore, a
  # replacement, damage under the checkpoint's feet. Or it carries no prefix
  # CRC at all (written before there was one) and its boundary probe fails
  # later in `read/5`.
  #
  # A checkpoint is only ever an optimisation, and the log is whole either
  # way. So a checkpoint that cannot be about this log is not repaired or
  # trusted in part — it is dropped, and the log is read from the start.
  # Slower, and always right.
  defp describing({_facts, _at, offset, _prefix_crc}, binary) when offset > byte_size(binary),
    do: {[], 0, 0}

  defp describing({facts, at, offset, :none}, _binary), do: {facts, at, offset}

  defp describing({facts, at, offset, prefix_crc}, binary) do
    if :erlang.crc32(binary_part(binary, 0, offset)) == prefix_crc,
      do: {facts, at, offset},
      else: {[], 0, 0}
  end

  defp scan_from(binary, start, mode) when byte_size(binary) >= start do
    {records, ended} =
      binary
      |> binary_part(start, byte_size(binary) - start)
      |> scan(mode, start, [])

    {records, length(records), ended - start}
  end

  defp scan_from(_binary, _start, _mode), do: {[], 0, 0}
end
