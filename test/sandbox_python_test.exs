defmodule Blazie.SandboxPythonTest do
  @moduledoc """
  A real language runtime as the guest, and the fence around it.

  Lua is what this system is authored IN. Python is what an agent works in, and
  an agent's code is the untrusted kind — so it runs where untrusted code has to
  run, and the question is not whether Python works but whether the sandbox is
  still a sandbox with a twenty-megabyte interpreter inside it.

  Excluded by default: the module is a large binary and does not belong in this
  repository. Point `PYTHON_WASM` at one and run with `--include python`.

      curl -sL -o /tmp/python.wasm https://github.com/vmware-labs/\\
        webassembly-language-runtimes/releases/download/python%2F3.11.4%2B20230714-11be424/\\
        python-3.11.4.wasm
      PYTHON_WASM=/tmp/python.wasm mix test --include python

  ## What was measured when this was written

      print(6*7)                      -> "42"          244M fuel
      json.dumps({...}), math.pi      -> works         496M fuel
      socket.create_connection(...)   -> AttributeError
      os.listdir("/")                 -> FileNotFoundError
      while True: pass                -> out_of_fuel

  The last three are the fence, and each is absent rather than forbidden: WASI
  preview 1 has no sockets to grant, and a guest with no `preopen` has no
  directories to open. Nothing is refusing Python here — there is nothing there
  to reach.
  """
  use ExUnit.Case, async: false

  alias Blazie.Sandbox

  @moduletag :python
  @moduletag timeout: 300_000

  @fuel 10_000_000_000
  @memory 512 * 1024 * 1024

  setup do
    case System.get_env("PYTHON_WASM") do
      nil -> {:ok, skip: true}
      path -> {:ok, bytes: File.read!(path)}
    end
  end

  defp python(bytes, code, fuel \\ @fuel) do
    Sandbox.run_wasi(bytes, "", fuel: fuel, memory_bytes: @memory, args: ["python", "-c", code])
  end

  test "python runs, and what it prints comes back", %{bytes: bytes} do
    assert {:ok, said, spent} = python(bytes, "print(6*7)")
    assert String.trim(said) == "42"

    # Metered like any other guest. An interpreter is not a special case.
    assert spent.fuel > 0
  end

  test "its standard library is there", %{bytes: bytes} do
    assert {:ok, said, _} =
             python(bytes, ~s|import json, math; print(json.dumps({"pi": round(math.pi, 3)}))|)

    assert String.trim(said) == ~s|{"pi": 3.142}|
  end

  test "it cannot reach the network", %{bytes: bytes} do
    assert {:ok, said, _} =
             python(bytes, """
             import socket
             try:
                 socket.create_connection(("1.1.1.1", 80), 1)
                 print("REACHED")
             except Exception as e:
                 print("blocked:", type(e).__name__)
             """)

    # Absent rather than forbidden: WASI preview 1 has no sockets to grant.
    refute String.contains?(said, "REACHED")
    assert said =~ "blocked"
  end

  test "it cannot read the filesystem", %{bytes: bytes} do
    assert {:ok, said, _} =
             python(bytes, """
             import os
             try:
                 print(os.listdir("/"))
             except Exception as e:
                 print("blocked:", type(e).__name__)
             """)

    assert said =~ "blocked"
  end

  test "and it cannot run forever", %{bytes: bytes} do
    # The property everything else rests on. A NIF runs to completion; fuel is
    # the only thing that ends this, and an interpreter loops as happily as
    # hand-written wasm.
    assert {:error, refusal} = python(bytes, "while True: pass", 2_000_000_000)
    assert refusal.problem == :out_of_fuel

    # Host still answering afterwards.
    assert {:ok, said, _} = python(bytes, "print('still here')")
    assert said =~ "still here"
  end
end
