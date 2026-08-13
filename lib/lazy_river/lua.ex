defmodule LazyRiver.Lua do
  @moduledoc """
  The host that runs tenant code, and the world it hands them.

  Lua, because it is already everybody's. Twenty-two keywords, no toolchain, no
  build step, and an author — human or agent — arrives knowing it. That matters
  more here than it usually does: the seven words are the only vocabulary this
  database asks anyone to learn, and every word the authoring language would
  have added is a word that had to be taught. Lua adds none.

  ## Why not a sandbox

  Luerl is Lua implemented in Erlang, so a guest is ordinary BEAM code. There
  is no foreign runtime, nothing memory-unsafe, and no NIF whose infinite loop
  would block a scheduler thread. Isolation is not a wall around the guest; it
  is the absence of anything to reach. The host builds the world out of what it
  binds, and for a formula it binds nothing that touches the outside.

  That is the same doctrine the WebAssembly fence used and a cheaper way to get
  it. What it does *not* give free is spending: a loop still runs forever and a
  table still grows, so every guest runs in its own process with a deadline and
  a heap limit. Those are the two lines below, and they are the whole of what
  "sandboxing" means here.

  ## Two worlds, one difference

      Lua.run(source, as: :formula)   # no clock, no randomness, no outside
      Lua.run(source, as: :job)       # the same, plus http

  A formula is cached under a snapshot name forever, so an answer that differed
  on a second run would not be a slow bug — it would be a wrong answer with no
  expiry. That is why `os` and `math.random` are absent rather than discouraged.

  ## Determinism, and the one place it is not free

  Measured before committing to any of this: the same source gives the same
  answer across repeated runs, and tenant strings never become atoms. The one
  gap is `pairs`, whose order Lua leaves unspecified and Erlang maps do not
  promise across releases — so `facts/1` sorts. Nothing a formula returns can
  depend on iteration order, which makes determinism structural rather than a
  property of a version.
  """

  @type refusal :: %{problem: atom(), repair: String.t()}
  @type option :: {:as, :formula | :job} | {:deadline, pos_integer()} | {:heap, pos_integer()}

  # Long enough that an honest formula over a large snapshot finishes, short
  # enough that a mistake is found rather than paid for.
  @deadline 5_000

  # Words, not bytes — about 40MB on a 64-bit VM.
  @heap 5_000_000

  @doc """
  Run a chunk in the world named by `as:`, and hand back what it returned.

  Never raises and never blocks longer than `deadline:`. Everything that can go
  wrong comes back as a refusal carrying what to do about it.
  """
  @spec run(binary(), [option()]) :: {:ok, term()} | {:error, refusal()}
  def run(source, opts \\ []) do
    kind = Keyword.get(opts, :as, :formula)
    deadline = Keyword.get(opts, :deadline, @deadline)
    heap = Keyword.get(opts, :heap, @heap)

    # Captured here rather than inside, because inside `self()` is the guest.
    caller = self()

    # Unlinked on purpose. A guest killed for spending too much must not take
    # the caller with it, and a link would do exactly that.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
        send(caller, {self(), evaluate(source, kind)})
      end)

    await(pid, ref, deadline, heap)
  end

  @doc """
  The assertions a chunk returned, as `{id, attribute, value}`.

  Sorted, because `pairs` has no defined order and a formula that returned its
  facts in whatever order a map happened to hold them would answer differently
  on a different release of the VM. Sorting here means iteration order cannot
  reach an answer at all.
  """
  @spec facts(term()) :: [{term(), term(), term()}]
  def facts(nil), do: []

  def facts(rows) when is_list(rows) do
    rows
    |> Enum.map(fn
      {_index, row} -> triple(row)
      row -> triple(row)
    end)
    |> Enum.sort()
  end

  def facts(other) do
    raise ArgumentError,
          "A formula returns a list of {id, attribute, value} triples. This returned " <>
            "#{inspect(other)}."
  end

  defp triple(row) when is_list(row) do
    case Enum.map(row, fn {_k, v} -> v end) do
      [id, attribute, value] ->
        {id, attribute, value}

      other ->
        raise ArgumentError,
              "Every fact a formula returns is three things — an id, an attribute, and a " <>
                "value. This one had #{length(other)}: #{inspect(other)}."
    end
  end

  defp triple(other) do
    raise ArgumentError,
          "Every fact a formula returns is three things — an id, an attribute, and a " <>
            "value. This was #{inspect(other)}."
  end

  # ── the world ──────────────────────────────────────────────────────────────

  @doc """
  What a guest of this kind can see.

  Kept as a function so it is somewhere to look and somewhere for a test to
  assert on, rather than an absence that has to be inferred from what nobody
  wrote.
  """
  @spec world(:formula | :job) :: term()
  def world(kind) do
    :luerl.init()
    |> strip()
    |> grant(kind)
  end

  # Everything that reaches outside, reads a clock, or loads more code. `load`
  # and its family go too: a guest that can compile a string can rebuild
  # anything we removed if it ever gets a reference back.
  @removed ~w(os io package require load loadstring dofile loadfile)

  defp strip(state) do
    state =
      Enum.reduce(@removed, state, fn name, acc ->
        {_, acc} = :luerl.set_table_keys([name], nil, acc)
        acc
      end)

    # Randomness is the rest of the clock: an answer that differs run to run
    # cannot be cached under a name that promises it will not.
    Enum.reduce(["random", "randomseed"], state, fn name, acc ->
      {_, acc} = :luerl.set_table_keys(["math", name], nil, acc)
      acc
    end)
  end

  defp grant(state, :formula), do: state

  defp grant(state, :job) do
    # The table is made in Lua and the function bound into it, because Luerl
    # builds tables and does not encode one from an Erlang term holding a
    # function.
    {:ok, _, state} = :luerl.do("http = {}", state)
    {_, state} = :luerl.set_table_keys(["http", "get"], {:erl_func, &http_get/2}, state)
    state
  end

  # The one capability that makes a job a job. Deliberately small: a string in,
  # a string or nil out. A job that needs more should be given more one
  # deliberate binding at a time, because every widening is a hole in the fence.
  defp http_get([url | _], state) when is_binary(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 30_000}], []) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        {[to_string(body)], state}

      _ ->
        {[nil], state}
    end
  end

  defp http_get(_args, state), do: {[nil], state}

  # ── running one ────────────────────────────────────────────────────────────

  defp evaluate(source, kind) do
    state = world(kind)

    case :luerl.do(source, state) do
      {:ok, returned, after_state} -> {:ok, decode(returned, after_state)}
      {:error, why, _} -> {:error, not_lua(why)}
    end
  rescue
    # Lua's own errors arrive here too: `rescue` covers the :error class, which
    # is what Luerl raises a lua_error as.
    error -> {:error, raised(Exception.message(error))}
  catch
    kind_, reason -> {:error, raised("#{kind_}: #{inspect(reason)}")}
  end

  defp decode([], _state), do: nil
  defp decode([value | _], state), do: decode_one(value, state)

  defp decode_one({:tref, _} = table, state), do: :luerl.decode(table, state)
  defp decode_one(value, _state), do: value

  defp await(pid, ref, deadline, heap) do
    receive do
      {^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error,
         %{
           problem: :took_too_much_memory,
           repair:
             "This used more than #{heap} words of memory and was stopped. A formula holds " <>
               "what it is building; if that is larger than the answer, build less."
         }}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, raised(inspect(reason))}
    after
      deadline ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          0 -> :ok
        end

        {:error,
         %{
           problem: :took_too_long,
           repair:
             "This ran for #{deadline}ms without finishing and was stopped. Nothing here " <>
               "waits on anything, so a chunk that does not finish is looping."
         }}
    end
  end

  defp not_lua(why) do
    %{
      problem: :not_lua,
      repair: "This will not compile as Lua: #{inspect(why) |> String.slice(0, 300)}"
    }
  end

  defp raised(message) do
    %{problem: :raised, repair: "This raised while running: #{String.slice(message, 0, 300)}"}
  end
end
