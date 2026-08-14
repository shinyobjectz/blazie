defmodule Blazie.SandboxResourcesTest do
  @moduledoc """
  The sandbox fences resources, not just reach.

  The reach half was always structural — no imports, so a module that names
  one fails to instantiate. C9 was the other half: a guest runs on a dirty
  NIF scheduler thread, a NIF runs to completion, and the BEAM has one such
  thread per core — so an unfenced loop was not slow, it was a permanent
  hole in the node that no supervisor could see. Fuel closed that earlier;
  what this file pins is the rest of the claim set: the memory bound holds
  in both directions, evaluations leave no processes behind, and the same
  module costs one compilation however many times it runs.
  """
  # Serial: the leak test counts the node's processes, and concurrent
  # modules starting servers of their own would count as leaks.
  use ExUnit.Case, async: false

  alias Blazie.Sandbox

  # Tries to grow memory by 100 pages (6.4MB) and answers nothing. Under a
  # small memory bound the grow is refused by wasmtime; under a generous one
  # it succeeds. Either way it returns cleanly — what differs is the memory
  # the store ends up holding, which `run/3` reports.
  @grower """
  (module
    (memory 1)
    (export "memory" (memory 0))
    (func $alloc (param $size i32) (result i32) (i32.const 1024))
    (export "alloc" (func $alloc))
    (func $run (param $ptr i32) (param $len i32) (result i64)
      (drop (memory.grow (i32.const 100)))
      (i64.const 0))
    (export "run" (func $run)))
  """

  @echo """
  (module
    (memory 1)
    (export "memory" (memory 0))
    (global $next (mut i32) (i32.const 1024))
    (func $alloc (param $size i32) (result i32)
      (local $at i32)
      (local.set $at (global.get $next))
      (global.set $next (i32.add (local.get $at) (local.get $size)))
      (local.get $at))
    (export "alloc" (func $alloc))
    (func $run (param $ptr i32) (param $len i32) (result i64)
      (i64.or (i64.shl (i64.extend_i32_u (local.get $ptr)) (i64.const 32))
              (i64.extend_i32_u (local.get $len))))
    (export "run" (func $run)))
  """

  describe "the memory bound holds, in both directions" do
    test "a grow past the bound is refused and the store stays small" do
      two_mb = 2 * 1024 * 1024

      assert {:ok, _answer, spent} = Sandbox.run(@grower, %{}, memory_bytes: two_mb)

      assert spent.memory_bytes <= two_mb,
             "the guest grew to #{spent.memory_bytes} bytes past a #{two_mb}-byte bound"
    end

    test "the same grow inside a generous bound succeeds" do
      # The other direction, or the test above passes when growing is simply
      # broken. 100 pages is 6.4MB; give it 16.
      assert {:ok, _answer, spent} = Sandbox.run(@grower, %{}, memory_bytes: 16 * 1024 * 1024)
      assert spent.memory_bytes > 6 * 1024 * 1024
    end
  end

  describe "an evaluation leaves nothing behind" do
    test "k runs from callers that die leave the process count where it was" do
      # Warm: first contact compiles and loads whatever loads lazily.
      {:ok, _, _} = Sandbox.run(@echo, %{"warm" => true})

      settle = fn ->
        Enum.reduce_while(1..200, length(Process.list()), fn _, _ ->
          Process.sleep(10)
          now = length(Process.list())
          if now == length(Process.list()), do: {:halt, now}, else: {:cont, now}
        end)
      end

      before = settle.()

      for i <- 1..10 do
        # Each run inside a task that finishes and dies — the caller shape
        # the runner uses. The holder used to outlive nothing while the
        # Wasmex server outlived everything.
        Task.await(Task.async(fn -> Sandbox.run(@echo, %{"i" => i}) end))
      end

      after_runs = settle.()

      assert after_runs <= before,
             "ten evaluations grew the node from #{before} to #{after_runs} processes"
    end
  end

  describe "a module is compiled once, however many times it runs" do
    test "the second run finds the first run's work" do
      # A module distinct from every other test's, so the cache entry is
      # provably this test's doing.
      marked = String.replace(@echo, "1024", "2048")
      key = {Blazie.Sandbox, :crypto.hash(:sha256, marked)}

      assert :persistent_term.get(key, nil) == nil
      assert {:ok, _, _} = Sandbox.run(marked, %{})
      assert {engine, module} = :persistent_term.get(key)

      # Ten more runs reuse exactly that compilation.
      for _ <- 1..10, do: {:ok, _, _} = Sandbox.run(marked, %{})
      assert :persistent_term.get(key) == {engine, module}
    end
  end
end
