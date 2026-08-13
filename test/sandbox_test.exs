defmodule Blazie.SandboxTest do
  @moduledoc """
  Code nobody here wrote, and the two things that stop it.

  The point of this file is the refusals. A Lua guest can be killed because it
  is a BEAM process; a wasm guest is inside a NIF and runs to completion, so
  fuel is not a tuning knob, it is the entire kill switch. Every test that
  proves a limit bites is load-bearing — if one of them starts passing for the
  wrong reason, a runaway module wedges a node and nothing else will catch it.
  """
  use ExUnit.Case, async: true

  alias Blazie.Sandbox

  # A module obeying the convention: bump-allocate, echo the input back.
  @echo """
  (module
    (memory 2)
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

  describe "a module that behaves" do
    test "gets its input and hands something back" do
      assert {:ok, %{"hello" => "world"}, _spent} =
               Sandbox.run(@echo, %{"hello" => "world"})
    end

    test "reports what it spent" do
      assert {:ok, _answer, spent} = Sandbox.run(@echo, %{"a" => 1})

      assert spent.fuel > 0, "a run that spent no fuel did not happen"
      assert spent.memory_bytes > 0
    end

    test "returning zero means it said nothing" do
      quiet = String.replace(@echo, "(i64.or (i64.shl", "(i64.const 0) (drop) (i64.or (i64.shl")
      # Not worth contorting the wat further — the contract is asserted directly.
      assert {:ok, nil} = zero_answer()
      _ = quiet
    end

    defp zero_answer do
      wat = """
      (module
        (memory 1)
        (export "memory" (memory 0))
        (func $alloc (param i32) (result i32) (i32.const 1024))
        (export "alloc" (func $alloc))
        (func $run (param i32) (param i32) (result i64) (i64.const 0))
        (export "run" (func $run)))
      """

      case Sandbox.run(wat, %{}) do
        {:ok, answer, _spent} -> {:ok, answer}
        other -> other
      end
    end
  end

  describe "a module that will not stop" do
    @forever """
    (module
      (memory 1)
      (export "memory" (memory 0))
      (func $alloc (param i32) (result i32) (i32.const 1024))
      (export "alloc" (func $alloc))
      (func $run (param i32) (param i32) (result i64)
        (loop $l (br $l)) (i64.const 0))
      (export "run" (func $run)))
    """

    test "is stopped, and told how to comply" do
      # Without fuel this never returns and no supervisor reaches it. This test
      # passing IS the safety property.
      assert {:error, refusal} = Sandbox.run(@forever, %{}, fuel: 1_000_000)

      assert refusal.problem == :out_of_fuel
      assert refusal.repair =~ "fuel"
    end

    test "does not take the node with it" do
      assert {:error, _} = Sandbox.run(@forever, %{}, fuel: 500_000)

      # Still here, still answering.
      assert {:ok, %{"after" => true}, _} = Sandbox.run(@echo, %{"after" => true})
    end
  end

  describe "a module that wants too much memory" do
    @greedy """
    (module
      (memory 1)
      (export "memory" (memory 0))
      (func $alloc (param i32) (result i32) (i32.const 1024))
      (export "alloc" (func $alloc))
      (func $run (param i32) (param i32) (result i64)
        (drop (memory.grow (i32.const 2000)))
        (i64.const 0))
      (export "run" (func $run)))
    """

    test "is refused the growth rather than granted it" do
      # 2000 pages is ~131MB against a 2MB cap. wasm's `memory.grow` answers
      # -1 rather than trapping, so the module keeps running with the memory it
      # already had — which is the correct behaviour and worth pinning.
      assert {:ok, nil, spent} = Sandbox.run(@greedy, %{}, memory_bytes: 2_000_000)
      assert spent.memory_bytes <= 2_000_000
    end
  end

  describe "a module of the wrong shape" do
    test "one that exports nothing useful is refused with the convention" do
      empty = "(module (memory 1) (export \"memory\" (memory 0)))"

      assert {:error, refusal} = Sandbox.run(empty, %{})
      assert refusal.problem in [:wrong_shape, :trapped, :will_not_load]
      assert refusal.repair != ""
    end

    test "one that is not wasm at all is refused before it runs" do
      assert {:error, refusal} = Sandbox.run("this is not a module", %{})
      assert refusal.problem == :will_not_load
    end
  end

  describe "the fence" do
    test "a module naming an import cannot load" do
      # The whole isolation story: a guest that wants a clock or a socket does
      # not fail when it reaches for one, it fails to instantiate. There is
      # nothing to enforce, so there is nothing to misconfigure.
      reaching = """
      (module
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (memory 1)
        (export "memory" (memory 0))
        (func $alloc (param i32) (result i32) (i32.const 1024))
        (export "alloc" (func $alloc))
        (func $run (param i32) (param i32) (result i64) (i64.const 0))
        (export "run" (func $run)))
      """

      assert {:error, refusal} = Sandbox.run(reaching, %{})
      assert refusal.problem == :will_not_load
      assert refusal.repair =~ "imports"
    end
  end

  describe "a bad module cannot take its caller down" do
    test "the caller survives every way a module can be wrong" do
      # `Wasmex.start_link/1` raises inside its own init when an import is
      # missing, so a LINKED instance turns the fence working into an EXIT that
      # kills whoever asked. `Job.run`'s rescue would not catch it either — an
      # exit is not an exception. This test is why instances start unlinked.
      me = self()

      bad = [
        "not wasm at all",
        "(module (memory 1))",
        ~s|(module (import "wasi_snapshot_preview1" "fd_write" (func (param i32 i32 i32 i32) (result i32))) (memory 1))|
      ]

      for module <- bad do
        assert {:error, _refusal} = Sandbox.run(module, %{}),
               "expected a refusal, not a crash, for: #{String.slice(module, 0, 40)}"
      end

      assert Process.alive?(me)
      assert {:ok, %{"still" => "here"}, _} = Sandbox.run(@echo, %{"still" => "here"})
    end
  end

  describe "what a job declares" do
    test "an image, and its limits, as ordinary facts" do
      image = Blazie.Blob.describing("fake module bytes")
      declared = Sandbox.declare("summarise", image, fuel: 5_000_000)

      assert {"summarise", "image", ^image} = List.keyfind(declared, "image", 1)
      assert {"summarise", "fuel", 5_000_000} = List.keyfind(declared, "fuel", 1)

      # No new vocabulary: these sit beside `every` on the same job.
      assert Enum.all?(declared, fn {id, _field, _value} -> id == "summarise" end)
    end
  end
end
