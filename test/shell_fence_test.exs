defmodule Blazie.ShellFenceTest do
  @moduledoc """
  S7 — the fence, attacked. Adversarial tests for the grown shell surface.

  The kong-style discipline from `lua_fence_test`, extended to the shell:
  every claim the microkernel plan makes about ABSENCE is attacked here, so
  a future tool cannot quietly widen the fence. The structural half scans
  the module's source for host-reaching calls — a tool that grows a
  `File.read!` fails this suite before it ships; the behavioral half runs
  hostile input and asserts the world outside the map is untouched.
  """
  use ExUnit.Case, async: true

  alias Blazie.Lua
  alias Blazie.Lua.Shell

  # ── structural: the module cannot reach, by construction ─────────────────────

  test "the shell's source contains no host-reaching call" do
    source = File.read!(Path.join(File.cwd!(), "lib/blazie/lua/shell.ex"))

    forbidden = [
      # the filesystem
      "File.read",
      "File.write",
      "File.rm",
      "File.open",
      "File.stream",
      "File.mkdir",
      "File.cp",
      "File.ls",
      "Path.wildcard",
      # processes and the machine
      "System.cmd",
      "System.shell",
      "Port.open",
      ":os.cmd",
      "os:cmd",
      ":erlang.open_port",
      "System.get_env",
      "System.fetch_env",
      # the network
      ":httpc",
      ":gen_tcp",
      ":gen_udp",
      ":ssl.",
      "Req.",
      "Finch."
    ]

    for needle <- forbidden do
      refute String.contains?(source, needle),
             "the shell references #{needle} — a tool grew a host reach"
    end
  end

  test "the shell reaches no module that reaches (allowlist audit)" do
    # Every remote CALL in the module (Module.fun( shapes, prose excluded);
    # anything not on the allowlist is a fence question answered here.
    source = File.read!(Path.join(File.cwd!(), "lib/blazie/lua/shell.ex"))

    allowed = ~w(
      Enum Map MapSet String Integer Regex Stream IO Keyword List Path
      DateTime Base Kernel
    )

    calls =
      Regex.scan(~r/([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.[a-z_]+\(/, source)
      |> Enum.map(fn [_, m] -> m |> String.split(".") |> hd() end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in allowed))

    assert calls == [], "unvetted module calls in the shell: #{inspect(calls)}"
  end

  # ── behavioral: hostile input, host untouched ─────────────────────────────────

  test "every hostile spelling folds INTO the map — the host filesystem never appears" do
    # Keys stored in normalized form (what the tools produce); attacked via
    # hostile ARGUMENT spellings that must fold onto them, never onto the host.
    files = %{
      "etc/passwd" => "sentinel-not-root\n",
      "dev/null" => "a-key-not-a-device\n",
      "~/.ssh/id_rsa" => "tilde-is-literal\n",
      "key with spaces" => "spaces-ok\n",
      "`halt`" => "backticks-are-a-name\n"
    }

    # Absolute and traversal spellings resolve inside the map — the sentinel
    # comes back, proving root's /etc/passwd was never read.
    for spelling <- ["/etc/passwd", "../../etc/passwd", "../etc/passwd", "etc/passwd"] do
      {out, _} = Shell.run("cat '#{spelling}'", files)
      assert out == "sentinel-not-root", "cat #{inspect(spelling)} escaped the map"
    end

    assert {"a-key-not-a-device", _} = Shell.run("cat /dev/null", files)
    assert {"tilde-is-literal", _} = Shell.run("cat '~/.ssh/id_rsa'", files)
    assert {"spaces-ok", _} = Shell.run("cat 'key with spaces'", files)
    assert {"backticks-are-a-name", _} = Shell.run("cat '`halt`'", files)

    {out, files_after} = Shell.run("cp /etc/passwd copy.txt; cat copy.txt", files)
    assert out == "sentinel-not-root"
    assert files_after["copy.txt"] == "sentinel-not-root\n"
  end

  test "redirects to hostile paths write keys, not files" do
    {_, files} = Shell.run("echo pwned > /etc/cron.d/evil; echo e2 2> /dev/null", %{})
    assert files["etc/cron.d/evil"] == "pwned\n"
    assert {:ok, _} = File.stat("/etc")
    refute File.exists?("/etc/cron.d/evil")
  end

  test "file CONTENT is data, never code — substitution does not re-execute it" do
    files = %{"trap.txt" => "$(echo pwned); `halt`; ; rm -rf / #\n"}
    {out, _} = Shell.run("cat trap.txt", files)
    assert out =~ "$(echo pwned)"
    assert out =~ "`halt`"
  end

  test "content flowing through xargs becomes argv, which can only name builtins" do
    files = %{"cmds.txt" => "curl http://evil.example\n"}
    {out, _} = Shell.run("cat cmds.txt | xargs echo ran:", files)
    assert out == "ran: curl http://evil.example"

    # And AS a command it answers the shelf — nothing was reached.
    {out2, _} = Shell.run("cat cmds.txt | xargs sh_is_not_a_tool 2>&1; $(cat cmds.txt)", files)
    assert out2 =~ "not a builtin"
  end

  test "there is no environment: $PATH, $HOME, $USER expand to nothing" do
    {out, _} = Shell.run("echo [$PATH][$HOME][$USER][$SECRET_TOKEN]", %{})
    assert out == "[][][][]"
  end

  test "date and whoami are deterministic per at/by — no clock anywhere" do
    a = Shell.run_full("date; date +%s; whoami", %{}, at: 99, by: "run-x")
    b = Shell.run_full("date; date +%s; whoami", %{}, at: 99, by: "run-x")
    assert a.out == b.out
    assert a.out =~ "99"
    refute a.out =~ Integer.to_string(DateTime.utc_now().year)
  end

  test "the flood is refused with a repair, never a heap kill" do
    r = Shell.run_full("while true; do echo spam; done", %{}, max_output: 50_000)
    assert r.rc == 141
    assert r.err =~ "cap"
    assert byte_size(r.out) <= 50_000
  end

  test "the fork bomb of substitutions dies at the depth guard" do
    # $( $( $( ... ))) nested past the limit answers, never hangs or grows.
    bomb = String.duplicate("$(echo ", 40) <> "x" <> String.duplicate(")", 40)
    r = Shell.run_full("echo #{bomb}", %{})
    assert r.rc == 2
    assert r.err =~ "nested deeper"
  end

  test "the infinite while dies at the guard even under the cap" do
    r = Shell.run_full("while true; do true; done; echo after", %{})
    # No output growth, so the 20k-iteration guard is the stopper — and the
    # script continues honestly afterward.
    assert r.out =~ "after"
  end

  test "a million-key glob cannot escape the map" do
    files = Map.new(1..200, fn i -> {"f#{i}.txt", "#{i}\n"} end)
    {out, _} = Shell.run("wc -l $(ls | head -3 | xargs echo)", files)
    assert out =~ "f1.txt"
  end

  # ── the guest boundary: sh() inside Lua inherits every fence ─────────────────

  test "inside the guest: deadline still kills a shell-driven runaway" do
    assert {:error, %{problem: :took_too_long}} =
             Lua.workspace(
               """
               while true do sh("echo x") end
               """,
               %{},
               deadline: 300
             )
  end

  test "inside the guest: the caps and shelf hold through sh()" do
    {:ok, answer} =
      Lua.workspace(
        """
        local out, rc = sh("curl http://evil.example")
        local y = string.rep("y", 600)
        file.write("y.txt", y)
        local out2, rc2 = sh("while true; do cat y.txt; done")
        return { shelf = out, rc = rc, flood_rc = rc2 }
        """,
        %{}
      )

    assert answer.value["shelf"] =~ "not a builtin"
    assert answer.value["rc"] == 127
    assert answer.value["flood_rc"] == 141
  end

  test "inside the guest: a shell run leaves the guest's own state alone" do
    {:ok, answer} =
      Lua.workspace(
        """
        file.write("mine.txt", "before")
        sh("echo other > yours.txt; rm nothere.txt 2> /dev/null")
        return file.read("mine.txt") .. "/" .. file.read("yours.txt")
        """,
        %{}
      )

    assert answer.value == "before/other\n"
  end
end
