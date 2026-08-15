defmodule Blazie.Lua.Shell do
  @moduledoc """
  The agent's shell — grammar, tools, and filesystem, all native BEAM code.

  Luerl's lesson at shell scale: no foreign runtime — the semantics are
  ordinary Elixir, and the BEAM provides the speed and the fence. The
  grammar is a small recursive-descent parser: pipes, `;`, `&&`/`||`,
  `>`/`>>`/`2>`/`2>>`/`2>&1`, `$VAR`/`$?`, `$(...)` substitution,
  `$((...))` arithmetic, `for`/`while`/`if` with `test`/`[`, and a block
  piped or redirected onward. Every tool is an Elixir function over the
  workspace map (docs/microkernel-plan.md; the wasm engine this replaced is
  in docs/storage-plan.md, with the measurements that replaced it).

  The whole shell is a pure function — `run_full(line, files, opts) →
  %{out, err, rc, files}` — with no process state anywhere. There is no
  filesystem: `cd` is a PREFIX over key names, a traversal-shaped path is a
  funny key, and no tool can reach a host path because no tool holds one.
  Determinism is structural: `date` and friends read the caller's `at`,
  never a clock.

  Output is capped (`max_output:`, default 4MB): a guest that floods gets a
  refusal naming the repair, never a heap kill. An unknown command answers
  the shelf, so every tool an agent reaches for and misses stays a recorded
  data point. `help` is the man page, readable from inside.
  """

  @type files :: %{optional(String.t()) => binary()}

  @default_cap 4 * 1024 * 1024
  @max_subst_depth 32

  @usage %{
    "basename" => "basename PATH — the last segment",
    "cat" => "cat [KEY...] — file contents, or pass stdin through",
    "cd" => "cd [KEY|..|/] — set the prefix keys resolve under",
    "cp" => "cp SRC DST — copy one key",
    "cut" => "cut -d DELIM -f N[,N...] | cut -c A-B — select fields or chars",
    "date" => "date [+%s] — the run's moment (deterministic, from `at`)",
    "diff" => "diff A B — line differences (< left, > right); rc 1 when different",
    "dirname" => "dirname PATH — everything before the last segment",
    "du" => "du [PREFIX] — total bytes under a prefix",
    "echo" => "echo [WORDS...] — print the words",
    "false" => "false — fail",
    "find" => "find [PREFIX] [-name GLOB] — keys under a prefix, sorted",
    "grep" => "grep [-c -v -i -n -E] PATTERN [KEY...] — matching lines (substring; -E regex)",
    "head" => "head [-N | -n N] [KEY...] — first lines",
    "help" => "help — this list",
    "ls" => "ls — every key, sorted",
    "mkdir" => "mkdir — a no-op: directories are implicit in key names",
    "mv" => "mv SRC DST — rename one key",
    "nl" => "nl — number lines",
    "paste" => "paste KEY... — files side by side, tab-joined",
    "pwd" => "pwd — the current prefix",
    "rev" => "rev — each line reversed",
    "rm" => "rm KEY... — drop keys",
    "sed" => "sed s/PATTERN/REPLACEMENT/[g] [KEY...] — BRE-lite substitute",
    "seq" => "seq [FIRST [INCR]] LAST — a number per line",
    "sha256" => "sha256 [KEY...] — hex digest of stdin or files",
    "sort" => "sort [-n -r] [KEY...] — sorted lines",
    "stat" => "stat KEY — size in bytes",
    "tac" => "tac [KEY...] — lines, last first",
    "tail" => "tail [-N | -n N] [KEY...] — last lines",
    "tee" => "tee [-a] KEY... — write stdin to keys and pass it through",
    "test" => "test / [ EXPR ] — -f KEY, -z/-n STR, A = B, A != B, N -eq/-ne/-lt/-le/-gt/-ge M",
    "tr" => "tr [-d|-s] SET1 [SET2] — translate, delete, or squeeze characters (a-z ranges)",
    "true" => "true — succeed",
    "uniq" => "uniq [-c] — collapse repeated adjacent lines",
    "upper" => "upper — stdin uppercased",
    "lower" => "lower — stdin lowercased",
    "wc" => "wc [-l -w -c] [KEY...] — line/word/byte counts",
    "whoami" => "whoami — the run's provenance id",
    "xargs" => "xargs CMD [ARGS...] — append stdin words to a command"
  }

  @builtins Map.keys(@usage) |> Enum.sort()

  @doc "Run one line. Returns `{output, files}` — output is stdout+stderr merged, trailing newline trimmed."
  @spec run(String.t(), files()) :: {String.t(), files()}
  def run(line, files, opts \\ []) do
    r = run_full(line, files, opts)
    {String.trim_trailing(r.out <> r.err, "\n"), r.files}
  end

  @doc """
  Run one line with the streams separate: `%{out, err, rc, files}`.

  `opts`: `at:` (the deterministic moment, default 0), `by:` (the run's
  provenance id), `max_output:` (bytes, default 4MB — exceeding it ends the
  run with rc 141 and a refusal naming the repair).
  """
  @spec run_full(String.t(), files(), keyword()) ::
          %{out: String.t(), err: String.t(), rc: non_neg_integer(), files: files()}
  def run_full(line, files, opts \\ []) do
    state = %{
      files: files,
      vars: %{},
      cwd: "",
      rc: 0,
      at: Keyword.get(opts, :at, 0),
      by: Keyword.get(opts, :by, "guest"),
      cap: Keyword.get(opts, :max_output, @default_cap),
      out_bytes: 0,
      err: [],
      depth: 0
    }

    try do
      {stmts, _rest} = line |> lex() |> parse_script([])
      {out, state, rc} = eval_stmts(stmts, state, "")

      %{
        out: IO.iodata_to_binary(out),
        err: IO.iodata_to_binary(state.err),
        rc: rc,
        files: state.files
      }
    catch
      {:shell_cap, out, state} ->
        %{
          out: IO.iodata_to_binary(out),
          err:
            IO.iodata_to_binary(state.err) <>
              "output cap exceeded (#{state.cap} bytes). The repair: write big results " <>
              "to a file with > and read slices with head/tail/grep.\n",
          rc: 141,
          files: state.files
        }

      {:shell_depth, state} ->
        %{
          out: "",
          err:
            IO.iodata_to_binary(state.err) <>
              "substitution nested deeper than #{@max_subst_depth} — almost certainly a loop.\n",
          rc: 2,
          files: state.files
        }
    end
  end

  @doc "The tools this shell speaks, for the shelf and the spec."
  def builtins, do: @builtins

  # ── lexer ────────────────────────────────────────────────────────────────────
  # {:w, word, :bare | :dquoted | :quoted} · :semi · :pipe · :andand · :oror ·
  # :gt · :gtgt · :errgt · :errgtgt · :errdup. Double quotes expand but never
  # glob or word-split; single quotes suppress everything. `$(...)` is kept
  # inside its word (balanced) for the expander.

  defp lex(line), do: lex(String.to_charlist(line), [])

  defp lex([], acc), do: Enum.reverse(acc)
  defp lex([c | rest], acc) when c in [?\s, ?\t], do: lex(rest, acc)
  defp lex([c | rest], acc) when c in [?;, ?\n], do: lex(rest, [:semi | acc])
  defp lex([?&, ?& | rest], acc), do: lex(rest, [:andand | acc])
  defp lex([?|, ?| | rest], acc), do: lex(rest, [:oror | acc])
  defp lex([?| | rest], acc), do: lex(rest, [:pipe | acc])
  defp lex([?2, ?>, ?&, ?1 | rest], acc), do: lex(rest, [:errdup | acc])
  defp lex([?2, ?>, ?> | rest], acc), do: lex(rest, [:errgtgt | acc])
  defp lex([?2, ?> | rest], acc), do: lex(rest, [:errgt | acc])
  defp lex([?>, ?> | rest], acc), do: lex(rest, [:gtgt | acc])
  defp lex([?> | rest], acc), do: lex(rest, [:gt | acc])

  defp lex([q | rest], acc) when q in [?', ?"] do
    {word, rest} = Enum.split_while(rest, &(&1 != q))

    rest =
      case rest do
        [^q | r] -> r
        [] -> []
      end

    kind = if q == ?', do: :quoted, else: :dquoted
    lex(rest, [{:w, List.to_string(word), kind} | acc])
  end

  defp lex(chars, acc) do
    {word, rest} = split_word(chars, [], 0)
    lex(rest, [{:w, List.to_string(word), :bare} | acc])
  end

  # `depth` tracks $( … ) nesting so a substitution may hold spaces and pipes.
  defp split_word([], acc, _d), do: {Enum.reverse(acc), []}

  defp split_word([?$, ?( | rest], acc, d), do: split_word(rest, [?(, ?$ | acc], d + 1)
  defp split_word([?( | rest], acc, d) when d > 0, do: split_word(rest, [?( | acc], d + 1)
  defp split_word([?) | rest], acc, d) when d > 0, do: split_word(rest, [?) | acc], d - 1)

  defp split_word([c | rest], acc, d) when d > 0, do: split_word(rest, [c | acc], d)

  defp split_word([c | _] = rest, acc, 0) when c in [?\s, ?\t, ?;, ?\n, ?|, ?>],
    do: {Enum.reverse(acc), rest}

  defp split_word([?&, ?& | _] = rest, acc, 0), do: {Enum.reverse(acc), rest}
  defp split_word([c | rest], acc, 0), do: split_word(rest, [c | acc], 0)

  # ── parser ───────────────────────────────────────────────────────────────────

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

  defp parse_body([{:w, "do", :bare} | rest]) do
    {body, rest} = parse_script(skip_semis(rest), [])

    case rest do
      [{:w, "done", :bare} | r] -> {body, r}
      r -> {body, r}
    end
  end

  defp parse_body(rest), do: {[], rest}

  defp parse_chain_until(toks, stop_word) do
    {taken, rest} =
      Enum.split_while(toks, fn
        {:w, ^stop_word, :bare} -> false
        _ -> true
      end)

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
    {segments, rest} = parse_segments(toks, [])
    {{:pipeline, segments}, rest}
  end

  defp parse_segments(toks, acc) do
    {words, rest} = Enum.split_while(toks, &match?({:w, _, _}, &1))
    {redirects, rest} = parse_redirects(rest, [])
    seg = {words, redirects}

    case rest do
      [:pipe | r] ->
        parse_segments(r, [seg | acc])

      _ ->
        segments =
          [seg | acc] |> Enum.reverse() |> Enum.reject(fn {w, r} -> w == [] and r == [] end)

        {segments, rest}
    end
  end

  defp parse_redirects([:gt, {:w, key, _} | rest], acc),
    do: parse_redirects(rest, [{:out, :write, key} | acc])

  defp parse_redirects([:gtgt, {:w, key, _} | rest], acc),
    do: parse_redirects(rest, [{:out, :append, key} | acc])

  defp parse_redirects([:errgt, {:w, key, _} | rest], acc),
    do: parse_redirects(rest, [{:err, :write, key} | acc])

  defp parse_redirects([:errgtgt, {:w, key, _} | rest], acc),
    do: parse_redirects(rest, [{:err, :append, key} | acc])

  defp parse_redirects([:errdup | rest], acc), do: parse_redirects(rest, [:err_to_out | acc])
  defp parse_redirects(rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_tail([:pipe | rest]) do
    {segments, rest} = parse_segments(rest, [])
    {{:pipeline, segments}, rest}
  end

  defp parse_tail([t | _] = toks) when t in [:gt, :gtgt, :errgt, :errgtgt, :errdup] do
    {redirects, rest} = parse_redirects(toks, [])
    {{:pipeline, [{[], redirects}]}, rest}
  end

  defp parse_tail(rest), do: {nil, rest}

  defp skip_semis([:semi | rest]), do: skip_semis(rest)
  defp skip_semis(rest), do: rest

  # ── evaluator ────────────────────────────────────────────────────────────────

  defp eval_stmts(stmts, state, extern_in) do
    Enum.reduce(stmts, {[], state, 0}, fn stmt, {out, state, _rc} ->
      {o, state, rc} = eval_stmt(stmt, state, if(out == [], do: extern_in, else: ""))
      {cap([out, o], state), %{state | rc: rc}, rc}
    end)
  end

  defp eval_stmt({:assign, name, value}, state, _in) do
    {value, state} = expand_word(value, state)
    {[], put_in(state.vars[name], value), 0}
  end

  defp eval_stmt({:chain, links}, state, extern_in) do
    Enum.reduce(links, {[], state, 0}, fn {conn, pipeline}, {out, state, rc} ->
      skip? = (conn == :andand and rc != 0) or (conn == :oror and rc == 0)

      if skip? do
        {out, state, rc}
      else
        {o, state, rc} = eval_pipeline(pipeline, state, if(out == [], do: extern_in, else: ""))
        {cap([out, o], state), %{state | rc: rc}, rc}
      end
    end)
  end

  defp eval_stmt({:for, name, words, body, tail}, state, _in) do
    {captured, state, rc} =
      Enum.reduce(words, {[], state, 0}, fn {:w, w, kind}, {out, state, _rc} ->
        {values, state} =
          case kind do
            :quoted -> {[w], state}
            _ -> expand_words(w, state)
          end

        Enum.reduce(values, {out, state, 0}, fn value, {out, state, _} ->
          state = put_in(state.vars[name], value)
          {o, state, rc} = eval_stmts(body, state, "")
          {cap([out, o], state), state, rc}
        end)
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
      while_loop(cond_chain, body, %{state | rc: rc}, cap([out, o], state), rc, guard - 1)
    else
      {out, state, rc}
    end
  end

  defp run_tail(nil, captured, state, rc), do: {captured, state, rc}

  defp run_tail({:pipeline, _} = pipeline, captured, state, _rc) do
    eval_pipeline(pipeline, state, IO.iodata_to_binary(captured))
  end

  defp eval_pipeline({:pipeline, segments}, state, stdin0) do
    {out, err, state, rc} =
      Enum.reduce(segments, {stdin0, [], state, 0}, fn {words, redirects},
                                                       {stdin, errs, state, _rc} ->
        {argv, state} = expand_cmd(words, state)
        {out, err, rc, state} = run_cmd(argv, to_string(stdin), state)

        # This segment's own redirects, where it stands in the pipe.
        {out, err} = if :err_to_out in redirects, do: {out <> err, ""}, else: {out, err}

        {err, state} =
          Enum.reduce(redirects, {err, state}, fn
            {:err, :write, key}, {e, st} -> {"", put_in(st.files[resolve(st.cwd, key)], e)}
            {:err, :append, key}, {e, st} -> {"", append_file(st, resolve(st.cwd, key), e)}
            _, acc -> acc
          end)

        {out, state} =
          Enum.reduce(redirects, {out, state}, fn
            {:out, :write, key}, {o, st} -> {"", put_in(st.files[resolve(st.cwd, key)], o)}
            {:out, :append, key}, {o, st} -> {"", append_file(st, resolve(st.cwd, key), o)}
            _, acc -> acc
          end)

        {out, [errs, err], state, rc}
      end)

    out = IO.iodata_to_binary([out])
    state = %{state | err: cap_err([state.err, IO.iodata_to_binary(err)], state)}
    {cap([out], state), state, rc}
  end

  defp append_file(state, key, data) do
    update_in(state.files[key], &((&1 || "") <> data))
  end

  # The output cap: a refusal with the repair, never a heap kill.
  defp cap(iodata, state) do
    if IO.iodata_length(iodata) + IO.iodata_length(state.err) > state.cap do
      throw({:shell_cap, iodata_truncate(iodata, state.cap), state})
    else
      iodata
    end
  end

  defp cap_err(iodata, state) do
    if IO.iodata_length(iodata) > state.cap do
      throw({:shell_cap, [], %{state | err: iodata_truncate(iodata, state.cap)}})
    else
      iodata
    end
  end

  defp iodata_truncate(iodata, cap) do
    iodata |> IO.iodata_to_binary() |> binary_part(0, min(IO.iodata_length(iodata), cap))
  end

  # ── expansion: $((...)), $(...), $VAR/$?, then globs ─────────────────────────

  defp expand_cmd(cmd, state) do
    Enum.reduce(cmd, {[], state}, fn
      {:w, w, :quoted}, {argv, state} ->
        {argv ++ [w], state}

      {:w, w, :dquoted}, {argv, state} ->
        {word, state} = expand_word(w, state)
        {argv ++ [word], state}

      {:w, w, :bare}, {argv, state} ->
        {words, state} = expand_words(w, state)
        globbed = Enum.flat_map(words, &expand_glob(&1, state))
        {argv ++ globbed, state}
    end)
  end

  # Bare word: expand, then word-split on whitespace (empty results vanish).
  defp expand_words(w, state) do
    {expanded, state} = expand_word(w, state)
    {String.split(expanded, ~r/\s+/, trim: true), state}
  end

  # One word: $((...)) first, then $(...), then $VAR / $? / ${VAR}.
  defp expand_word(w, state) do
    {w, state} = expand_arith(w, state)
    {w, state} = expand_subst(w, state)
    {expand_vars(w, state), state}
  end

  defp expand_arith(w, state) do
    case split_marker(w, "$((") do
      nil ->
        {w, state}

      {before, rest} ->
        case balanced(rest, 2) do
          nil ->
            {w, state}

          {inner, after_} ->
            inner = expand_vars(inner, state)

            inner =
              Regex.replace(~r/[A-Za-z_][A-Za-z0-9_]*/, inner, fn name ->
                Map.get(state.vars, name, "0")
              end)

            value = arith(inner)
            {tail, state} = expand_arith(after_, state)
            {before <> value <> tail, state}
        end
    end
  end

  defp expand_subst(w, state) do
    case split_marker(w, "$(") do
      nil ->
        {w, state}

      {before, rest} ->
        case balanced(rest, 1) do
          nil ->
            {w, state}

          {inner, after_} ->
            if state.depth >= @max_subst_depth, do: throw({:shell_depth, state})

            # A substitution is a subshell: files changes persist, var changes
            # do not, and its stderr joins the run's.
            sub = %{state | depth: state.depth + 1}
            {stmts, _} = inner |> lex() |> parse_script([])
            {out, sub_state, _rc} = eval_stmts(stmts, sub, "")

            state = %{
              state
              | files: sub_state.files,
                err: sub_state.err,
                out_bytes: sub_state.out_bytes
            }

            value = out |> IO.iodata_to_binary() |> String.trim_trailing("\n")
            {tail, state} = expand_subst(after_, state)
            {before <> value <> tail, state}
        end
    end
  end

  defp split_marker(w, marker) do
    case String.split(w, marker, parts: 2) do
      [_only] -> nil
      [before, rest] -> {before, rest}
    end
  end

  # Take chars until the parens opened by the marker close. `open` is how
  # many `)` close the construct ($(( needs two, $( needs one).
  defp balanced(rest, open), do: balanced(String.to_charlist(rest), open, open, [])

  defp balanced([], _need, _depth, _acc), do: nil

  defp balanced([?( | t], need, depth, acc), do: balanced(t, need, depth + 1, [?( | acc])

  defp balanced([?) | t], need, depth, acc) do
    if depth == need and need > 1 do
      case t do
        [?) | t2] when need == 2 ->
          {acc |> Enum.reverse() |> List.to_string(), List.to_string(t2)}

        _ ->
          balanced(t, need, depth - 1, [?) | acc])
      end
    else
      if depth == 1 do
        {acc |> Enum.reverse() |> List.to_string(), List.to_string(t)}
      else
        balanced(t, need, depth - 1, [?) | acc])
      end
    end
  end

  defp balanced([c | t], need, depth, acc), do: balanced(t, need, depth, [c | acc])

  defp expand_vars(word, state) do
    Regex.replace(~r/\$\{(\w+)\}|\$(\w+)|\$\?/, word, fn
      whole, braced, bare ->
        cond do
          whole == "$?" -> Integer.to_string(state.rc)
          braced != "" -> Map.get(state.vars, braced, "")
          bare != "" -> Map.get(state.vars, bare, "")
          true -> whole
        end
    end)
  end

  # ── $((...)) arithmetic: + - * / % and parens over integers ─────────────────

  defp arith(text) do
    case arith_expr(String.to_charlist(text) |> Enum.reject(&(&1 in [?\s, ?\t]))) do
      {v, []} -> Integer.to_string(v)
      _ -> "0"
    end
  catch
    _, _ -> "0"
  end

  defp arith_expr(chars) do
    {left, rest} = arith_term(chars)
    arith_expr_rest(left, rest)
  end

  defp arith_expr_rest(left, [?+ | rest]) do
    {right, rest} = arith_term(rest)
    arith_expr_rest(left + right, rest)
  end

  defp arith_expr_rest(left, [?-, c | _] = chars) when c in ?0..?9 or c == ?( do
    [?- | rest] = chars
    {right, rest} = arith_term(rest)
    arith_expr_rest(left - right, rest)
  end

  defp arith_expr_rest(left, rest), do: {left, rest}

  defp arith_term(chars) do
    {left, rest} = arith_factor(chars)
    arith_term_rest(left, rest)
  end

  defp arith_term_rest(left, [?* | rest]) do
    {right, rest} = arith_factor(rest)
    arith_term_rest(left * right, rest)
  end

  defp arith_term_rest(left, [?/ | rest]) do
    {right, rest} = arith_factor(rest)
    arith_term_rest(div(left, right), rest)
  end

  defp arith_term_rest(left, [?% | rest]) do
    {right, rest} = arith_factor(rest)
    arith_term_rest(rem(left, right), rest)
  end

  defp arith_term_rest(left, rest), do: {left, rest}

  defp arith_factor([?( | rest]) do
    {v, rest} = arith_expr(rest)

    case rest do
      [?) | r] -> {v, r}
      r -> {v, r}
    end
  end

  defp arith_factor([?- | rest]) do
    {v, rest} = arith_factor(rest)
    {-v, rest}
  end

  defp arith_factor(chars) do
    {digits, rest} = Enum.split_while(chars, &(&1 in ?0..?9))
    {List.to_integer(digits), rest}
  end

  # ── globs and path resolution ────────────────────────────────────────────────

  # `*` never crosses `/`; `**` does. Patterns resolve under the cwd prefix.
  defp expand_glob(word, state) do
    if String.contains?(word, "*") do
      full = resolve(state.cwd, word)

      regex =
        full
        |> Regex.escape()
        |> String.replace("\\*\\*", "\0")
        |> String.replace("\\*", "[^/]*")
        |> String.replace("\0", ".*")
        |> then(&Regex.compile!("^#{&1}$"))

      case state.files |> Map.keys() |> Enum.filter(&Regex.match?(regex, &1)) |> Enum.sort() do
        [] -> [word]
        matched -> Enum.map(matched, &unresolve(state.cwd, &1))
      end
    else
      [word]
    end
  end

  # A key argument resolved under the cwd prefix; "/" roots, ".."/"." fold.
  defp resolve(cwd, path) do
    base = if String.starts_with?(path, "/"), do: [], else: split_prefix(cwd)

    (base ++ String.split(path, "/"))
    |> Enum.reduce([], fn
      "", acc -> acc
      ".", acc -> acc
      "..", [] -> []
      "..", acc -> tl(acc)
      seg, acc -> [seg | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
  end

  defp split_prefix(""), do: []
  defp split_prefix(cwd), do: String.split(cwd, "/")

  defp unresolve("", key), do: key

  defp unresolve(cwd, key) do
    prefix = cwd <> "/"
    if String.starts_with?(key, prefix), do: String.replace_prefix(key, prefix, ""), else: key
  end

  # ── the tools ────────────────────────────────────────────────────────────────

  defp run_cmd([], stdin, state), do: {stdin, "", 0, state}

  defp run_cmd([verb | args], stdin, state) do
    if verb in @builtins or verb == "[" do
      builtin(verb, args, stdin, state)
    else
      {"",
       "#{verb}: not a builtin. This shell is #{Enum.join(@builtins, ", ")} over the " <>
         "workspace — pipes, for/if/while, $(), $(()), test/[ and redirects work; " <>
         "processes and the machine do not exist here. `help` describes every tool.\n", 127,
       state}
    end
  end

  # Every builtin: (args, stdin, state) → {out, err, rc, state}.

  defp builtin("help", _a, _s, state) do
    out = Enum.map_join(@builtins, "", fn b -> @usage[b] <> "\n" end)
    {out, "", 0, state}
  end

  defp builtin("echo", args, _stdin, state), do: {Enum.join(args, " ") <> "\n", "", 0, state}
  defp builtin("true", _a, _s, state), do: {"", "", 0, state}
  defp builtin("false", _a, _s, state), do: {"", "", 1, state}
  defp builtin("mkdir", _a, _s, state), do: {"", "", 0, state}
  defp builtin("upper", _a, stdin, state), do: {String.upcase(stdin), "", 0, state}
  defp builtin("lower", _a, stdin, state), do: {String.downcase(stdin), "", 0, state}
  defp builtin("pwd", _a, _s, state), do: {"/" <> state.cwd <> "\n", "", 0, state}
  defp builtin("whoami", _a, _s, state), do: {to_string(state.by) <> "\n", "", 0, state}

  defp builtin("date", ["+%s"], _s, state),
    do: {Integer.to_string(state.at) <> "\n", "", 0, state}

  defp builtin("date", _a, _s, state) do
    iso = state.at |> DateTime.from_unix!() |> DateTime.to_iso8601()
    {iso <> "\n", "", 0, state}
  end

  defp builtin("cd", args, _s, state) do
    case args do
      [] ->
        {"", "", 0, %{state | cwd: ""}}

      ["/"] ->
        {"", "", 0, %{state | cwd: ""}}

      [path] ->
        {"", "", 0, %{state | cwd: resolve(state.cwd, path)}}

      _ ->
        {"", "cd: one argument\n", 1, state}
    end
  end

  defp builtin("rev", _a, stdin, state) do
    {stdin |> lines() |> Enum.map_join("", &(String.reverse(&1) <> "\n")), "", 0, state}
  end

  defp builtin("ls", [], _stdin, state) do
    keys =
      state.files
      |> Map.keys()
      |> Enum.map(&unresolve(state.cwd, &1))
      |> Enum.sort()

    {Enum.map_join(keys, "", &(&1 <> "\n")), "", 0, state}
  end

  defp builtin("ls", args, _stdin, state) do
    {out, err} =
      Enum.reduce(args, {"", ""}, fn key, {o, e} ->
        if Map.has_key?(state.files, resolve(state.cwd, key)) do
          {o <> key <> "\n", e}
        else
          {o, e <> "ls: #{key}: no such key\n"}
        end
      end)

    {out, err, if(err == "", do: 0, else: 1), state}
  end

  defp builtin("cat", [], stdin, state), do: {stdin, "", 0, state}

  defp builtin("cat", args, _stdin, state) do
    {out, err} =
      Enum.reduce(args, {"", ""}, fn key, {o, e} ->
        case Map.fetch(state.files, resolve(state.cwd, key)) do
          {:ok, content} -> {o <> content, e}
          :error -> {o, e <> "cat: #{key}: no such key\n"}
        end
      end)

    {out, err, if(err == "", do: 0, else: 1), state}
  end

  defp builtin("grep", args, stdin, state) do
    {flags, args} = Enum.split_with(args, &String.starts_with?(&1, "-"))
    count? = "-c" in flags
    invert? = "-v" in flags
    icase? = "-i" in flags
    number? = "-n" in flags
    regex? = "-E" in flags

    case args do
      [] ->
        {"", "grep: need a pattern\n", 2, state}

      [pattern | sources] ->
        {text, err} = text_or_stdin(sources, stdin, state)

        matcher =
          if regex? do
            opts = if icase?, do: [:caseless], else: []

            case Regex.compile(pattern, opts) do
              {:ok, re} -> fn line -> Regex.match?(re, line) end
              _ -> nil
            end
          else
            needle = if icase?, do: String.downcase(pattern), else: pattern

            fn line ->
              String.contains?(if(icase?, do: String.downcase(line), else: line), needle)
            end
          end

        if matcher == nil do
          {"", "grep: bad pattern\n", 2, state}
        else
          grep_one = fn text, prefix ->
            hits =
              text
              |> lines()
              |> Enum.with_index(1)
              |> Enum.filter(fn {line, _n} -> matcher.(line) != invert? end)

            out =
              cond do
                count? -> "#{prefix}#{length(hits)}\n"
                number? -> Enum.map_join(hits, "", fn {l, n} -> "#{prefix}#{n}:#{l}\n" end)
                true -> Enum.map_join(hits, "", fn {l, _} -> "#{prefix}#{l}\n" end)
              end

            {out, length(hits)}
          end

          case sources do
            # Real grep names the file per line (and per count) with >1 file.
            many when length(many) > 1 ->
              {out, total} =
                Enum.reduce(many, {"", 0}, fn key, {o, n} ->
                  content = Map.get(state.files, resolve(state.cwd, key), "")
                  {piece, hits} = grep_one.(content, key <> ":")
                  {o <> piece, n + hits}
                end)

              {out, err, if(total == 0, do: 1, else: 0), state}

            _ ->
              {out, hits} = grep_one.(text, "")
              {out, err, if(hits == 0, do: 1, else: 0), state}
          end
        end
    end
  end

  defp builtin("wc", args, stdin, state) do
    {flags, sources} = Enum.split_with(args, &String.starts_with?(&1, "-"))

    measure = fn text ->
      cond do
        "-w" in flags -> length(String.split(text, ~r/\s+/, trim: true))
        "-c" in flags -> byte_size(text)
        true -> length(lines(text))
      end
    end

    case sources do
      [] ->
        {"#{measure.(stdin)}\n", "", 0, state}

      keys ->
        # Real wc names the file beside the count (padding is the terminal's).
        {out, err} =
          Enum.reduce(keys, {"", ""}, fn key, {o, e} ->
            case Map.fetch(state.files, resolve(state.cwd, key)) do
              {:ok, content} -> {o <> "#{measure.(content)} #{key}\n", e}
              :error -> {o, e <> "wc: #{key}: no such key\n"}
            end
          end)

        {out, err, if(err == "", do: 0, else: 1), state}
    end
  end

  defp builtin("head", args, stdin, state), do: headtail(args, stdin, state, &Enum.take(&1, &2))
  defp builtin("tail", args, stdin, state), do: headtail(args, stdin, state, &Enum.take(&1, -&2))

  defp builtin("sort", args, stdin, state) do
    {flags, sources} = Enum.split_with(args, &String.starts_with?(&1, "-"))
    {text, err} = text_or_stdin(sources, stdin, state)
    ls = lines(text)

    ls =
      if "-n" in flags do
        Enum.sort_by(ls, fn l ->
          case Integer.parse(String.trim_leading(l)) do
            {n, _} -> n
            :error -> 0
          end
        end)
      else
        Enum.sort(ls)
      end

    ls = if "-r" in flags, do: Enum.reverse(ls), else: ls
    {Enum.map_join(ls, "", &(&1 <> "\n")), err, 0, state}
  end

  defp builtin("uniq", args, stdin, state) do
    {flags, sources} = Enum.split_with(args, &String.starts_with?(&1, "-"))
    {text, err} = text_or_stdin(sources, stdin, state)
    grouped = text |> lines() |> Enum.chunk_by(& &1)

    out =
      if "-c" in flags do
        Enum.map_join(grouped, "", fn [l | _] = g -> "#{length(g)} #{l}\n" end)
      else
        Enum.map_join(grouped, "", fn [l | _] -> l <> "\n" end)
      end

    {out, err, 0, state}
  end

  defp builtin("rm", args, _stdin, state) do
    keys = Enum.map(args, &resolve(state.cwd, &1))
    {"", "", 0, update_in(state.files, &Map.drop(&1, keys))}
  end

  defp builtin("mv", [from, to], _stdin, state) do
    from = resolve(state.cwd, from)
    to = resolve(state.cwd, to)

    case Map.fetch(state.files, from) do
      {:ok, content} ->
        {"", "", 0, update_in(state.files, &(&1 |> Map.delete(from) |> Map.put(to, content)))}

      :error ->
        {"", "mv: #{from}: no such key\n", 1, state}
    end
  end

  defp builtin("mv", _args, _stdin, state),
    do: {"", "mv: takes a source and a destination\n", 1, state}

  defp builtin("cp", [from, to], _stdin, state) do
    from = resolve(state.cwd, from)
    to = resolve(state.cwd, to)

    case Map.fetch(state.files, from) do
      {:ok, content} -> {"", "", 0, put_in(state.files[to], content)}
      :error -> {"", "cp: #{from}: no such key\n", 1, state}
    end
  end

  defp builtin("cp", _args, _stdin, state),
    do: {"", "cp: takes a source and a destination\n", 1, state}

  defp builtin("stat", [key], _stdin, state) do
    full = resolve(state.cwd, key)

    case Map.fetch(state.files, full) do
      {:ok, content} -> {"#{byte_size(content)} #{full}\n", "", 0, state}
      :error -> {"", "stat: #{key}: no such key\n", 1, state}
    end
  end

  defp builtin("stat", _a, _s, state), do: {"", "stat: takes one key\n", 1, state}

  defp builtin("du", args, _stdin, state) do
    prefix =
      case args do
        [p] -> resolve(state.cwd, p)
        _ -> state.cwd
      end

    total =
      state.files
      |> Enum.filter(fn {k, _} -> prefix == "" or String.starts_with?(k, prefix) end)
      |> Enum.map(fn {_, v} -> byte_size(v) end)
      |> Enum.sum()

    {"#{total}\n", "", 0, state}
  end

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
            {"", "seq: increment must not be zero\n", 2, state}
          else
            out =
              first
              |> Stream.iterate(&(&1 + incr))
              |> Stream.take_while(fn i -> if incr > 0, do: i <= last, else: i >= last end)
              |> Enum.map_join("", &"#{&1}\n")

            {out, "", 0, state}
          end
        else
          {"", "seq: not a number\n", 2, state}
        end

      _ ->
        {"", "seq: usage: seq [FIRST [INCR]] LAST\n", 2, state}
    end
  end

  defp builtin("sed", [script | sources], stdin, state) do
    {text, ferr} = text_or_stdin(sources, stdin, state)

    case parse_sed(script) do
      {:ok, regex, replacement, global?} ->
        out =
          text
          |> lines()
          |> Enum.map_join("", fn line ->
            Regex.replace(regex, line, replacement, global: global?) <> "\n"
          end)

        {out, ferr, 0, state}

      :error ->
        {"", "sed: expected s/pattern/replacement/[g] — the subset this shell speaks\n", 1, state}
    end
  end

  defp builtin("sed", [], _stdin, state),
    do: {"", "sed: expected s/pattern/replacement/[g]\n", 1, state}

  defp builtin("tr", args, stdin, state) do
    case args do
      ["-s", set] ->
        chars = tr_set(set) |> MapSet.new()

        out =
          stdin
          |> String.graphemes()
          |> Enum.chunk_by(fn g -> if MapSet.member?(chars, g), do: g, else: :other end)
          |> Enum.map_join("", fn [g | _] = run ->
            if MapSet.member?(chars, g), do: g, else: Enum.join(run)
          end)

        {out, "", 0, state}

      ["-d", set] ->
        chars = tr_set(set) |> MapSet.new()

        out =
          stdin |> String.graphemes() |> Enum.reject(&MapSet.member?(chars, &1)) |> Enum.join()

        {out, "", 0, state}

      [set1, set2] ->
        from = tr_set(set1)
        to = tr_set(set2)
        last = List.last(to)

        mapping =
          from
          |> Enum.with_index()
          |> Map.new(fn {c, i} -> {c, Enum.at(to, i, last)} end)

        out = stdin |> String.graphemes() |> Enum.map_join("", &Map.get(mapping, &1, &1))
        {out, "", 0, state}

      _ ->
        {"", "tr: usage: tr [-d] SET1 [SET2]\n", 1, state}
    end
  end

  defp builtin("cut", args, stdin, state) do
    {args, stdin} =
      case args do
        ["-d", d, "-f", f | sources] when sources != [] ->
          {text, _e} = text_or_stdin(sources, stdin, state)
          {["-d", d, "-f", f], text}

        ["-c", r | sources] when sources != [] ->
          {text, _e} = text_or_stdin(sources, stdin, state)
          {["-c", r], text}

        other ->
          {other, stdin}
      end

    case args do
      ["-d", delim, "-f", fields] ->
        wanted =
          fields |> String.split(",") |> Enum.map(&String.to_integer/1)

        out =
          stdin
          |> lines()
          |> Enum.map_join("", fn line ->
            parts = String.split(line, delim)
            Enum.map_join(wanted, delim, &Enum.at(parts, &1 - 1, "")) <> "\n"
          end)

        {out, "", 0, state}

      ["-c", range] ->
        [a, b] =
          case String.split(range, "-") do
            [a, b] -> [String.to_integer(a), String.to_integer(b)]
            [a] -> [String.to_integer(a), String.to_integer(a)]
          end

        out =
          stdin
          |> lines()
          |> Enum.map_join("", fn line -> String.slice(line, (a - 1)..(b - 1)) <> "\n" end)

        {out, "", 0, state}

      _ ->
        {"", "cut: usage: cut -d DELIM -f N[,N...] | cut -c A-B\n", 1, state}
    end
  end

  defp builtin("nl", args, stdin, state) do
    {text, err} = text_or_stdin(args, stdin, state)
    _ = err

    out =
      text
      |> lines()
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {l, n} ->
        "#{String.pad_leading(Integer.to_string(n), 6)}\t#{l}\n"
      end)

    {out, "", 0, state}
  end

  defp builtin("tac", args, stdin, state) do
    {text, err} = text_or_stdin(args, stdin, state)
    {text |> lines() |> Enum.reverse() |> Enum.map_join("", &(&1 <> "\n")), err, 0, state}
  end

  defp builtin("paste", args, _stdin, state) do
    columns =
      Enum.map(args, fn key ->
        case Map.fetch(state.files, resolve(state.cwd, key)) do
          {:ok, content} -> lines(content)
          :error -> []
        end
      end)

    height = columns |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    out =
      Enum.map_join(0..max(height - 1, 0)//1, "", fn i ->
        Enum.map_join(columns, "\t", &Enum.at(&1, i, "")) <> "\n"
      end)

    {out, "", 0, state}
  end

  defp builtin("tee", args, stdin, state) do
    {append?, keys} = {"-a" in args, Enum.reject(args, &(&1 == "-a"))}

    state =
      Enum.reduce(keys, state, fn key, st ->
        full = resolve(st.cwd, key)
        if append?, do: append_file(st, full, stdin), else: put_in(st.files[full], stdin)
      end)

    {stdin, "", 0, state}
  end

  defp builtin("diff", [a, b], _stdin, state) do
    with {:ok, ca} <- Map.fetch(state.files, resolve(state.cwd, a)),
         {:ok, cb} <- Map.fetch(state.files, resolve(state.cwd, b)) do
      la = lines(ca)
      lb = lines(cb)

      if la == lb do
        {"", "", 0, state}
      else
        common = MapSet.new(lcs(la, lb))

        left =
          la
          |> Enum.reject(&MapSet.member?(common, &1))
          |> Enum.map_join("", &("< " <> &1 <> "\n"))

        right =
          lb
          |> Enum.reject(&MapSet.member?(common, &1))
          |> Enum.map_join("", &("> " <> &1 <> "\n"))

        sep = if left != "" and right != "", do: "---\n", else: ""
        {left <> sep <> right, "", 1, state}
      end
    else
      :error -> {"", "diff: both keys must exist\n", 2, state}
    end
  end

  defp builtin("diff", _a, _s, state), do: {"", "diff: takes two keys\n", 2, state}

  defp builtin("find", args, _stdin, state) do
    {prefix, glob} =
      case args do
        [] -> {state.cwd, nil}
        ["-name", g] -> {state.cwd, g}
        [p] -> {resolve(state.cwd, p), nil}
        [p, "-name", g] -> {resolve(state.cwd, p), g}
        _ -> {state.cwd, nil}
      end

    regex =
      glob &&
        glob
        |> Regex.escape()
        |> String.replace("\\*", "[^/]*")
        |> then(&Regex.compile!("^#{&1}$"))

    keys =
      state.files
      |> Map.keys()
      |> Enum.filter(fn k -> prefix == "" or String.starts_with?(k, prefix) end)
      |> Enum.filter(fn k -> regex == nil or Regex.match?(regex, Path.basename(k)) end)
      |> Enum.sort()

    {Enum.map_join(keys, "", &(&1 <> "\n")), "", 0, state}
  end

  defp builtin("xargs", args, stdin, state) do
    words = String.split(stdin, ~r/\s+/, trim: true)

    case args do
      [] -> {"", "xargs: needs a command\n", 1, state}
      argv -> run_cmd(argv ++ words, "", state)
    end
  end

  defp builtin("basename", [path | _], _s, state), do: {Path.basename(path) <> "\n", "", 0, state}
  defp builtin("basename", [], _s, state), do: {"", "basename: needs a path\n", 1, state}

  defp builtin("dirname", [path | _], _s, state) do
    d = Path.dirname(path)
    {d <> "\n", "", 0, state}
  end

  defp builtin("dirname", [], _s, state), do: {"", "dirname: needs a path\n", 1, state}

  defp builtin("sha256", args, stdin, state) do
    {text, err} = text_or_stdin(args, stdin, state)
    hex = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    {hex <> "\n", err, 0, state}
  end

  defp builtin(t, args, stdin, state) when t in ["test", "["] do
    args = if t == "[", do: drop_bracket(args), else: args

    case args do
      nil ->
        {"", "[: missing ]\n", 2, state}

      _ ->
        {out_rc, state} = {test_eval(args, stdin, state), state}

        case out_rc do
          :bad -> {"", "test: bad expression — see `help`\n", 2, state}
          rc -> {"", "", rc, state}
        end
    end
  end

  defp drop_bracket(args) do
    case Enum.reverse(args) do
      ["]" | rest] -> Enum.reverse(rest)
      _ -> nil
    end
  end

  defp test_eval(args, _stdin, state) do
    case args do
      [] ->
        1

      ["-f", key] ->
        if Map.has_key?(state.files, resolve(state.cwd, key)), do: 0, else: 1

      ["-z", s] ->
        if s == "", do: 0, else: 1

      ["-n", s] ->
        if s != "", do: 0, else: 1

      [a, "=", b] ->
        if a == b, do: 0, else: 1

      [a, "!=", b] ->
        if a != b, do: 0, else: 1

      [a, op, b] when op in ["-eq", "-ne", "-lt", "-le", "-gt", "-ge"] ->
        with {x, ""} <- Integer.parse(a), {y, ""} <- Integer.parse(b) do
          ok? =
            case op do
              "-eq" -> x == y
              "-ne" -> x != y
              "-lt" -> x < y
              "-le" -> x <= y
              "-gt" -> x > y
              "-ge" -> x >= y
            end

          if ok?, do: 0, else: 1
        else
          _ -> :bad
        end

      [s] ->
        if s == "", do: 1, else: 0

      _ ->
        :bad
    end
  end

  # ── shared helpers ───────────────────────────────────────────────────────────

  defp headtail(args, stdin, state, taker) do
    {n, sources} =
      case args do
        ["-n", n | rest] -> {String.to_integer(n), rest}
        ["-" <> n | rest] -> {String.to_integer(n), rest}
        rest -> {10, rest}
      end

    {text, err} = text_or_stdin(sources, stdin, state)
    {text |> lines() |> taker.(n) |> Enum.map_join("", &(&1 <> "\n")), err, 0, state}
  end

  defp text_or_stdin([], stdin, _state), do: {stdin, ""}

  defp text_or_stdin(keys, _stdin, state) do
    Enum.reduce(keys, {"", ""}, fn key, {t, e} ->
      case Map.fetch(state.files, resolve(state.cwd, key)) do
        {:ok, content} -> {t <> content, e}
        :error -> {t, e <> "#{key}: no such key\n"}
      end
    end)
  end

  defp parse_sed(<<?s, delim::utf8, rest::binary>>) do
    with [pattern, replacement, flags] <- String.split(rest, <<delim::utf8>>, parts: 3),
         {:ok, regex} <- Regex.compile(bre_lite(pattern)) do
      {:ok, regex, String.replace(replacement, "&", "\\0"), String.contains?(flags, "g")}
    else
      _ -> :error
    end
  end

  defp parse_sed(_), do: :error

  defp bre_lite(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map_join("", fn
      g when g in [".", "*", "^", "$", "[", "]"] -> g
      g -> Regex.escape(g)
    end)
  end

  defp tr_set(set) do
    set
    |> String.to_charlist()
    |> tr_expand([])
    |> Enum.map(&<<&1::utf8>>)
  end

  defp tr_expand([a, ?-, b | rest], acc) when b >= a,
    do: tr_expand(rest, acc ++ Enum.to_list(a..b))

  defp tr_expand([c | rest], acc), do: tr_expand(rest, acc ++ [c])
  defp tr_expand([], acc), do: acc

  # Longest common subsequence of two line lists (for diff).
  defp lcs(a, b) do
    la = List.to_tuple(a)
    lb = List.to_tuple(b)
    n = tuple_size(la)
    m = tuple_size(lb)

    table =
      Enum.reduce((n - 1)..0//-1, %{}, fn i, table ->
        Enum.reduce((m - 1)..0//-1, table, fn j, table ->
          v =
            if elem(la, i) == elem(lb, j) do
              1 + Map.get(table, {i + 1, j + 1}, 0)
            else
              max(Map.get(table, {i + 1, j}, 0), Map.get(table, {i, j + 1}, 0))
            end

          Map.put(table, {i, j}, v)
        end)
      end)

    walk_lcs(la, lb, 0, 0, n, m, table, [])
  end

  defp walk_lcs(_la, _lb, i, j, n, m, _t, acc) when i >= n or j >= m, do: Enum.reverse(acc)

  defp walk_lcs(la, lb, i, j, n, m, t, acc) do
    cond do
      elem(la, i) == elem(lb, j) ->
        walk_lcs(la, lb, i + 1, j + 1, n, m, t, [elem(la, i) | acc])

      Map.get(t, {i + 1, j}, 0) >= Map.get(t, {i, j + 1}, 0) ->
        walk_lcs(la, lb, i + 1, j, n, m, t, acc)

      true ->
        walk_lcs(la, lb, i, j + 1, n, m, t, acc)
    end
  end

  defp lines(text), do: text |> String.split("\n") |> Enum.reject(&(&1 == ""))
end
