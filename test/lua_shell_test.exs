defmodule Blazie.LuaShellTest do
  @moduledoc """
  LT5(a) — the shell grant: terminal ergonomics with no terminal anywhere.

  `sh("grep total *.txt | wc -l")` inside a workspace guest. The "shell" is a
  pure Elixir function over the workspace map — builtins, pipes, `>` and a
  `*` glob — so an agent gets the vocabulary it already knows (ls, cat, grep,
  wc) while the fence stays exactly what it was: no process is spawned, no
  path leaves the map, a redirect writes a key. Real bash (busybox through
  the tiny-lasers transpiler) stays gated on THIS proving insufficient.
  """
  use ExUnit.Case, async: true

  alias Blazie.Lua
  alias Blazie.Lua.Shell

  @files %{
    "notes.txt" => "alpha total 3\nbeta 4\ngamma total 5\n",
    "data/more.txt" => "delta total 6\n",
    "readme.md" => "# hello\n"
  }

  describe "the shell as a pure function (host-side truth)" do
    test "ls lists keys, sorted" do
      {out, _files} = Shell.run("ls", @files)
      assert out == "data/more.txt\nnotes.txt\nreadme.md"
    end

    test "cat, grep, wc compose through pipes" do
      {out, _} = Shell.run("cat notes.txt | grep total | wc -l", @files)
      assert String.trim(out) == "2"
    end

    test "a glob reaches every matching key" do
      {out, _} = Shell.run("grep total *.txt", @files)
      assert out =~ "alpha total 3"
      refute out =~ "delta"

      {out2, _} = Shell.run("grep -c total data/*.txt", @files)
      assert String.trim(out2) == "1"
    end

    test "a redirect writes a key, additively" do
      {_, files} = Shell.run("grep total notes.txt > hits.txt", @files)
      assert files["hits.txt"] == "alpha total 3\ngamma total 5\n"
      # Nothing else moved.
      assert files["notes.txt"] == @files["notes.txt"]
    end

    test "head, sort and uniq behave" do
      files = %{"n.txt" => "b\na\nb\nc\n"}
      {out, _} = Shell.run("cat n.txt | sort | uniq", files)
      assert out == "a\nb\nc"

      {out2, _} = Shell.run("cat n.txt | head -2", files)
      assert out2 == "b\na"
    end

    test "echo speaks, rm removes a key" do
      {out, _} = Shell.run("echo hello world", @files)
      assert out == "hello world"

      {_, files} = Shell.run("rm readme.md", @files)
      refute Map.has_key?(files, "readme.md")
    end

    test "an unknown command refuses with the shelf of builtins" do
      {out, _} = Shell.run("curl http://evil", @files)
      assert out =~ "curl: not a builtin"
      assert out =~ "grep"
    end

    test "a missing file is an honest miss, not a crash" do
      {out, _} = Shell.run("cat nope.txt", @files)
      assert out =~ "nope.txt"
    end
  end

  describe "the grammar, native (for/while/if, $VAR, &&/||, block tails)" do
    test "the exit criterion: a for-loop pipes into a host program" do
      {out, _} = Shell.run("for f in a b c; do echo $f; done | wc -l", %{})
      assert out == "3"
    end

    test "variables and if/else run" do
      {out, _} = Shell.run("X=world; if true; then echo hello $X; else echo bye; fi", %{})
      assert out == "hello world"
    end

    test "&& and || short-circuit" do
      {out, _} = Shell.run("false && echo no; true && echo yes || echo never", %{})
      assert out == "yes"
    end

    test "cat pipes into upper" do
      {out, _} = Shell.run("cat in.txt | upper", %{"in.txt" => "hello\n"})
      assert out == "HELLO"
    end

    test "a block's output redirects to a key" do
      {_, files} = Shell.run("for f in a b; do echo $f; done > out.txt", %{})
      assert files["out.txt"] == "a\nb\n"
    end

    test "the caller's process state survives the run" do
      Process.put(:tl_vfs, :sentinel)
      Process.put(:blazie_workspace, %{"mine" => "untouched"})
      {_, _} = Shell.run("echo hi", %{})
      assert Process.get(:tl_vfs) == :sentinel
      assert Process.get(:blazie_workspace) == %{"mine" => "untouched"}
      Process.delete(:tl_vfs)
      Process.delete(:blazie_workspace)
    end
  end

  describe "sed and seq — the tools that came home (native)" do
    test "sed runs mid-pipe" do
      {out, _} = Shell.run("echo hello world | sed s/hello/goodbye/", %{})
      assert out == "goodbye world"
    end

    test "the exit chain: grammar, sed, wc, one line" do
      {out, _} = Shell.run("for f in alpha beta; do echo $f; done | sed s/a/A/ | wc -l", %{})
      assert out == "2"
    end

    test "seq chains into sed" do
      {out, _} = Shell.run("seq 3", %{})
      assert out == "1\n2\n3"

      {out2, _} = Shell.run("seq 1 2 9 | sed s/5/five/ | wc -l", %{})
      assert out2 == "5"
    end

    test "sed shows up on the shelf" do
      {out, _} = Shell.run("curl http://evil", %{})
      assert out =~ "sed" and out =~ "seq"
    end
  end

  describe "granted to the guest" do
    test "sh() speaks the full grammar inside the Lua guest — the TL1 exit" do
      {:ok, answer} =
        Lua.workspace(
          """
          return sh("for f in a b c; do echo $f; done | wc -l")
          """,
          %{}
        )

      assert answer.value == "3"
    end

    test "sh() runs a pipeline and its redirect lands in the workspace" do
      {:ok, answer} =
        Lua.workspace(
          """
          local hits = sh("grep total *.txt | wc -l")
          sh("grep total notes.txt > hits.txt")
          return hits
          """,
          @files
        )

      assert String.trim(answer.value) == "2"
      assert answer.files["hits.txt"] =~ "alpha total 3"
    end

    test "the shell cannot reach past the map — no process, no host path" do
      {:ok, answer} =
        Lua.workspace(
          """
          return sh("cat /etc/passwd")
          """,
          %{}
        )

      # A host path is just an absent key.
      assert answer.value =~ "/etc/passwd"
      refute answer.value =~ "root:"
    end
  end

  describe "S1 — conditionals and status" do
    test "test/[ predicates over the VFS" do
      files = %{"notes.txt" => "x\n"}
      {out, _} = Shell.run("if [ -f notes.txt ]; then echo yes; else echo no; fi", files)
      assert out == "yes"
      {out2, _} = Shell.run("if [ -f absent.txt ]; then echo yes; else echo no; fi", files)
      assert out2 == "no"
    end

    test "string and integer predicates" do
      assert {"eq", _} = Shell.run("if [ a = a ]; then echo eq; fi", %{})
      assert {"ne", _} = Shell.run("if [ a != b ]; then echo ne; fi", %{})
      assert {"lt", _} = Shell.run("if [ 3 -lt 5 ]; then echo lt; fi", %{})
      assert {"empty", _} = Shell.run("if [ -z \"\" ]; then echo empty; fi", %{})
    end

    test "$? carries the last status" do
      {out, _} = Shell.run("false; echo $?; true; echo $?", %{})
      assert out == "1\n0"
    end

    test "sh() returns out, rc, err to the guest" do
      {:ok, answer} =
        Lua.workspace(
          """
          local out, rc, err = sh("false")
          local out2, rc2 = sh("echo ok")
          return { rc1 = rc, rc2 = rc2, out2 = out2, err_empty = (err == "") }
          """,
          %{}
        )

      assert answer.value == %{"rc1" => 1, "rc2" => 0, "out2" => "ok", "err_empty" => true}
    end
  end

  describe "S2 — substitution and arithmetic" do
    test "$(...) substitutes a command's output" do
      files = %{"n.txt" => "a\nb\nc\n"}
      {out, _} = Shell.run("echo lines=$(cat n.txt | wc -l)", files)
      assert out == "lines=3"
    end

    test "$((...)) computes" do
      {out, _} = Shell.run("echo $((2 + 3 * 4))", %{})
      assert out == "14"
      {out2, _} = Shell.run("X=5; echo $((X > 0 && 1 || 0))", %{}) |> then(fn r -> r end)
      _ = out2
      {out3, _} = Shell.run("X=5; echo $(($X * 2))", %{})
      assert out3 == "10"
    end

    test "the idiom sentence: substitution inside a test" do
      files = %{"n.txt" => "1\n2\n3\n4\n"}

      {out, _} =
        Shell.run("if [ $(cat n.txt | wc -l) -gt 3 ]; then echo big; else echo small; fi", files)

      assert out == "big"
    end

    test "a substitution is a subshell: file writes persist, var changes do not" do
      {out, files} =
        Shell.run("X=outer; echo $(X=inner; echo made > sub.txt; echo $X); echo $X", %{})

      assert out == "inner\nouter"
      assert files["sub.txt"] == "made\n"
    end

    test "counting loop with arithmetic" do
      {out, _} = Shell.run("i=0; while [ $i -lt 3 ]; do echo n$i; i=$((i + 1)); done", %{})
      assert out == "n0\nn1\nn2"
    end
  end

  describe "S3 — the coreutils sweep" do
    @s3_files %{"a.txt" => "one\ntwo\nthree\n", "b.txt" => "one\ntwo\nfour\n"}

    test "tr translates and deletes" do
      assert {"HELLO", _} = Shell.run("echo hello | tr a-z A-Z", %{})
      assert {"heo", _} = Shell.run("echo hello | tr -d l", %{})
    end

    test "cut selects fields and chars" do
      assert {"b", _} = Shell.run("echo a:b:c | cut -d : -f 2", %{})
      assert {"a:c", _} = Shell.run("echo a:b:c | cut -d : -f 1,3", %{})
      assert {"ell", _} = Shell.run("echo hello | cut -c 2-4", %{})
    end

    test "nl, tac, paste" do
      {out, _} = Shell.run("printf_is_absent; echo x | nl", %{})
      assert out =~ "1\tx"
      assert {"b\na", _} = Shell.run("cat two.txt | tac", %{"two.txt" => "a\nb\n"})
      {out2, _} = Shell.run("paste l.txt r.txt", %{"l.txt" => "1\n2\n", "r.txt" => "x\ny\n"})
      assert out2 == "1\tx\n2\ty"
    end

    test "tee writes and passes through" do
      {out, files} = Shell.run("echo data | tee copy.txt | upper", %{})
      assert out == "DATA"
      assert files["copy.txt"] == "data\n"
    end

    test "diff reports difference and rc" do
      {out, _} = Shell.run("diff a.txt b.txt", @s3_files)
      assert out =~ "< three" and out =~ "> four"
      {:ok, answer} = Lua.workspace("local _, rc = sh(\"diff a.txt a.txt\") return rc", @s3_files)
      assert answer.value == 0
    end

    test "find walks keys with -name" do
      files = %{"src/a.ex" => "", "src/b.txt" => "", "top.txt" => ""}
      {out, _} = Shell.run("find -name '*.txt'", files)
      assert out == "src/b.txt\ntop.txt"
      {out2, _} = Shell.run("find src", files)
      assert out2 == "src/a.ex\nsrc/b.txt"
    end

    test "xargs appends stdin words" do
      {out, _} = Shell.run("echo a.txt | xargs wc -l", @s3_files)
      # Real wc names the file beside the count — the differential gate proved it.
      assert out == "3 a.txt"
    end

    test "grep -E and -n" do
      {out, _} = Shell.run("grep -E 't(wo|hree)' a.txt", @s3_files)
      assert out == "two\nthree"
      {out2, _} = Shell.run("grep -n two a.txt", @s3_files)
      assert out2 == "2:two"
    end

    test "sort -n -r, uniq -c, wc -w -c" do
      assert {"10\n9\n2", _} =
               Shell.run("seq_input | sort", %{})
               |> then(fn _ ->
                 Shell.run("cat n.txt | sort -n -r", %{"n.txt" => "9\n10\n2\n"})
               end)

      {out, _} = Shell.run("cat d.txt | uniq -c", %{"d.txt" => "a\na\nb\n"})
      assert out == "2 a\n1 b"
      assert {"2", _} = Shell.run("echo one two | wc -w", %{})
      assert {"4", _} = Shell.run("echo abc | wc -c", %{})
    end

    test "basename, dirname, sha256" do
      assert {"c.txt", _} = Shell.run("basename a/b/c.txt", %{})
      assert {"a/b", _} = Shell.run("dirname a/b/c.txt", %{})
      {out, _} = Shell.run("echo x | sha256", %{})
      assert out == :crypto.hash(:sha256, "x\n") |> Base.encode16(case: :lower)
    end

    test "head/tail -n spelling" do
      files = %{"n.txt" => "1\n2\n3\n4\n"}
      assert {"1\n2", _} = Shell.run("head -n 2 n.txt", files)
      assert {"3\n4", _} = Shell.run("tail -n 2 n.txt", files)
    end

    test "date and whoami are deterministic from at" do
      r = Shell.run_full("date +%s; whoami", %{}, at: 1234, by: "run-9")
      assert r.out == "1234\nrun-9\n"
      r2 = Shell.run_full("date +%s; whoami", %{}, at: 1234, by: "run-9")
      assert r2.out == r.out
    end

    test "help documents every tool" do
      {out, _} = Shell.run("help", %{})
      for tool <- Shell.builtins(), do: assert(out =~ tool)
    end
  end

  describe "S4 — cwd over the flat map" do
    @s4_files %{"proj/src/a.txt" => "alpha\n", "proj/readme.md" => "hi\n", "top.txt" => "t\n"}

    test "cd sets the prefix; relative keys resolve under it" do
      {out, _} = Shell.run("cd proj; pwd; cat readme.md", @s4_files)
      assert out == "/proj\nhi"
    end

    test ".. and / fold correctly" do
      {out, _} = Shell.run("cd proj/src; cat ../readme.md; cd /; cat top.txt", @s4_files)
      assert out == "hi\nt"
    end

    test "redirects and globs resolve under cwd" do
      {out, files} = Shell.run("cd proj; grep alpha src/*.txt > hit.txt; cat hit.txt", @s4_files)
      assert out == "alpha"
      assert files["proj/hit.txt"] == "alpha\n"
    end

    test "** crosses slashes" do
      {out, _} = Shell.run("wc -l **/*.txt", @s4_files)
      assert out == "1 proj/src/a.txt"
    end

    test "cp, stat, du" do
      {out, files} = Shell.run("cp top.txt copy.txt; stat copy.txt; du proj", @s4_files)
      assert out == "2 copy.txt\n9"
      assert files["copy.txt"] == "t\n"
    end
  end

  describe "S5 — streams and caps" do
    test "stderr is separate, 2> captures it" do
      r = Shell.run_full("cat nope.txt", %{})
      assert r.out == ""
      assert r.err =~ "nope.txt"

      {_, files} = Shell.run("cat nope.txt 2> errs.txt", %{})
      assert files["errs.txt"] =~ "nope.txt"
    end

    test "2>&1 folds err into the pipe" do
      {out, _} = Shell.run("cat nope.txt 2>&1 | upper", %{})
      assert out =~ "NOPE.TXT"
    end

    test "the output cap refuses with the repair, never a heap kill" do
      r = Shell.run_full("while true; do echo spam; done", %{}, max_output: 10_000)
      assert r.rc == 141
      assert r.err =~ "output cap"
      assert r.err =~ "repair"
    end

    test "legacy run/2 still merges the streams (the old contract)" do
      {out, _} = Shell.run("cat nope.txt", %{})
      assert out =~ "nope.txt"
    end
  end
end
