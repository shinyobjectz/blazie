defmodule LazyRiver.Store do
  @moduledoc """
  Where a ledger's facts actually live.

  A ledger is an append-only sequence, so a store only has to do three things:
  take a transaction's facts, hand them all back in order, and close. That is a
  small enough surface that a file on disk and an LSM on object storage
  implement the same three functions, which is what keeps the storage decision
  a configuration line rather than a rewrite.

  Nothing above this line knows which one is in use. The ledger is the seam.
  """

  alias LazyRiver.Fact

  @type state :: term()

  @doc "Open storage for a ledger, replaying whatever is already there."
  @callback open(name :: term(), opts :: keyword()) :: {:ok, state()}

  @doc "Record one transaction's facts. Returning means recorded."
  @callback append(state(), [Fact.t()]) :: {:ok, state()}

  @doc "Every fact ever recorded, oldest first."
  @callback replay(state()) :: [Fact.t()]

  @doc "Release whatever was held. Not erasure — erasure destroys a key."
  @callback close(state()) :: :ok
end

defmodule LazyRiver.Store.Memory do
  @moduledoc """
  Facts in the process holding them. Fast, isolated, and gone on close.

  Right for tests and for a ledger nobody needs to survive a restart. Wrong for
  anything else, which is why closing one is erasure by accident.
  """

  @behaviour LazyRiver.Store

  @impl true
  def open(_name, _opts), do: {:ok, []}

  # Newest first, so appending is O(batch) rather than O(everything). `++`
  # copies its left operand, so the obvious `facts ++ new` re-copies the whole
  # history on every write and makes a ledger quadratic in its own length.
  @impl true
  def append(facts, new), do: {:ok, Enum.reverse(new) ++ facts}

  @impl true
  def replay(facts), do: Enum.reverse(facts)

  @impl true
  def close(_facts), do: :ok
end

defmodule LazyRiver.Store.File do
  @moduledoc """
  An append-only file, which is what a ledger already is.

  One record per transaction, so atomicity is real rather than implied:

      <<size::32, crc::32, payload::binary-size(size)>>

  The payload is one transaction's facts. On replay the file is scanned
  forward, and a record whose length runs past the end or whose checksum does
  not match is where reading stops — a process killed mid-write leaves a torn
  tail, and everything after a torn record is unreadable by definition.
  Discarding it loses exactly the transaction that never completed.

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
  """

  @behaviour LazyRiver.Store

  alias LazyRiver.Fact

  # How much of the log may be un-checkpointed before writing another one:
  # half of what is already checkpointed. Lower means opening scans less and
  # more total bytes are written; higher is the reverse. Both are constant
  # factors — the point is that neither grows with the length of the log.
  @growth 0.5

  @impl true
  def open(name, opts) do
    dir = Keyword.get(opts, :dir, "priv/ledgers")
    File.mkdir_p!(dir)
    path = Path.join(dir, filename(name))

    {checkpoint, at, offset} = read_checkpoint(path <> ".checkpoint")
    {tail, scanned} = read_from(path, offset)
    {:ok, io} = :file.open(path, [:append, :binary, :raw])

    {:ok,
     %{
       path: path,
       io: io,
       # Newest first. See `append/2`.
       facts: Enum.reverse(checkpoint ++ List.flatten(tail)),
       sync: Keyword.get(opts, :sync, false),
       every: Keyword.get(opts, :checkpoint_every),
       growth: Keyword.get(opts, :checkpoint_growth, @growth),
       # Tracked rather than asked for: a file opened in :append mode does not
       # move its position pointer on write, so position(:cur) is not where the
       # bytes went. Getting that wrong made a reopen read the tail twice.
       bytes: file_size(path),
       since: length(tail),
       checkpoint_at: at,
       checkpoint_bytes: offset,
       checkpoints_written: 0,
       records_scanned: scanned
     }}
  end

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
    record = <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>

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
        bytes: state.bytes + byte_size(record)
    }

    {:ok, maybe_checkpoint(state)}
  end

  @impl true
  def replay(state), do: Enum.reverse(state.facts)

  @impl true
  def close(state), do: :file.close(state.io)

  @doc "Where a ledger's facts are kept, for a name that may be any term."
  @spec filename(term()) :: String.t()
  def filename(name) do
    name |> :erlang.term_to_binary() |> Base.url_encode64(padding: false) |> Kernel.<>(".ledger")
  end

  defp scan(<<size::32, crc::32, payload::binary-size(size), rest::binary>>, acc) do
    if :erlang.crc32(payload) == crc do
      # Whatever row shape this transaction was written under. Nothing is ever
      # rewritten, so old shapes are still on disk and still have to answer.
      transaction = payload |> :erlang.binary_to_term() |> Enum.map(&Fact.from_stored/1)
      scan(rest, [transaction | acc])
    else
      # A torn record. Everything past it is unreadable, so this is the end.
      Enum.reverse(acc)
    end
  end

  defp scan(_incomplete_tail, acc), do: Enum.reverse(acc)

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
    payload = :erlang.term_to_binary({at, state.bytes, facts})

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
         true <- :erlang.crc32(payload) == crc,
         {at, offset, facts} <- :erlang.binary_to_term(payload) do
      # A checkpoint is as old as the log it summarises, so it carries old
      # shapes too.
      {Enum.map(facts, &Fact.from_stored/1), at, offset}
    else
      # No checkpoint, or one that did not survive. The log is whole either
      # way, so reading from the start is always correct — just slower.
      _ -> {[], 0, 0}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, :enoent} -> 0
    end
  end

  defp read_from(path, offset) do
    case File.read(path) do
      {:ok, binary} ->
        records = binary |> binary_part(offset, byte_size(binary) - offset) |> scan([])
        {records, length(records)}

      {:error, :enoent} ->
        {[], 0}
    end
  end
end
