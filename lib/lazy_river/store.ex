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

  @impl true
  def append(facts, new), do: {:ok, facts ++ new}

  @impl true
  def replay(facts), do: facts

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
       facts: checkpoint ++ List.flatten(tail),
       sync: Keyword.get(opts, :sync, false),
       every: Keyword.get(opts, :checkpoint_every),
       # Tracked rather than asked for: a file opened in :append mode does not
       # move its position pointer on write, so position(:cur) is not where the
       # bytes went. Getting that wrong made a reopen read the tail twice.
       bytes: file_size(path),
       since: length(tail),
       checkpoint_at: at,
       records_scanned: scanned
     }}
  end

  @doc "What opening this store had to do. Observability, not vocabulary."
  @spec stats(map()) :: %{checkpoint_at: non_neg_integer(), records_scanned: non_neg_integer()}
  def stats(state),
    do: %{checkpoint_at: state.checkpoint_at, records_scanned: state.records_scanned}

  @impl true
  def append(state, facts) do
    payload = :erlang.term_to_binary(facts)
    record = <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>

    :ok = :file.write(state.io, record)
    if state.sync, do: :ok = :file.sync(state.io)

    state = %{
      state
      | facts: state.facts ++ facts,
        since: state.since + 1,
        bytes: state.bytes + byte_size(record)
    }

    {:ok, maybe_checkpoint(state)}
  end

  @impl true
  def replay(state), do: state.facts

  @impl true
  def close(state), do: :file.close(state.io)

  @doc "Where a ledger's facts are kept, for a name that may be any term."
  @spec filename(term()) :: String.t()
  def filename(name) do
    name |> :erlang.term_to_binary() |> Base.url_encode64(padding: false) |> Kernel.<>(".ledger")
  end

  defp scan(<<size::32, crc::32, payload::binary-size(size), rest::binary>>, acc) do
    if :erlang.crc32(payload) == crc do
      scan(rest, [:erlang.binary_to_term(payload) | acc])
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
    at = state.facts |> Enum.map(& &1.tx) |> Enum.max(fn -> 0 end)
    payload = :erlang.term_to_binary({at, state.bytes, state.facts})

    # Written beside the log and swapped in, so a crash mid-write leaves the
    # previous checkpoint rather than a torn one. The log is never touched.
    tmp = state.path <> ".checkpoint.writing"
    File.write!(tmp, <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>)
    File.rename!(tmp, state.path <> ".checkpoint")

    %{state | since: 0, checkpoint_at: at}
  end

  defp read_checkpoint(path) do
    with {:ok, <<size::32, crc::32, payload::binary-size(size)>>} <- File.read(path),
         true <- :erlang.crc32(payload) == crc,
         {at, offset, facts} <- :erlang.binary_to_term(payload) do
      {facts, at, offset}
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
