defmodule Blazie.Lua.Shell do
  @moduledoc """
  Terminal ergonomics with no terminal anywhere — LT5(a), the small size.

  An agent already speaks `ls`, `cat`, `grep`, `wc`; what it needs from a
  shell is the vocabulary and the pipe, not a process. So the "shell" is a
  pure function over the workspace map: builtins in Elixir, `|` composes
  them, `>` writes a key, `*` globs over key names. No process is spawned,
  no host path exists to reach, and a hostile command line is at worst an
  unknown builtin answered with the shelf.

  Deliberately small. Real bash — busybox through the tiny-lasers wasm→BEAM
  transpiler — is the large size (docs/storage-plan.md, LT5b), gated on this
  proving insufficient in real agent use. Every builtin an agent asks for
  that is missing here is a data point for that verdict, which is why the
  unknown-command answer names the shelf.
  """

  @builtins ~w(ls cat grep echo wc head tail sort uniq rm mv)

  @doc """
  Run one command line over the files. Returns `{output, files_after}`.

  Pipes compose left to right; a trailing `> key` writes the output there
  (and the output of the LINE becomes empty, as a shell would).
  """
  @spec run(String.t(), map()) :: {String.t(), map()}
  def run(line, files) do
    {pipeline, redirect} = split_redirect(line)

    {out, files} =
      pipeline
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce({"", files}, fn command, {stdin, files} ->
        apply_command(command, stdin, files)
      end)

    case redirect do
      nil -> {String.trim_trailing(out, "\n") |> then(&{&1, files}) |> elem(0), files}
      key -> {"", Map.put(files, key, out)}
    end
  end

  defp split_redirect(line) do
    case String.split(line, ">", parts: 2) do
      [pipeline] -> {pipeline, nil}
      [pipeline, target] -> {pipeline, String.trim(target)}
    end
  end

  defp apply_command(command, stdin, files) do
    [verb | args] = tokenize(command)
    args = expand(args, files)

    case builtin(verb, args, stdin, files) do
      {out, files} -> {out, files}
      out when is_binary(out) -> {out, files}
    end
  end

  defp tokenize(command) do
    # Quotes hold a token together; otherwise whitespace splits. A shell's
    # lexer reduced to what builtins over a map can need.
    Regex.scan(~r/"([^"]*)"|'([^']*)'|(\S+)/, command)
    |> Enum.map(fn
      [_, dq] -> dq
      [_, "", sq] -> sq
      [_, "", "", bare] -> bare
    end)
  end

  # `*` globs over KEY NAMES — there are no directories, only keys that
  # contain slashes, so `data/*.txt` is a prefix+suffix match on keys.
  defp expand(args, files) do
    Enum.flat_map(args, fn arg ->
      if String.contains?(arg, "*") do
        pattern =
          arg
          |> Regex.escape()
          |> String.replace("\\*", "[^/]*")
          |> then(&Regex.compile!("^#{&1}$"))

        case files |> Map.keys() |> Enum.filter(&Regex.match?(pattern, &1)) |> Enum.sort() do
          [] -> [arg]
          matched -> matched
        end
      else
        [arg]
      end
    end)
  end

  # ── the builtins ─────────────────────────────────────────────────────────────

  defp builtin("ls", _args, _stdin, files) do
    files |> Map.keys() |> Enum.sort() |> Enum.join("\n")
  end

  defp builtin("echo", args, _stdin, _files), do: Enum.join(args, " ")

  defp builtin("cat", [], stdin, _files), do: stdin

  defp builtin("cat", args, _stdin, files) do
    Enum.map_join(args, "", fn key ->
      Map.get(files, key) || "cat: #{key}: no such key\n"
    end)
  end

  defp builtin("grep", args, stdin, files) do
    {count?, args} = flag(args, "-c")

    {pattern, sources} =
      case args do
        [p | rest] -> {p, rest}
        [] -> {"", []}
      end

    text = if sources == [], do: stdin, else: gather(sources, files)
    hits = text |> lines() |> Enum.filter(&String.contains?(&1, pattern))

    if count?, do: "#{length(hits)}\n", else: Enum.map_join(hits, "", &(&1 <> "\n"))
  end

  defp builtin("wc", args, stdin, files) do
    {_lines_only, args} = flag(args, "-l")
    text = if args == [], do: stdin, else: gather(args, files)
    "#{length(lines(text))}\n"
  end

  defp builtin("head", args, stdin, files), do: take(args, stdin, files, &Enum.take(&1, &2))

  defp builtin("tail", args, stdin, files),
    do: take(args, stdin, files, &Enum.take(&1, -&2))

  defp builtin("sort", args, stdin, files) do
    text = if args == [], do: stdin, else: gather(args, files)
    text |> lines() |> Enum.sort() |> Enum.map_join("", &(&1 <> "\n"))
  end

  defp builtin("uniq", args, stdin, files) do
    text = if args == [], do: stdin, else: gather(args, files)
    text |> lines() |> Enum.dedup() |> Enum.map_join("", &(&1 <> "\n"))
  end

  defp builtin("rm", args, _stdin, files), do: {"", Map.drop(files, args)}

  defp builtin("mv", [from, to], _stdin, files) do
    case Map.fetch(files, from) do
      {:ok, content} -> {"", files |> Map.delete(from) |> Map.put(to, content)}
      :error -> "mv: #{from}: no such key\n"
    end
  end

  defp builtin(verb, _args, _stdin, _files) do
    "#{verb}: not a builtin. This shell is #{Enum.join(@builtins, ", ")} over the " <>
      "workspace — pipes and > work; processes and the machine do not exist here.\n"
  end

  # ── small helpers ────────────────────────────────────────────────────────────

  defp flag(args, name) do
    {name in args, Enum.reject(args, &(&1 == name))}
  end

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
