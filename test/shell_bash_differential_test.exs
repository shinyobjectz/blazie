defmodule Blazie.ShellBashDifferentialTest do
  @moduledoc """
  S6 — the conformance gate: the documented subset, differentially against
  real bash.

  Every corpus entry runs twice: under `/bin/bash` with the files
  materialized into a tmpdir, and under `Blazie.Lua.Shell` with the files as
  the map. Stdout must be byte-identical (modulo one trailing newline — the
  shell trims it, a terminal's business). A divergence is either a bug fixed
  or a line added to docs/SHELLSPEC.md — never silently absorbed.

  The corpus covers the grammar and every tool the spec marks
  bash-conformant; the spec's "this shell's own" list is deliberately not
  here. Skipped honestly where bash is absent.
  """
  use ExUnit.Case, async: false

  alias Blazie.Lua.Shell

  @bash System.find_executable("bash")

  @files %{
    "notes.txt" => "alpha total 3\nbeta 4\ngamma total 5\n",
    "nums.txt" => "9\n10\n2\n7\n",
    "dup.txt" => "a\na\nb\na\n",
    "data/more.txt" => "delta total 6\nzeta 8\n",
    "csv.txt" => "x:1:red\ny:2:blue\nz:3:red\n"
  }

  # {label, script} — the documented subset only.
  @corpus [
    {"echo + args", "echo hello world"},
    {"pipes compose", "cat notes.txt | grep total | wc -l | tr -d ' '"},
    {"sequencing", "echo one; echo two"},
    {"short-circuit &&", "false && echo no; echo after"},
    {"short-circuit ||", "false || echo rescued"},
    {"chain mix", "false && echo no; true && echo yes || echo never"},
    {"vars", "X=world; echo hello $X"},
    {"braced vars", "X=ab; echo ${X}c"},
    {"exit status", "false; echo $?; true; echo $?"},
    {"redirect out", "grep total notes.txt > hits.txt; cat hits.txt"},
    {"redirect append", "echo a > f.txt; echo b >> f.txt; cat f.txt"},
    {"stderr split", "cat notes.txt 2> /dev/null | wc -l | tr -d ' '"},
    {"for loop", "for x in a b c; do echo $x; done"},
    {"for pipes onward", "for x in a b c; do echo $x; done | wc -l | tr -d ' '"},
    {"for redirects onward", "for f in a b; do echo $f; done > out.txt; cat out.txt"},
    {"if test file", "if [ -f notes.txt ]; then echo yes; else echo no; fi"},
    {"if test absent", "if [ -f nope.txt ]; then echo yes; else echo no; fi"},
    {"test strings", "if [ a = a ]; then echo eq; fi; if [ a != b ]; then echo ne; fi"},
    {"test integers", "if [ 3 -lt 5 ]; then echo lt; fi; if [ 5 -ge 5 ]; then echo ge; fi"},
    {"test -z -n", "if [ -z \"\" ]; then echo z; fi; if [ -n x ]; then echo n; fi"},
    {"substitution", "echo lines=$(grep -c total notes.txt)"},
    {"substitution in test", "if [ $(grep -c total notes.txt) -gt 1 ]; then echo big; fi"},
    {"subshell vars stay in", "X=outer; echo $(X=inner; echo $X); echo $X"},
    {"arithmetic", "echo $((2 + 3 * 4)); echo $(((10 - 4) / 3)); echo $((7 % 3))"},
    {"arith with vars", "X=5; echo $(($X * 2)); echo $((X + 1))"},
    {"counting while", "i=0; while [ $i -lt 3 ]; do echo n$i; i=$((i + 1)); done"},
    {"grep flags", "grep -c total notes.txt; grep -v total notes.txt; grep -i ALPHA notes.txt"},
    {"grep -n", "grep -n total notes.txt"},
    {"grep -E", "grep -E 'tot(al|em)' notes.txt"},
    {"wc family", "wc -l notes.txt | tr -d ' '; echo one two three | wc -w | tr -d ' '"},
    {"head tail", "head -2 nums.txt; tail -1 nums.txt; head -n 3 nums.txt"},
    {"sort family", "sort nums.txt; sort -n nums.txt; sort -n -r nums.txt"},
    {"uniq", "sort dup.txt | uniq"},
    {"tr", "echo hello | tr a-z A-Z; echo hello | tr -d l"},
    {"cut fields", "cut -d : -f 2 csv.txt; cut -d : -f 1,3 csv.txt"},
    {"cut chars", "echo abcdef | cut -c 2-4"},
    {"rev", "echo abc | rev"},
    {"paste", "paste nums.txt dup.txt"},
    {"nl", "echo x > two.txt; echo y >> two.txt; nl two.txt | tr -s ' '"},
    {"seq", "seq 3; seq 2 5; seq 1 2 9; seq 10 -3 1"},
    {"seq into loop", "for i in $(seq 3); do echo item$i; done"},
    {"sed substitute", "echo hello world | sed s/hello/goodbye/"},
    {"sed global", "echo aaa | sed s/a/b/g"},
    {"sed on file", "sed s/total/T/ notes.txt"},
    {"tee", "echo data | tee copy.txt | cat; cat copy.txt"},
    {"xargs", "echo notes.txt | xargs grep -c total"},
    {"basename dirname", "basename a/b/c.txt; dirname a/b/c.txt"},
    {"quotes", "echo 'single $X kept'; X=v; echo \"double $X expanded\""},
    {"glob", "grep -c total *.txt"},
    {"cd relative", "cd data; grep -c total more.txt"},
    {"cd dotdot", "cd data; cat ../notes.txt | wc -l | tr -d ' '"},
    {"cp mv rm", "cp notes.txt c.txt; mv c.txt d.txt; rm d.txt; ls d.txt 2> /dev/null; echo rc=$?"}
  ]

  setup_all do
    if @bash == nil, do: raise("bash not found — this gate needs /bin/bash")
    :ok
  end

  defp bash_run(script) do
    dir = Path.join(System.tmp_dir!(), "shellspec_#{System.unique_integer([:positive])}")

    for {key, content} <- @files do
      path = Path.join(dir, key)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    {out, _rc} = System.cmd(@bash, ["-c", script], cd: dir, stderr_to_stdout: false)
    File.rm_rf!(dir)
    String.trim_trailing(out, "\n")
  end

  defp ours(script) do
    r = Shell.run_full(script, @files)
    String.trim_trailing(r.out, "\n")
  end

  for {label, script} <- @corpus do
    @script script
    test "bash ≡ shell: #{label}" do
      expected = bash_run(@script)
      got = ours(@script)

      assert got == expected,
             "divergence on #{inspect(@script)}\n  bash:  #{inspect(expected)}\n  ours:  #{inspect(got)}"
    end
  end
end
