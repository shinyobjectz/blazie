defmodule Blazie.ToolSandboxedTest do
  @moduledoc """
  A tool that is a module runs where untrusted code has to run.

  `Tool` said it plainly — "a tool is a declared job with two extra attributes"
  — and `Sandbox` said "the job is still the job". Both true, and `Tool.run/3`
  read `source` and nothing else, so `Job` reached the sandbox and a tool could
  only ever be Lua somebody in this tree wrote.

  That is the wrong way round. Authored Lua is the trusted case; a module is the
  untrusted one, and an agent must not be able to run the untrusted one anywhere
  else.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Blob, Snapshot, Tool, World}

  # Hands its input straight back, which is enough to prove the call reached a
  # guest and the answer came out of one.
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

  setup do
    {:ok, world} = World.open("toolbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> World.close(world) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Tool.seed() ++ Blazie.Sandbox.seed())
    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  test "a tool declared with an image runs in the sandbox", %{world: world} do
    image = %Blob{key: "tools/echo.wasm", hash: "sha256:x", bytes: byte_size(@echo)}

    {:ok, _} =
      World.append(
        world,
        Tool.declare("echo", describe: "hands back what it was given", takes: %{}) ++
          Blazie.Sandbox.declare("echo", image)
      )

    # `bytes:` stands in for the fetch, so this tests the dispatch rather than a
    # bucket — the same reason `Sandbox.run/3` takes bytes rather than a blob.
    assert {:ok, %{"q" => "ada"}} =
             Tool.run(snapshot(world), %{name: "echo", arguments: %{"q" => "ada"}}, bytes: @echo)
  end

  test "a tool with neither says which it is missing", %{world: world} do
    {:ok, _} = World.append(world, Tool.declare("bare", describe: "nothing", takes: %{}))

    assert {:error, refusal} =
             Tool.run(snapshot(world), %{name: "bare", arguments: %{}})

    assert refusal.problem == :no_such_tool
    assert refusal.repair =~ "neither"
  end

  test "an authored tool still runs its lua", %{world: world} do
    {:ok, _} =
      World.append(
        world,
        Tool.declare("double",
          describe: "doubles a number",
          takes: %{},
          source: "answer.out = args.n * 2"
        )
      )

    assert {:ok, %{"out" => 84}} =
             Tool.run(snapshot(world), %{name: "double", arguments: %{"n" => 42}})
  end

  test "a module that will not stop is stopped by the fuel it declared", %{world: world} do
    # A tool an agent may call, looping forever. This is the property the whole
    # arrangement exists for: a NIF runs to completion, no supervisor reaches
    # inside one, and fuel is the only thing that ends it. Declared on the tool,
    # so the ceiling is a fact somebody can read rather than a default.
    forever = """
    (module
      (memory 1)
      (export "memory" (memory 0))
      (func $alloc (param i32) (result i32) (i32.const 1024))
      (export "alloc" (func $alloc))
      (func $run (param i32) (param i32) (result i64)
        (loop $l (br $l)) (i64.const 0))
      (export "run" (func $run)))
    """

    image = %Blob{key: "tools/forever.wasm", hash: "sha256:y", bytes: byte_size(forever)}

    {:ok, _} =
      World.append(
        world,
        Tool.declare("forever", describe: "never finishes", takes: %{}) ++
          Blazie.Sandbox.declare("forever", image, fuel: 1_000_000)
      )

    assert {:error, refusal} =
             Tool.run(snapshot(world), %{name: "forever", arguments: %{}}, bytes: forever)

    assert refusal.problem == :out_of_fuel

    # And the node is still here, which is the other half of the same claim: a
    # guest that had to be killed did not take the host with it.
    echo = %Blob{key: "tools/echo.wasm", hash: "sha256:x", bytes: byte_size(@echo)}

    {:ok, _} =
      World.append(
        world,
        Tool.declare("after", describe: "e", takes: %{}) ++ Blazie.Sandbox.declare("after", echo)
      )

    assert {:ok, %{"still" => "here"}} =
             Tool.run(snapshot(world), %{name: "after", arguments: %{"still" => "here"}},
               bytes: @echo
             )
  end
end
