defmodule Blazie.Lua do
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

      Lua.run(source, as: :formula, at: tx)   # a clock that does not move
      Lua.run(source, as: :job, at: tx)       # the real clock, plus http

  A formula is cached under a snapshot name forever, so an answer that differed
  on a second run would not be a slow bug — it would be a wrong answer with no
  expiry.

  ## Substitution, not prohibition

  An earlier version deleted `os` and `math.random` outright. That is
  deterministic and it is also hostile: ordinary Lua crashes on a nil index
  somewhere inside a library the author did not write. Doctrine 19 draws the
  line where it belongs — what a formula may not have is a **value that differs
  run to run**, not a name it expects to find.

  So the clock is frozen to `at:`, the transaction the snapshot was read at, and
  randomness is seeded from it. Both are more useful than their absence: "as of
  this data" is a question a formula should be able to ask, and a deterministic
  `math.random` is a usable sampler rather than a missing function. A different
  snapshot gives a different sequence, so this is deterministic rather than
  fixed.

  What is still gone is everything that touches the machine — `io`, `package`,
  the `load` family, and the half of `os` that runs commands, reads the
  environment or moves files. `os.date` goes with them: formatting a moment for
  a human is presentation, and a formula produces facts.

  A job keeps the real clock. Its answer happened once and was never
  reproducible, so there is nothing for a frozen one to protect.

  ## Determinism, and the one place it is not free

  Measured before committing to any of this: the same source gives the same
  answer across repeated runs, and tenant strings never become atoms. The one
  gap is `pairs`, whose order Lua leaves unspecified and Erlang maps do not
  promise across releases — so `facts/1` sorts. Nothing a formula returns can
  depend on iteration order, which makes determinism structural rather than a
  property of a version.
  """

  @type refusal :: %{problem: atom(), repair: String.t()}
  @type option ::
          {:as, :formula | :job}
          | {:deadline, pos_integer()}
          | {:heap, pos_integer()}
          | {:at, integer()}

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
    at = Keyword.get(opts, :at, 0)

    # Captured here rather than inside, because inside `self()` is the guest.
    caller = self()

    # Unlinked on purpose. A guest killed for spending too much must not take
    # the caller with it, and a link would do exactly that.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
        send(caller, {self(), evaluate(source, kind, at)})
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
  @spec world(:formula | :job, integer()) :: term()
  def world(kind, at \\ 0) do
    :luerl.init()
    |> strip()
    |> grant(kind, at)
  end

  # Everything that reaches outside or loads more code. `load` and its family go
  # too: a guest that can compile a string could rebuild anything removed here
  # if it ever got a reference back.
  @removed ~w(io package require load loadstring dofile loadfile)

  # The parts of `os` that touch the machine. `date` goes with them for a
  # different reason: formatting a moment for a human is presentation, and a
  # formula produces facts.
  @removed_from_os ~w(execute exit getenv remove rename tmpname date)

  defp strip(state) do
    state =
      Enum.reduce(@removed, state, fn name, acc ->
        {_, acc} = :luerl.set_table_keys([name], nil, acc)
        acc
      end)

    Enum.reduce(@removed_from_os, state, fn name, acc ->
      {_, acc} = :luerl.set_table_keys(["os", name], nil, acc)
      acc
    end)
  end

  # Doctrine 19. What a formula may not have is a value that differs run to run
  # — not a name it expects to find. An earlier version deleted `os` and
  # `math.random` outright, which made ordinary Lua crash on its way to being
  # deterministic. Freezing the clock to the snapshot's transaction and seeding
  # randomness from it makes the same code answer, and answer the same forever.
  #
  # The substituted clock is also more useful than no clock: "as of this data"
  # is a question a formula should be able to ask, and `at` is exactly that
  # moment rather than the moment somebody happened to run it.
  defp grant(state, :formula, at) do
    {_, state} = :luerl.set_table_keys(["os", "time"], {:erl_func, frozen(at)}, state)
    {_, state} = :luerl.set_table_keys(["os", "clock"], {:erl_func, frozen(0)}, state)

    # Deterministic, not fixed: a different snapshot is a different sequence.
    {:ok, _, state} = :luerl.do("math.randomseed(#{seed(at)})", state)
    state
  end

  # A job keeps the real ones. Its answer happened once and was never
  # reproducible, so there is nothing for a frozen clock to protect.
  defp grant(state, :job, _at) do
    state
    |> grant_http()
  end

  defp frozen(value), do: fn _args, state -> {[value], state} end

  # Stable for a moment, spread across moments — consecutive transactions should
  # not give neighbouring sequences.
  defp seed(at), do: :erlang.phash2({__MODULE__, at}, 2_147_483_647)

  defp grant_http(state) do
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

  defp evaluate(source, kind, at) do
    state = world(kind, at)

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
