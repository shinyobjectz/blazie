defmodule Blazie.Lua.Shell do
  @moduledoc """
  The agent's shell — C grammar, host tools, no terminal anywhere. TL1.

  The line is run by `washy` (tiny-lasers' no-fork shell, C compiled to
  wasm32-wasip1, vendored in priv/wasm): real grammar — pipes, `;`, `&&`,
  `||`, `>`/`>>`, `$VAR`, `for`/`while`/`if`, and a block piped onward —
  interpreted as ordinary BEAM code in THIS process, so the Lua guest's
  deadline and heap still bound it. Files are the same key→bytes map the
  Lua microkernel already holds: washy's `/work` preopen lands on the
  process-dict VFS, and this module bridges `:blazie_workspace` ↔ `:tl_vfs`.

  Programs come in species, resolved in one order:

    * washy's own C builtins — echo, grep (files, -c/-v/-i/-r/-l), rev,
      upper, lower, true, false, mkdir;
    * HOST programs — the Elixir builtins below (ls/cat/wc/head/tail/sort/
      uniq/rm/mv), riding tiny-lasers' `:tl_host_dispatch` seam: any command
      the C shell does not have becomes the host's to answer, mid-pipe;
    * registered wasm programs (`:tl_programs`) — the TL2 road, where
      busybox applets land as registry entries;
    * anything else answers the shelf, so every command an agent reaches
      for and misses is a recorded data point.

  Globs expand HERE, before washy sees the line: `*` matches over key names
  (never crossing `/`), quote-aware, sorted — the host knows the map, the C
  knows the grammar. There is still no process, no tty, and no host path:
  `cat /etc/passwd` is an absent key.
  """

  alias TinyLasers.Wasm

  @c_builtins ~w(echo grep rev upper lower true false mkdir)
  @host_builtins ~w(ls cat wc head tail sort uniq rm mv)

  # Every process-dict key a washy run touches — snapshotted and restored so
  # the caller's state (the Lua guest's own keys included) survives the run.
  @tl_keys [
    :tl_programs,
    :tl_vfs,
    :tl_backend,
    :tl_argv,
    :tl_stdin,
    :tl_out,
    :tl_host_dispatch,
    :tl_mem,
    :tl_mem_pages,
    :tl_max_pages,
    :tl_globals,
    :tl_table,
    :tl_fdmap,
    :tl_descs,
    :tl_nextfd,
    :tl_nextdesc,
    :tl_pipes,
    :tl_exec_out,
    :tl_exec_code,
    :tl_rt,
    :tl_last_fuel
  ]

  @doc """
  Run one shell line over the files. Returns `{output, files_after}`.

  Output is trimmed of its trailing newline (a shell's final `\\n` is the
  terminal's business, and there is no terminal); a redirect writes a key
  and the output of the line is empty, as a shell would have it.
  """
  @spec run(String.t(), map()) :: {String.t(), map()}
  def run(line, files) do
    saved = for key <- @tl_keys, do: {key, Process.get(key)}

    try do
      Process.put(:tl_backend, :map)
      Process.put(:tl_programs, programs())
      Process.put(:tl_vfs, files)
      Process.put(:tl_argv, ["sh", expand_globs(line, files)])
      Process.put(:tl_stdin, "")
      Process.put(:tl_out, [])
      Process.put(:tl_host_dispatch, &dispatch/2)

      out =
        try do
          {_res, out} = Wasm.call_io(washy(), "_start", [], transpile: false)
          out
        catch
          :throw, {:tl_exit, _code} ->
            Process.get(:tl_out, []) |> List.wrap() |> IO.iodata_to_binary()
        end

      {String.trim_trailing(out, "\n"), Process.get(:tl_vfs, files)}
    after
      for {key, value} <- saved do
        if value == nil, do: Process.delete(key), else: Process.put(key, value)
      end
    end
  end

  # The registered wasm programs — the TL2 road: real compiled tools, vendored
  # in priv/wasm/programs with provenance, each earning its entry from the
  # shelf-refusal telemetry. Decoded once per node. Today: sed (minised,
  # BSD-3-Clause). A program reads stdin and writes stdout; file arguments
  # are the applet's own affair and unresolved for now (no cwd in wasi-libc)
  # — pipe into it, which is what a shell line does anyway.
  defp programs do
    case :persistent_term.get({__MODULE__, :programs}, nil) do
      nil ->
        dir = Path.join(:code.priv_dir(:blazie), "wasm/programs")

        registry =
          for path <- Path.wildcard(Path.join(dir, "*.wasm")), into: %{} do
            {:ok, mod} = Wasm.decode(File.read!(path))
            {Path.basename(path, ".wasm"), mod}
          end

        :persistent_term.put({__MODULE__, :programs}, registry)
        registry

      registry ->
        registry
    end
  end

  # The washy module, decoded once per node.
  defp washy do
    case :persistent_term.get({__MODULE__, :washy}, nil) do
      nil ->
        path = Path.join(:code.priv_dir(:blazie), "wasm/washy_sh.wasm")
        {:ok, mod} = Wasm.decode(File.read!(path))
        :persistent_term.put({__MODULE__, :washy}, mod)
        mod

      mod ->
        mod
    end
  end

  # ── the host species (rides :tl_host_dispatch) ───────────────────────────────

  # Any command washy's C table lacks arrives here mid-pipe: our builtins
  # answer over the VFS; a name in :tl_programs steps aside so the wasm
  # program runs (the TL2 road); anything else answers the shelf.
  defp dispatch([verb | args], stdin) do
    files = Process.get(:tl_vfs, %{})

    cond do
      verb in @host_builtins ->
        {out, code, files_after} = host_builtin(verb, args, stdin, files)
        Process.put(:tl_vfs, files_after)
        {out, code}

      Map.has_key?(Process.get(:tl_programs) || %{}, verb) ->
        :not_host

      true ->
        shelf = @c_builtins ++ @host_builtins ++ Map.keys(Process.get(:tl_programs) || %{})

        {"#{verb}: not a builtin. This shell is #{Enum.join(Enum.sort(shelf), ", ")} " <>
           "over the workspace — pipes, for/if/while and > work; processes and the machine " <>
           "do not exist here.\n", 127}
    end
  end

  defp dispatch(_argv, _stdin), do: {"", 0}

  defp host_builtin("ls", _args, _stdin, files) do
    {files |> Map.keys() |> Enum.sort() |> Enum.map_join("", &(&1 <> "\n")), 0, files}
  end

  defp host_builtin("cat", [], stdin, files), do: {stdin, 0, files}

  defp host_builtin("cat", args, _stdin, files) do
    out =
      Enum.map_join(args, "", fn key ->
        Map.get(files, key) || "cat: #{key}: no such key\n"
      end)

    {out, 0, files}
  end

  defp host_builtin("wc", args, stdin, files) do
    {_l, args} = flag(args, "-l")
    text = if args == [], do: stdin, else: gather(args, files)
    {"#{length(lines(text))}\n", 0, files}
  end

  defp host_builtin("head", args, stdin, files),
    do: {take(args, stdin, files, &Enum.take(&1, &2)), 0, files}

  defp host_builtin("tail", args, stdin, files),
    do: {take(args, stdin, files, &Enum.take(&1, -&2)), 0, files}

  defp host_builtin("sort", args, stdin, files) do
    text = if args == [], do: stdin, else: gather(args, files)
    {text |> lines() |> Enum.sort() |> Enum.map_join("", &(&1 <> "\n")), 0, files}
  end

  defp host_builtin("uniq", args, stdin, files) do
    text = if args == [], do: stdin, else: gather(args, files)
    {text |> lines() |> Enum.dedup() |> Enum.map_join("", &(&1 <> "\n")), 0, files}
  end

  defp host_builtin("rm", args, _stdin, files), do: {"", 0, Map.drop(files, args)}

  defp host_builtin("mv", [from, to], _stdin, files) do
    case Map.fetch(files, from) do
      {:ok, content} -> {"", 0, files |> Map.delete(from) |> Map.put(to, content)}
      :error -> {"mv: #{from}: no such key\n", 1, files}
    end
  end

  defp host_builtin("mv", _args, _stdin, files),
    do: {"mv: takes a source and a destination\n", 1, files}

  # ── glob expansion (host-side: the map is ours, the grammar is C's) ──────────

  # `*` expands over KEY NAMES, never crossing `/`; quoted words are left
  # alone; a pattern matching nothing stays literal (the honest miss).
  defp expand_globs(line, files) do
    Regex.scan(~r/"[^"]*"|'[^']*'|\S+/, line)
    |> Enum.map(&hd/1)
    |> Enum.map(fn token ->
      if String.contains?(token, "*") and not quoted?(token) do
        case matches(token, files) do
          [] -> token
          matched -> Enum.join(matched, " ")
        end
      else
        token
      end
    end)
    |> Enum.join(" ")
  end

  defp quoted?(token), do: String.starts_with?(token, "\"") or String.starts_with?(token, "'")

  defp matches(pattern, files) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", "[^/]*")
      |> then(&Regex.compile!("^#{&1}$"))

    files |> Map.keys() |> Enum.filter(&Regex.match?(regex, &1)) |> Enum.sort()
  end

  # ── small helpers ────────────────────────────────────────────────────────────

  defp flag(args, name), do: {name in args, Enum.reject(args, &(&1 == name))}

  defp take(args, stdin, files, taker) do
    {n, sources} =
      case args do
        ["-" <> n | rest] -> {String.to_integer(n), rest}
        rest -> {10, rest}
      end

    text = if sources == [], do: stdin, else: gather(sources, files)
    text |> lines() |> taker.(n) |> Enum.map_join("", &(&1 <> "\n"))
  end

  defp gather(keys, files) do
    Enum.map_join(keys, "", fn key ->
      Map.get(files, key) || "#{key}: no such key\n"
    end)
  end

  defp lines(text), do: text |> String.split("\n") |> Enum.reject(&(&1 == ""))
end
