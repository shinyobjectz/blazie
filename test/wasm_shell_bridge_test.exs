defmodule Blazie.WasmShellBridgeTest do
  @moduledoc """
  TL0 — tiny-lasers as a dependency, proven at the one seam that matters.

  tiny-lasers is OUR wasm-on-the-BEAM substrate (workbooks-sh): guests are
  ordinary BEAM code — an interpreter lane in pure Elixir, an ASM lane that
  compiles wasm functions to real BEAM functions. This is Luerl's species,
  not wasmex's; adopting it does not reopen LT3.

  The spike runs `washy` — tiny-lasers' no-fork shell, C compiled to
  wasm32-wasip1 (fixture vendored in priv/wasm, rebuildable from its
  priv/shell/sh.c) — over BLAZIE'S workspace: both sides keep their files as
  a process-dict map (`:blazie_workspace` here, `:tl_vfs` there), so the
  bridge is a rename. A pipeline of real compiled C runs against the same
  key→bytes world the Lua guest sees, its writes flow back, and no
  filesystem exists anywhere — the microkernel picture, with a second
  species of program inside it.

  Interpreter lane only (`transpile: false`): the ASM perf tier is parked on
  OTP 29 pending an upstream fix, and correctness is the lane the fence
  cares about.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  @fixture Path.join(:code.priv_dir(:blazie), "wasm/washy_sh.wasm")

  setup do
    {:ok, mod} = Wasm.decode(File.read!(@fixture))
    %{mod: mod}
  end

  # Run one washy command line over a blazie-style workspace map. The bridge:
  # seed :tl_vfs from the map, run, harvest :tl_vfs back.
  defp washy(mod, cmd, files) do
    Process.put(:tl_vfs, files)
    Process.put(:tl_argv, ["sh", cmd])
    Process.put(:tl_stdin, "")
    Process.put(:tl_out, [])

    out =
      try do
        {_res, out} = Wasm.call_io(mod, "_start", [], transpile: false)
        out
      catch
        :throw, {:tl_exit, _code} ->
          Process.get(:tl_out) |> List.wrap() |> IO.iodata_to_binary()
      end

    {out, Process.get(:tl_vfs, %{})}
  end

  test "the dependency boots — its supervision tree is up" do
    assert is_pid(Process.whereis(TinyLasers.Supervisor))
  end

  test "compiled C runs a pipeline over blazie's workspace map", %{mod: mod} do
    files = %{"notes.txt" => "alpha total 3\nbeta 4\ngamma total 5\n"}

    {out, _files} = washy(mod, "grep total /work/notes.txt | upper", files)

    assert out =~ "ALPHA TOTAL 3"
    assert out =~ "GAMMA TOTAL 5"
    refute out =~ "beta"
  end

  test "a redirect from C lands back in the map — writes flow both ways", %{mod: mod} do
    files = %{"in.txt" => "hello\n"}

    {_out, files_after} = washy(mod, "grep hello /work/in.txt > /work/found.txt", files)

    assert files_after["found.txt"] =~ "hello"
    assert files_after["in.txt"] == "hello\n"
  end

  test "a traversal-shaped path is a funny key here too", %{mod: mod} do
    {out, files_after} = washy(mod, "echo gotcha > /work/../../etc/passwd", %{})

    # No host path was involved; the C program wrote a map entry.
    wrote = Enum.find(Map.keys(files_after), &String.contains?(&1, "passwd"))
    assert wrote == nil or files_after[wrote] =~ "gotcha"
    refute match?({:ok, "gotcha" <> _}, File.read("/etc/passwd"))
  end
end
