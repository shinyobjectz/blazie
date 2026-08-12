defmodule LazyRiver.Keyring do
  @moduledoc """
  One key per subject, and the ability to destroy one.

  This is the only place in the system where forgetting is possible, which is
  why it is deliberately small and deliberately not a ledger. A ledger keeps
  things; this exists to lose them.

  Keys live outside the facts they protect, so a stolen ledger is noise and a
  backup of the ledger carries nothing to restore — the key was never in it.
  That is also why erasure needs no coordination with backups at all.

  ## Not yet true

  Keys are held in memory, so a restart is an accidental erasure of everything
  — which doctrine 16 says should only ever happen on purpose. A durable
  keyring outside the ledger is the next step, and it is the one piece of this
  that must not ship as it stands.
  """

  use GenServer

  @type subject :: term()

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "This subject's key, made the first time it is asked for."
  @spec key(subject()) :: binary()
  def key(subject), do: GenServer.call(__MODULE__, {:key, subject})

  @doc "This subject's key if it still exists, without making one."
  @spec peek(subject()) :: {:ok, binary()} | :forgotten
  def peek(subject), do: GenServer.call(__MODULE__, {:peek, subject})

  @doc """
  Destroy this subject's key.

  Idempotent, and irreversible. Everything encrypted under it is noise from
  here on, wherever it is — resident, on disk, or in a backup.
  """
  @spec forget(subject()) :: :ok
  def forget(subject), do: GenServer.call(__MODULE__, {:forget, subject})

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:key, subject}, _from, keys) do
    case Map.fetch(keys, subject) do
      {:ok, key} ->
        {:reply, key, keys}

      :error ->
        with key <- :crypto.strong_rand_bytes(32), do: {:reply, key, Map.put(keys, subject, key)}
    end
  end

  def handle_call({:peek, subject}, _from, keys) do
    {:reply, (Map.has_key?(keys, subject) && {:ok, keys[subject]}) || :forgotten, keys}
  end

  def handle_call({:forget, subject}, _from, keys), do: {:reply, :ok, Map.delete(keys, subject)}
end
