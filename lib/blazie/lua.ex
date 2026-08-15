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
    snapshot = Keyword.get(opts, :snapshot)

    # Captured here rather than inside, because inside `self()` is the guest.
    caller = self()

    # Unlinked on purpose. A guest killed for spending too much must not take
    # the caller with it, and a link would do exactly that.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
        send(caller, {self(), evaluate(source, kind, at, snapshot)})
      end)

    case await(pid, ref, deadline, heap) do
      {:ok, value, _wrote, _read} -> {:ok, value}
      other -> other
    end
  end

  @doc """
  Run a chunk over a WORKSPACE — files for a guest, with no filesystem anywhere.

  The workspace is a key→bytes map: seeded by the caller (the coding loop
  builds it from facts), mutated inside the guest's own process, and handed
  back whole. A guest path is never a host path — `../etc` is a funny key in
  the same map — so there is no filesystem to traverse out of, which is the
  tiny-lasers VFS lesson reduced to its blazie minimum (docs/storage-plan.md,
  LT1).

  The posture is the python sandbox's, kept exactly: `file.read/write/list`
  and a captured `print`, on the `:formula` base — no http, no blob, frozen
  clock. The fence stays the absence of everything else.

  Returns `{:ok, %{value:, printed:, files:}}` or a refusal.
  """
  @spec workspace(binary(), %{optional(String.t()) => binary()}, [option()]) ::
          {:ok, %{value: term(), printed: String.t(), files: map()}} | {:error, refusal()}
  def workspace(source, files, opts \\ []) when is_map(files) do
    deadline = Keyword.get(opts, :deadline, @deadline)
    heap = Keyword.get(opts, :heap, @heap)
    at = Keyword.get(opts, :at, 0)
    snapshot = Keyword.get(opts, :snapshot)

    with {:ok, prelude} <- preludes(Keyword.get(opts, :prelude, [])) do
      caller = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
          Process.put(:blazie_workspace, files)
          Process.put(:blazie_printed, [])
          send(caller, {self(), evaluate_workspace(source, at, snapshot, prelude)})
        end)

      case await(pid, ref, deadline, heap) do
        {:ok, value, printed, files_after} ->
          {:ok, %{value: value, printed: printed, files: files_after}}

        other ->
          other
      end
    end
  end

  # The shelf: vendored pure-Lua single-files in priv/lua, each smoke-tested
  # under Luerl before anything trusts it (docs/storage-plan.md, the guest
  # library shelf). Loaded by name into a global — no require, no package
  # path, no filesystem in the guest; the host reads the file.
  defp preludes(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      path = Path.join([Application.app_dir(:blazie, "priv"), "lua", "#{name}.lua"])

      if File.exists?(path) do
        {:cont, {:ok, acc ++ [{to_string(name), File.read!(path)}]}}
      else
        shelf =
          Path.join([Application.app_dir(:blazie, "priv"), "lua"])
          |> Path.join("*.lua")
          |> Path.wildcard()
          |> Enum.map_join(", ", &Path.basename(&1, ".lua"))

        {:halt,
         {:error,
          %{
            problem: :no_such_prelude,
            repair: "#{inspect(name)} is not on the shelf. Vendored preludes: #{shelf}."
          }}}
      end
    end)
  end

  @doc false
  # The same run, with what the guest wrote. `Blazie.Lua.Binding.run/3` is the way
  # to reach this; it is here because only this module knows how to spawn a
  # guest with a deadline around it.
  @spec collect(binary(), [option()]) ::
          {:ok, term(), [Blazie.Lua.Binding.assertion()], [keyword()]} | {:error, refusal()}
  def collect(source, opts \\ []) do
    kind = Keyword.get(opts, :as, :formula)
    deadline = Keyword.get(opts, :deadline, @deadline)
    heap = Keyword.get(opts, :heap, @heap)
    at = Keyword.get(opts, :at, 0)
    snapshot = Keyword.get(opts, :snapshot)
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
        send(caller, {self(), evaluate(source, kind, at, snapshot)})
      end)

    await(pid, ref, deadline, heap)
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

  @doc """
  The globals this host removes, so the world can keep them removed.

  `Blazie.Lua.Binding` puts a metatable on `_G` that turns any unknown name into
  an entity — which would quietly turn every one of these from "absent" into
  "an empty entity named io". The fence is the absence of anything to reach, and
  a name that answers with a table is not absent.
  """
  @spec removed() :: [String.t()]
  def removed, do: @removed ++ ~w(http)

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
  @doc """
  What a guest of this kind may reach — the ONE place doctrine 14 lives.

  A formula and a job run in the same sandbox and differ in exactly this: a
  job is handed the network (and the real clock its network answers travel
  with), a formula is not. `grant/3` reads this and hands back only what it
  names; `Blazie.Sandbox` honors the same map for a wasm guest, where WASI
  preview 1 makes `network` a promise the platform keeps for free (there are
  no sockets to grant). So "may this reach out" is answered by one function
  rather than inferred from two fences that have to agree.
  """
  @spec capabilities(:formula | :job) :: %{network: boolean(), clock: :frozen | :real}
  def capabilities(:formula), do: %{network: false, clock: :frozen}
  def capabilities(:job), do: %{network: true, clock: :real}

  defp grant(state, kind, at) do
    caps = capabilities(kind)

    state =
      case caps.clock do
        :frozen ->
          {_, s} = :luerl.set_table_keys(["os", "time"], {:erl_func, frozen(at)}, state)
          {_, s} = :luerl.set_table_keys(["os", "clock"], {:erl_func, frozen(0)}, s)
          # Deterministic, not fixed: a different snapshot is a different sequence.
          {:ok, _, s} = :luerl.do("math.randomseed(#{seed(at)})", s)
          s

        :real ->
          state
      end

    if caps.network, do: state |> grant_http() |> grant_blob(), else: state
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

  # Storing bytes reaches the network, so it is a job's and a formula cannot be
  # given it. Same argument as `http`: the fence is that a formula's world holds
  # nothing that reaches, not that a rule says no.
  defp grant_blob(state) do
    {_, state} = :luerl.set_table_keys(["blob"], {:erl_func, &store_blob/2}, state)
    state
  end

  # Bytes in, a reference out — key, hash, size — which is what gets written
  # down. The bytes never become a fact: five megabytes in the log forever is
  # the thing a blob exists to prevent.
  defp store_blob([bytes | rest], state) when is_binary(bytes) do
    case Application.get_env(:blazie, :blob_target) do
      nil ->
        {[
           nil,
           "This cluster has nowhere to put bytes. Set BLOB_BUCKET (with " <>
             "BLOB_ENDPOINT and credentials) or BLOB_DIR."
         ], state}

      {target, opts} ->
        media = with [m | _] <- rest, true <- is_binary(m), do: m, else: (_ -> nil)

        case Blazie.Blob.store(bytes, target, Keyword.put(opts, :media_type, media)) do
          {:ok, blob} ->
            {encoded, state} =
              :luerl.encode(
                [
                  {"key", blob.key},
                  {"hash", blob.hash},
                  {"bytes", blob.bytes},
                  {"media_type", blob.media_type}
                ],
                state
              )

            {[encoded, nil], state}

          {:error, refusal} ->
            {[nil, refusal.repair], state}
        end
    end
  end

  defp store_blob(_args, state),
    do: {[nil, "blob() takes the bytes to store, and optionally a media type."], state}

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

  defp wrote(nil), do: []
  defp wrote(_snapshot), do: Blazie.Lua.Binding.staged()

  # The workspace guest: the :formula base (frozen clock, nothing that
  # reaches) plus the file table and a captured print. Runs in the guest's
  # process, so the process dictionary IS the workspace for the duration.
  defp evaluate_workspace(source, at, snapshot, prelude \\ []) do
    state = world(:formula, at)
    state = if snapshot, do: Blazie.Lua.Binding.bind(state, snapshot), else: state
    state = grant_workspace(state)

    # Each vendored module becomes a global: `name = (function() ...source... end)()`
    # — the module-style `return m` at the file's end lands in the assignment.
    state =
      Enum.reduce(prelude, state, fn {name, module_source}, state ->
        {:ok, _, state} = :luerl.do("#{name} = (function()\n#{module_source}\nend)()", state)
        state
      end)

    case :luerl.do(source, state) do
      {:ok, returned, after_state} ->
        printed = Process.get(:blazie_printed, []) |> Enum.reverse() |> Enum.join("\n")
        {:ok, decode(returned, after_state), printed, Process.get(:blazie_workspace, %{})}

      {:error, why, _} ->
        {:error, not_lua(why)}
    end
  rescue
    error -> {:error, raised(Exception.message(error))}
  catch
    kind_, reason -> {:error, raised("#{kind_}: #{inspect(reason)}")}
  end

  # Luerl 1.5's string.gmatch raises badarg (found by the LT2 tests). Every
  # workspace guest gets this find-based shim so authored code and vendored
  # libraries speak ordinary Lua. Whole match, or the first capture when the
  # pattern has one — the shapes real code uses; a multi-capture iteration is
  # rare enough to write with string.find directly.
  @gmatch_shim """
  string.gmatch = function(s, pat)
    local pos = 1
    return function()
      if pos > #s + 1 then return nil end
      local a, b, cap = string.find(s, pat, pos)
      if a == nil then return nil end
      if b >= a then pos = b + 1 else pos = a + 1 end
      if cap ~= nil then return cap end
      return string.sub(s, a, b)
    end
  end
  """

  defp grant_workspace(state) do
    {:ok, _, state} = :luerl.do(@gmatch_shim, state)
    {:ok, _, state} = :luerl.do("file = {}", state)
    {_, state} = :luerl.set_table_keys(["file", "read"], {:erl_func, &ws_read/2}, state)
    {_, state} = :luerl.set_table_keys(["file", "write"], {:erl_func, &ws_write/2}, state)
    {_, state} = :luerl.set_table_keys(["file", "list"], {:erl_func, &ws_list/2}, state)
    {_, state} = :luerl.set_table_keys(["print"], {:erl_func, &ws_print/2}, state)
    state
  end

  defp ws_read([path | _], state) when is_binary(path) do
    {[Map.get(Process.get(:blazie_workspace, %{}), path)], state}
  end

  defp ws_read(_args, state), do: {[nil, "file.read takes the path to read."], state}

  defp ws_write([path, content | _], state) when is_binary(path) do
    case text(content) do
      nil ->
        {[nil, "file.write takes a path and the content to write."], state}

      bytes ->
        Process.put(:blazie_workspace, Map.put(Process.get(:blazie_workspace, %{}), path, bytes))
        {[true], state}
    end
  end

  defp ws_write(_args, state),
    do: {[nil, "file.write takes a path and the content to write."], state}

  defp ws_list(_args, state) do
    paths = Process.get(:blazie_workspace, %{}) |> Map.keys() |> Enum.sort()
    {encoded, state} = :luerl.encode(paths, state)
    {[encoded], state}
  end

  defp ws_print(args, state) do
    line = args |> Enum.map(&(text(&1) || inspect(&1))) |> Enum.join("\t")
    Process.put(:blazie_printed, [line | Process.get(:blazie_printed, [])])
    {[], state}
  end

  # A Lua value as printable text — what both print and file.write accept.
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(true), do: "true"
  defp text(false), do: "false"

  defp text(value) when is_float(value) do
    if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  defp text(_other), do: nil

  defp evaluate(source, kind, at, snapshot) do
    state = world(kind, at)
    # Bound only when a snapshot was given. Without one this is still the plain
    # host — useful for a chunk that computes rather than reads, and the reason
    # `run/2` did not have to change shape to gain a database.
    state = if snapshot, do: Blazie.Lua.Binding.bind(state, snapshot), else: state

    # Tracked inside the guest, because `track_reads` records into the process
    # dictionary of whoever is reading and the guest is a process of its own.
    # A subscription needs this: what a chunk read is what makes its answer
    # stale, and it is the only thing that can decide when to run it again.
    {result, read} =
      Blazie.Snapshot.track_reads(fn ->
        case :luerl.do(source, state) do
          {:ok, returned, after_state} -> {:ok, decode(returned, after_state)}
          {:error, why, _} -> {:error, not_lua(why)}
        end
      end)

    case result do
      {:ok, value} -> {:ok, value, wrote(snapshot), read}
      {:error, refusal} -> {:error, refusal}
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

  defp decode_one({:tref, _} = table, state),
    do: table |> :luerl.decode(state) |> jsonish()

  defp decode_one(value, _state), do: value

  # Luerl hands a table back as a list of {key, value} pairs, which is neither a
  # JSON object nor an array and encodes as neither — every non-empty table a
  # chunk returned failed to serialise. Lua has one data structure for both, so
  # the shape has to be decided here: keys exactly 1..n is a list, anything else
  # is an object. That is the rule every Lua-to-JSON bridge uses, and it carries
  # the same ambiguity they all do — an empty table could be either, and comes
  # back as a list.
  defp jsonish(pairs) when is_list(pairs) do
    if sequence?(pairs) do
      Enum.map(pairs, fn {_index, value} -> jsonish(value) end)
    else
      Map.new(pairs, fn {key, value} -> {to_string(key), jsonish(value)} end)
    end
  end

  defp jsonish(value), do: value

  defp sequence?([]), do: true

  defp sequence?(pairs) do
    pairs
    |> Enum.map(fn {key, _value} ->
      # Luerl numbers arrive as floats often enough that 1.0 and 1 both have to
      # count as the first index.
      if is_float(key) and key == trunc(key), do: trunc(key), else: key
    end)
    |> Kernel.==(Enum.to_list(1..length(pairs)))
  end

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
