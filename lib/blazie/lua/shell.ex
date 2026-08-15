defmodule Blazie.Lua.Shell do
  @moduledoc """
  The agent's shell — grammar, tools, and filesystem, all native BEAM code.

  Luerl's lesson, applied at shell scale: don't host a foreign runtime,
  implement the semantics as ordinary Erlang/Elixir and let the BEAM provide
  the speed and the fence. The grammar is a small recursive-descent parser —
  pipes, `;`, `&&`/`||`, `>`/`>>`, `$VAR`, `for`/`while`/`if`, and a block
  piped or redirected onward — and every tool is an Elixir function over the
  workspace map. Measured before deciding (docs/storage-plan.md): the
  C-compiled-to-wasm route ran 60× SLOWER than BEAM-native on string work,
  so the wasm engine was removed and the tools came home.

  The whole shell is a pure function: `run(line, files) → {output, files}`.
  No process is spawned, no tty exists, no host path is reachable — a
  traversal-shaped path is a funny key in the same map — and the caller's
  process state is untouched because nothing here touches process state.
  Inside a Lua guest, `sh(...)` runs THIS, under the guest's own deadline
  and heap.

  An unknown command answers the shelf, so every tool an agent reaches for
  and misses stays a recorded data point for what to implement next.
  """

  @type files :: %{optional(String.t()) => binary()}

  @builtins ~w(cat echo false grep head ls mkdir mv rev rm sed seq sort tail true uniq upper lower wc)

  @doc """
  Run one shell line over the files. Returns `{output, files_after}`.

  Output is trimmed of its trailing newline (a shell's final `\\n` is the
  terminal's business, and there is no terminal); a redirect writes a key
  and the output of that pipeline is empty, as a shell would have it.
  """
  @spec run(String.t(), files()) :: {String.t(), files()}
  def run(line, files) do
    {stmts, _rest} = line |> lex() |> parse_script([])
    {out, state, _rc} = eval_stmts(stmts, %{files: files, vars: %{}}, "")
    {out |> IO.iodata_to_binary() |> String.trim_trailing("\n"), state.files}
  end

  # ── lexer ────────────────────────────────────────────────────────────────────
  # Tokens: {:w, word, :bare | :quoted} · :semi · :pipe · :andand · :oror ·
  # :gt · :gtgt. Quotes hold a token together; single quotes also suppress
  # `$` expansion later.

  defp lex(line), do: lex(String.to_charlist(line), [])

  defp lex([], acc), do: Enum.reverse(acc)
  defp lex([c | rest], acc) when c in [?\s, ?\t], do: lex(rest, acc)
  defp lex([c | rest], acc) when c in [?;, ?\n], do: lex(rest, [:semi | acc])
  defp lex([?&, ?& | rest], acc), do: lex(rest, [:andand | acc])
  defp lex([?|, ?| | rest], acc), do: lex(rest, [:oror | acc])
  defp lex([?| | rest], acc), do: lex(rest, [:pipe | acc])
  defp lex([?>, ?> | rest], acc), do: lex(rest, [:gtgt | acc])
  defp lex([?> | rest], acc), do: lex(rest, [:gt | acc])

  defp lex([q | rest], acc) when q in [?', ?"] do
    {word, rest} = Enum.split_while(rest, &(&1 != q))

    rest =
      case rest do
        [^q | r] -> r
        [] -> []
      end

    kind = if q == ?', do: :quoted, else: :bare
    lex(rest, [{:w, List.to_string(word), kind} | acc])
  end

  defp lex(chars, acc) do
    {word, rest} = split_word(chars, [])
    lex(rest, [{:w, List.to_string(word), :bare} | acc])
  end

  defp split_word([], acc), do: {Enum.reverse(acc), []}

  defp split_word([c | _] = rest, acc) when c in [?\s, ?\t, ?;, ?\n, ?|, ?>],
    do: {Enum.reverse(acc), rest}

  defp split_word([?&, ?& | _] = rest, acc), do: {Enum.reverse(acc), rest}
  defp split_word([c | rest], acc), do: split_word(rest, [c | acc])

  # ── parser ───────────────────────────────────────────────────────────────────
  # script := stmt*        (stmts separated by :semi; a stop word ends a body)
  # stmt   := for | while | if | NAME=VALUE | chain
  # chain  := pipeline ((&& | ||) pipeline)*
  # pipeline := cmd (| cmd)* [> word | >> word]
  # for/while/if bodies recurse; a block may carry a TAIL — `done | cmd…` or
  # `done > key` — feeding the block's whole output onward.

  @stops ~w(done else fi then)

  defp parse_script(toks, stmts) do
    case toks do
      [] ->
        {Enum.reverse(stmts), []}

      [:semi | rest] ->
        parse_script(rest, stmts)

      [{:w, stop, :bare} | _] when stop in @stops ->
        {Enum.reverse(stmts), toks}

      _ ->
        {stmt, rest} = parse_stmt(toks)
        parse_script(rest, [stmt | stmts])
    end
  end

  defp parse_stmt([{:w, "for", :bare}, {:w, name, _}, {:w, "in", :bare} | rest]) do
    {words, rest} = Enum.split_while(rest, &match?({:w, _, _}, &1))
    rest = skip_semis(rest)
    {body, rest} = parse_body(rest)
    {tail, rest} = parse_tail(rest)
    {{:for, name, words, body, tail}, rest}
  end

  defp parse_stmt([{:w, "while", :bare} | rest]) do
    {cond_chain, rest} = parse_chain_until(rest, "do")
    rest = skip_semis(rest)
    {body, rest} = parse_body(rest)
    {tail, rest} = parse_tail(rest)
    {{:while, cond_chain, body, tail}, rest}
  end

  defp parse_stmt([{:w, "if", :bare} | rest]) do
    {cond_chain, rest} = parse_chain_until(rest, "then")

    rest =
      case skip_semis(rest) do
        [{:w, "then", :bare} | r] -> r
        r -> r
      end

    {then_body, rest} = parse_script(skip_semis(rest), [])

    {else_body, rest} =
      case rest do
        [{:w, "else", :bare} | r] -> parse_script(skip_semis(r), [])
        _ -> {[], rest}
      end

    rest =
      case rest do
        [{:w, "fi", :bare} | r] -> r
        r -> r
      end

    {tail, rest} = parse_tail(rest)
    {{:if, cond_chain, then_body, else_body, tail}, rest}
  end

  defp parse_stmt([{:w, word, :bare} | rest] = toks) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, word) and assign_alone?(rest) do
      [name, value] = String.split(word, "=", parts: 2)
      {{:assign, name, value}, rest}
    else
      parse_chain(toks)
    end
  end

  defp parse_stmt(toks), do: parse_chain(toks)

  defp assign_alone?([]), do: true
  defp assign_alone?([:semi | _]), do: true
  defp assign_alone?([:andand | _]), do: true
  defp assign_alone?([:oror | _]), do: true
  defp assign_alone?(_), do: false

  # `for`/`while`'s body: `do` … matching `done` (inner blocks recurse away).
  defp parse_body([{:w, "do", :bare} | rest]) do
    {body, rest} = parse_script(skip_semis(rest), [])

    case rest do
      [{:w, "done", :bare} | r] -> {body, r}
      r -> {body, r}
    end
  end

  defp parse_body(rest), do: {[], rest}

  # A condition is a chain read up to (not consuming) `stop_word`.
  defp parse_chain_until(toks, stop_word) do
    {taken, rest} =
      Enum.split_while(toks, fn
        {:w, ^stop_word, :bare} -> false
        _ -> true
      end)

    # Drop a trailing :semi before the stop word (`if true; then`).
    taken = taken |> Enum.reverse() |> Enum.drop_while(&(&1 == :semi)) |> Enum.reverse()
    {chain, _} = parse_chain(taken)
    {chain, rest}
  end

  defp parse_chain(toks) do
    {first, rest} = parse_pipeline(toks)
    parse_chain_rest(rest, [{nil, first}])
  end

  defp parse_chain_rest([:andand | rest], acc) do
    {pl, rest} = parse_pipeline(rest)
    parse_chain_rest(rest, [{:andand, pl} | acc])
  end

  defp parse_chain_rest([:oror | rest], acc) do
    {pl, rest} = parse_pipeline(rest)
    parse_chain_rest(rest, [{:oror, pl} | acc])
  end

  defp parse_chain_rest(rest, acc), do: {{:chain, Enum.reverse(acc)}, rest}

  defp parse_pipeline(toks) do
    {cmds, rest} = parse_cmds(toks, [[]], [])
    {redirect, rest} = parse_redirect(rest)
    {{:pipeline, cmds, redirect}, rest}
  end

  defp parse_cmds([{:w, _, _} = w | rest], [cur | done], all) do
    parse_cmds(rest, [[w | cur] | done], all)
  end

  defp parse_cmds([:pipe | rest], [cur | done], all) do
    parse_cmds(rest, [[] | [Enum.reverse(cur) | done]] ++ all, [])
  end

  defp parse_cmds(rest, [cur | done], _all) do
    cmds = Enum.reverse([Enum.reverse(cur) | done]) |> Enum.reject(&(&1 == []))
    {cmds, rest}
  end

  defp parse_redirect([:gt, {:w, key, _} | rest]), do: {{:write, key}, rest}
  defp parse_redirect([:gtgt, {:w, key, _} | rest]), do: {{:append, key}, rest}
  defp parse_redirect(rest), do: {nil, rest}

  # A block's tail: `| cmd…` or a redirect, feeding the block's output onward.
  defp parse_tail([:pipe | rest]) do
    {cmds, rest} = parse_cmds(rest, [[]], [])
    {redirect, rest} = parse_redirect(rest)
    {{:pipeline, cmds, redirect}, rest}
  end

  defp parse_tail([:gt, {:w, key, _} | rest]), do: {{:pipeline, [], {:write, key}}, rest}
  defp parse_tail([:gtgt, {:w, key, _} | rest]), do: {{:pipeline, [], {:append, key}}, rest}
  defp parse_tail(rest), do: {nil, rest}

  defp skip_semis([:semi | rest]), do: skip_semis(rest)
  defp skip_semis(rest), do: rest

  # ── evaluator ────────────────────────────────────────────────────────────────

  defp eval_stmts(stmts, state, extern_in) do
    Enum.reduce(stmts, {[], state, 0}, fn stmt, {out, state, _rc} ->
      {o, state, rc} = eval_stmt(stmt, state, if(out == [], do: extern_in, else: ""))
      {[out, o], state, rc}
    end)
  end

  defp eval_stmt({:assign, name, value}, state, _in) do
    {[], put_in(state.vars[name], expand_vars(value, state.vars)), 0}
  end

  defp eval_stmt({:chain, links}, state, extern_in) do
    Enum.reduce(links, {[], state, 0}, fn {conn, pipeline}, {out, state, rc} ->
      skip? = (conn == :andand and rc != 0) or (conn == :oror and rc == 0)

      if skip? do
        {out, state, rc}
      else
        {o, state, rc} = eval_pipeline(pipeline, state, if(out == [], do: extern_in, else: ""))
        {[out, o], state, rc}
      end
    end)
  end

  defp eval_stmt({:for, name, words, body, tail}, state, _in) do
    {captured, state, rc} =
      Enum.reduce(words, {[], state, 0}, fn {:w, w, kind}, {out, state, _rc} ->
        value = if kind == :quoted, do: w, else: expand_vars(w, state.vars)
        state = put_in(state.vars[name], value)
        {o, state, rc} = eval_stmts(body, state, "")
        {[out, o], state, rc}
      end)

    run_tail(tail, captured, state, rc)
  end

  defp eval_stmt({:while, cond_chain, body, tail}, state, _in) do
    {captured, state, rc} = while_loop(cond_chain, body, state, [], 0, 1_000_000)
    run_tail(tail, captured, state, rc)
  end

  defp eval_stmt({:if, cond_chain, then_body, else_body, tail}, state, _in) do
    {_cond_out, state, cond_rc} = eval_stmt(cond_chain, state, "")

    {captured, state, rc} =
      if cond_rc == 0,
        do: eval_stmts(then_body, state, ""),
        else: eval_stmts(else_body, state, "")

    run_tail(tail, captured, state, rc)
  end

  defp while_loop(_cond, _body, state, out, rc, 0), do: {out, state, rc}

  defp while_loop(cond_chain, body, state, out, rc, guard) do
    {_o, state, cond_rc} = eval_stmt(cond_chain, state, "")

    if cond_rc == 0 do
      {o, state, rc} = eval_stmts(body, state, "")
      while_loop(cond_chain, body, state, [out, o], rc, guard - 1)
    else
      {out, state, rc}
    end
  end

  defp run_tail(nil, captured, state, rc), do: {captured, state, rc}

  defp run_tail({:pipeline, _, _} = pipeline, captured, state, _rc) do
    eval_pipeline(pipeline, state, IO.iodata_to_binary(captured))
  end

  defp eval_pipeline({:pipeline, cmds, redirect}, state, stdin0) do
    {out, state, rc} =
      Enum.reduce(cmds, {stdin0, state, 0}, fn cmd, {stdin, state, _rc} ->
        argv = expand_cmd(cmd, state)
        run_cmd(argv, to_string(stdin), state)
      end)

    out = IO.iodata_to_binary([out])

    case redirect do
      nil -> {out, state, rc}
      {:write, key} -> {"", put_in(state.files[key], out), rc}
      {:append, key} -> {"", update_in(state.files[key], &((&1 || "") <> out)), rc}
    end
  end

  # ── expansion: $VAR, then globs, per word ────────────────────────────────────

  defp expand_cmd(cmd, state) do
    Enum.flat_map(cmd, fn
      {:w, w, :quoted} -> [w]
      {:w, w, :bare} -> w |> expand_vars(state.vars) |> expand_glob(state.files)
    end)
  end

  defp expand_vars(word, vars) do
    Regex.replace(~r/\$\{(\w+)\}|\$(\w+)/, word, fn _, braced, bare ->
      Map.get(vars, if(braced != "", do: braced, else: bare), "")
    end)
  end

  # `*` matches over KEY NAMES, never crossing `/`; no match stays literal.
  defp expand_glob(word, files) do
    if String.contains?(word, "*") do
      regex =
        word
        |> Regex.escape()
        |> String.replace("\\*", "[^/]*")
        |> then(&Regex.compile!("^#{&1}$"))

      case files |> Map.keys() |> Enum.filter(&Regex.match?(regex, &1)) |> Enum.sort() do
        [] -> [word]
        matched -> matched
      end
    else
      [word]
    end
  end

  # ── the tools ────────────────────────────────────────────────────────────────

  defp run_cmd([], stdin, state), do: {stdin, state, 0}

  defp run_cmd([verb | args], stdin, state) do
    if verb in @builtins do
      builtin(verb, args, stdin, state)
    else
      {"#{verb}: not a builtin. This shell is #{Enum.join(@builtins, ", ")} over the " <>
         "workspace — pipes, for/if/while and > work; processes and the machine do not " <>
         "exist here.\n", state, 127}
    end
  end

  defp builtin("echo", args, _stdin, state), do: {Enum.join(args, " ") <> "\n", state, 0}
  defp builtin("true", _a, _s, state), do: {"", state, 0}
  defp builtin("false", _a, _s, state), do: {"", state, 1}
  defp builtin("mkdir", _a, _s, state), do: {"", state, 0}
  defp builtin("upper", _a, stdin, state), do: {String.upcase(stdin), state, 0}
  defp builtin("lower", _a, stdin, state), do: {String.downcase(stdin), state, 0}

  defp builtin("rev", _a, stdin, state) do
    out = stdin |> lines() |> Enum.map_join("", &(String.reverse(&1) <> "\n"))
    {out, state, 0}
  end

  defp builtin("ls", _args, _stdin, state) do
    {state.files |> Map.keys() |> Enum.sort() |> Enum.map_join("", &(&1 <> "\n")), state, 0}
  end

  defp builtin("cat", [], stdin, state), do: {stdin, state, 0}

  defp builtin("cat", args, _stdin, state) do
    out =
      Enum.map_join(args, "", fn key ->
        Map.get(state.files, key) || "cat: #{key}: no such key\n"
      end)

    {out, state, 0}
  end

  defp builtin("grep", args, stdin, state) do
    {flags, args} = Enum.split_with(args, &String.starts_with?(&1, "-"))
    count? = "-c" in flags
    invert? = "-v" in flags
    icase? = "-i" in flags

    case args do
      [] ->
        {"grep: need a pattern\n", state, 2}

      [pattern | sources] ->
        text = if sources == [], do: stdin, else: gather(sources, state.files)
        {hay, needle} = if icase?, do: {nil, String.downcase(pattern)}, else: {nil, pattern}
        _ = hay

        hits =
          text
          |> lines()
          |> Enum.filter(fn line ->
            l = if icase?, do: String.downcase(line), else: line
            String.contains?(l, needle) != invert?
          end)

        out = if count?, do: "#{length(hits)}\n", else: Enum.map_join(hits, "", &(&1 <> "\n"))
        {out, state, if(hits == [], do: 1, else: 0)}
    end
  end

  defp builtin("wc", args, stdin, state) do
    {_l, args} = {"-l" in args, Enum.reject(args, &(&1 == "-l"))}
    text = if args == [], do: stdin, else: gather(args, state.files)
    {"#{length(lines(text))}\n", state, 0}
  end

  defp builtin("head", args, stdin, state),
    do: {take(args, stdin, state.files, &Enum.take(&1, &2)), state, 0}

  defp builtin("tail", args, stdin, state),
    do: {take(args, stdin, state.files, &Enum.take(&1, -&2)), state, 0}

  defp builtin("sort", args, stdin, state) do
    text = if args == [], do: stdin, else: gather(args, state.files)
    {text |> lines() |> Enum.sort() |> Enum.map_join("", &(&1 <> "\n")), state, 0}
  end

  defp builtin("uniq", args, stdin, state) do
    text = if args == [], do: stdin, else: gather(args, state.files)
    {text |> lines() |> Enum.dedup() |> Enum.map_join("", &(&1 <> "\n")), state, 0}
  end

  defp builtin("rm", args, _stdin, state),
    do: {"", update_in(state.files, &Map.drop(&1, args)), 0}

  defp builtin("mv", [from, to], _stdin, state) do
    case Map.fetch(state.files, from) do
      {:ok, content} ->
        {"", update_in(state.files, &(&1 |> Map.delete(from) |> Map.put(to, content))), 0}

      :error ->
        {"mv: #{from}: no such key\n", state, 1}
    end
  end

  defp builtin("mv", _args, _stdin, state),
    do: {"mv: takes a source and a destination\n", state, 1}

  defp builtin("seq", args, _stdin, state) do
    case Enum.map(args, &Integer.parse/1) do
      parsed when length(parsed) in 1..3 ->
        if Enum.all?(parsed, &match?({_, ""}, &1)) do
          nums = Enum.map(parsed, &elem(&1, 0))

          {first, incr, last} =
            case nums do
              [l] -> {1, 1, l}
              [f, l] -> {f, 1, l}
              [f, i, l] -> {f, i, l}
            end

          if incr == 0 do
            {"seq: increment must not be zero\n", state, 2}
          else
            out =
              first
              |> Stream.iterate(&(&1 + incr))
              |> Stream.take_while(fn i -> if incr > 0, do: i <= last, else: i >= last end)
              |> Enum.map_join("", &"#{&1}\n")

            {out, state, 0}
          end
        else
          {"seq: not a number\n", state, 2}
        end

      _ ->
        {"seq: usage: seq [FIRST [INCR]] LAST\n", state, 2}
    end
  end

  # sed, the subset agents use: `s DELIM pattern DELIM replacement DELIM [g]`.
  # The pattern is BRE-lite — literals plus `.` `*` `^` `$` `[...]`; `&` in
  # the replacement is the whole match. Anything fancier belongs in Lua's
  # string library, which the guest already holds.
  defp builtin("sed", [script | sources], stdin, state) do
    text = if sources == [], do: stdin, else: gather(sources, state.files)

    case parse_sed(script) do
      {:ok, regex, replacement, global?} ->
        out =
          text
          |> lines()
          |> Enum.map_join("", fn line ->
            Regex.replace(regex, line, replacement, global: global?) <> "\n"
          end)

        {out, state, 0}

      :error ->
        {"sed: expected s/pattern/replacement/[g] — the subset this shell speaks\n", state, 1}
    end
  end

  defp builtin("sed", [], _stdin, state),
    do: {"sed: expected s/pattern/replacement/[g]\n", state, 1}

  defp parse_sed(<<?s, delim::utf8, rest::binary>>) do
    with [pattern, replacement, flags] <- String.split(rest, <<delim::utf8>>, parts: 3),
         {:ok, regex} <- Regex.compile(bre_lite(pattern)) do
      {:ok, regex, String.replace(replacement, "&", "\\0"), String.contains?(flags, "g")}
    else
      _ -> :error
    end
  end

  defp parse_sed(_), do: :error

  # BRE-lite → PCRE: pass `.` `*` `^` `$` and `[...]` through, escape the rest.
  defp bre_lite(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map_join("", fn
      g when g in [".", "*", "^", "$", "[", "]"] -> g
      g -> Regex.escape(g)
    end)
  end

  # ── small helpers ────────────────────────────────────────────────────────────

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
