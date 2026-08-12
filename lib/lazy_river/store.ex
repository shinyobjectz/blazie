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
  """

  @behaviour LazyRiver.Store

  @impl true
  def open(name, opts) do
    dir = Keyword.get(opts, :dir, "priv/ledgers")
    File.mkdir_p!(dir)
    path = Path.join(dir, filename(name))

    facts = path |> read_all() |> List.flatten()
    {:ok, io} = :file.open(path, [:append, :binary, :raw])

    {:ok, %{path: path, io: io, facts: facts, sync: Keyword.get(opts, :sync, false)}}
  end

  @impl true
  def append(state, facts) do
    payload = :erlang.term_to_binary(facts)
    record = <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>

    :ok = :file.write(state.io, record)
    if state.sync, do: :ok = :file.sync(state.io)

    {:ok, %{state | facts: state.facts ++ facts}}
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

  defp read_all(path) do
    case File.read(path) do
      {:ok, binary} -> scan(binary, [])
      {:error, :enoent} -> []
    end
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
end
