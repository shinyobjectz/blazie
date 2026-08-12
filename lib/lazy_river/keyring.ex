defmodule LazyRiver.Keyring do
  @moduledoc """
  Where key-encryption keys live, and the only place forgetting is possible.

  ## Two tiers, and why it matters where the second one goes

  A fresh **data key** encrypts each answer. A **key-encryption key** belonging
  to the subject wraps that data key, and the wrapped result is stored in the
  fact beside the ciphertext.

  That placement is the whole design. A wrapped key is noise without the KEK,
  so it can live in the ledger with everything else — it persists, checkpoints
  and backs up along with the facts it belongs to, and needs no store of its
  own. Which means **nothing durable is held in memory**, and the defect this
  replaces cannot happen: the previous keyring held the only copy of every key
  in a process, so restarting it erased every subject by accident.

  What still has to live somewhere deletion is real is one KEK per subject.
  That is now the whole of what a keyring is.

  ## An implementation, not a decision

  `wrap`, `unwrap`, `destroy`. `LazyRiver.Keyring.Local` keeps KEKs in a file
  under a master key from the environment, which is right for development and
  for an application with no real user data. A KMS-backed one is a module
  rather than a migration, and it is what should be in front of real users:
  destroying a key there is audited and irreversible, and a file can always
  come back from a restore.

  ## Erasure latency is the cache

  Unwrapped data keys are cached, or every read of a sealed fact is a round
  trip. That cache is also the window between erasing and being unreadable, so
  `destroy/1` drops it immediately rather than waiting for it to expire — the
  KEK going is what makes it permanent, the cache going is what makes it now.
  """

  @type subject :: term()
  @type ring :: term()

  @doc "Open the keyring. Whatever it needs to find its keys is in `opts`."
  @callback open(opts :: keyword()) :: {:ok, ring()} | {:error, term()}

  @doc "Wrap a data key under this subject's key, making one if there is none."
  @callback wrap(ring(), dek :: binary(), subject()) :: {:ok, binary()} | {:error, term()}

  @doc "Unwrap a data key, or say the subject's key is gone."
  @callback unwrap(ring(), wrapped :: binary(), subject()) :: {:ok, binary()} | :forgotten

  @doc "Destroy a subject's key. Irreversible."
  @callback destroy(ring(), subject()) :: :ok

  use GenServer

  @cache_for :timer.minutes(15)

  # ── the front ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Wrap a fresh data key for this subject."
  @spec wrap(binary(), subject()) :: {:ok, binary()} | {:error, term()}
  def wrap(dek, subject), do: GenServer.call(__MODULE__, {:wrap, dek, subject})

  @doc "Unwrap a data key, from cache if it is there."
  @spec unwrap(binary(), subject()) :: {:ok, binary()} | :forgotten
  def unwrap(wrapped, subject), do: GenServer.call(__MODULE__, {:unwrap, wrapped, subject})

  @doc """
  Destroy a subject's key and drop everything cached under it.

  The KEK going makes it permanent. The cache going makes it now.
  """
  @spec destroy(subject()) :: :ok
  def destroy(subject), do: GenServer.call(__MODULE__, {:destroy, subject})

  @doc false
  # Tests only: prove that restarting loses nothing, which is the point.
  def restart do
    GenServer.stop(__MODULE__)
    wait_for_restart(200)
  end

  defp wait_for_restart(0), do: {:error, :timeout}

  defp wait_for_restart(tries) do
    if Process.whereis(__MODULE__), do: :ok, else: Process.sleep(5) && wait_for_restart(tries - 1)
  end

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {module, ring_opts} =
      Keyword.get(
        opts,
        :keyring,
        {__MODULE__.Local, dir: Application.get_env(:lazy_river, :key_dir, "priv/keys")}
      )

    {:ok, ring} = module.open(ring_opts)
    {:ok, %{module: module, ring: ring, cache: %{}}}
  end

  @impl true
  def handle_call({:wrap, dek, subject}, _from, state) do
    {:reply, state.module.wrap(state.ring, dek, subject), state}
  end

  def handle_call({:unwrap, wrapped, subject}, _from, state) do
    case Map.get(state.cache, {subject, wrapped}) do
      {dek, until} ->
        if now() < until,
          do: {:reply, {:ok, dek}, state},
          else: unwrap_and_cache(wrapped, subject, state)

      nil ->
        unwrap_and_cache(wrapped, subject, state)
    end
  end

  def handle_call({:destroy, subject}, _from, state) do
    :ok = state.module.destroy(state.ring, subject)
    cache = state.cache |> Enum.reject(fn {{s, _}, _} -> s == subject end) |> Map.new()
    {:reply, :ok, %{state | cache: cache}}
  end

  defp unwrap_and_cache(wrapped, subject, state) do
    case state.module.unwrap(state.ring, wrapped, subject) do
      {:ok, dek} ->
        cache = Map.put(state.cache, {subject, wrapped}, {dek, now() + @cache_for})
        {:reply, {:ok, dek}, %{state | cache: cache}}

      :forgotten ->
        {:reply, :forgotten, state}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
