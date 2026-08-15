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

  describe "granted to the guest" do
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
end
