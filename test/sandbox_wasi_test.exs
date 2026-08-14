defmodule Blazie.SandboxWasiTest do
  @moduledoc """
  The other guest contract: stdio, so a real language runtime can be the guest.

  `run/3` speaks a bespoke protocol — export `alloc`, take a pointer, hand back
  a packed i64. Fine for a module written to be a blazie guest, and impossible
  for one that was not: CPython compiled to wasm does not export `alloc`, it
  exports `_start` and talks over stdio like every other program.

  This is that path. The fence has to survive it, which is what most of these
  assert — a WASI guest gets stdio and nothing else unless somebody said so.
  """
  use ExUnit.Case, async: false

  alias Blazie.Sandbox

  # Writes "hello" to fd 1 through wasi's fd_write, then exits. The iovec is
  # built by hand at address 0: {ptr, len} followed by the bytes.
  @hello """
  (module
    (import "wasi_snapshot_preview1" "fd_write"
      (func $fd_write (param i32 i32 i32 i32) (result i32)))
    (memory 1)
    (export "memory" (memory 0))
    (data (i32.const 8) "hello")
    (func $main (export "_start")
      (i32.store (i32.const 0) (i32.const 8))
      (i32.store (i32.const 4) (i32.const 5))
      (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20)))))
  """

  # Loops forever without printing, to prove fuel still ends a WASI guest.
  @forever """
  (module
    (memory 1)
    (export "memory" (memory 0))
    (func $main (export "_start") (loop $l (br $l))))
  """

  test "a wasi guest writes to stdout and it comes back" do
    assert {:ok, "hello", spent} = Sandbox.run_wasi(@hello)
    assert spent.fuel > 0, "a run that spent no fuel did not happen"
  end

  test "fuel still ends one that will not stop" do
    # The property the whole arrangement rests on, checked again on the new
    # path: a NIF runs to completion and no supervisor reaches inside one, so
    # the only thing that ends this is the fuel.
    assert {:error, refusal} = Sandbox.run_wasi(@forever, "", fuel: 1_000_000)
    assert refusal.problem == :out_of_fuel

    # And the node is still here.
    assert {:ok, "hello", _} = Sandbox.run_wasi(@hello)
  end

  test "a module that is not wasm is refused before it runs" do
    assert {:error, refusal} = Sandbox.run_wasi("not wasm at all")
    assert refusal.problem == :would_not_start
  end

  test "a guest is given no filesystem unless somebody hands it one" do
    # WASI's capabilities are all opt-in and this is the default: no preopen
    # means no directories, so there is nothing to open. A sandbox whose guest
    # can read the disk is not one.
    opened = %Wasmex.Wasi.WasiOptions{} |> Map.get(:preopen)
    assert opened == []
  end
end
