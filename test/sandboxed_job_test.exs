defmodule Blazie.SandboxedJobTest do
  @moduledoc """
  A job whose body is an image, end to end.

  The point is that it is still a job: same runner, same cadence, same read set,
  same failure facts. Only what happens inside changes, and the seam is a `work`
  function like any other.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Blob, Job, Snapshot, World}

  # A module that echoes back one assertion, obeying the sandbox convention.
  @writer """
  (module
    (memory 2)
    (export "memory" (memory 0))
    (data (i32.const 2048) "[[\\"ada\\",\\"seen\\",1]]")
    (func $alloc (param i32) (result i32) (i32.const 1024))
    (export "alloc" (func $alloc))
    (func $run (param i32) (param i32) (result i64)
      (i64.or (i64.shl (i64.const 2048) (i64.const 32)) (i64.const 18)))
    (export "run" (func $run)))
  """

  # Stands in for object storage: a map from key to bytes.
  defmodule Bucket do
    def get(opts, key) do
      case Map.fetch(Keyword.fetch!(opts, :holding), key) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :missing}
      end
    end
  end

  setup do
    name = "sbjob-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} =
      World.append(
        world,
        Attribute.seed() ++ Job.seed() ++ Blazie.Sandbox.seed() ++
          Attribute.define("seen", answers: "integer", cardinality: "many")
      )

    image = Blob.describing(@writer)
    {:ok, _} = World.append(world, Job.declare("agent") ++ Blazie.Sandbox.declare("agent", image))

    %{world: world, image: image, holding: %{image.key => @writer}}
  end

  defp snapshot(world), do: Snapshot.open([world])

  test "runs its image and writes what it returned", ctx do
    work = Job.sandboxed(snapshot(ctx.world), "agent", Bucket, holding: ctx.holding)
    job = Job.new("agent", work)

    assert {:ok, _tx} = Job.run(job, ctx.world, snapshot(ctx.world), 1000)

    # The guest's assertion landed, naming the job rather than the guest.
    assert [%{value: 1, by: "agent"}] = Snapshot.find(snapshot(ctx.world), id: "ada", attribute: "seen")
  end

  test "records what the run spent", ctx do
    work = Job.sandboxed(snapshot(ctx.world), "agent", Bucket, holding: ctx.holding)
    {:ok, _tx} = Job.run(Job.new("agent", work), ctx.world, snapshot(ctx.world), 1000)

    assert is_integer(Snapshot.value(snapshot(ctx.world), "agent", "fuel_spent"))
  end

  test "an image that is not there is a failure fact, not a crash", ctx do
    work = Job.sandboxed(snapshot(ctx.world), "agent", Bucket, holding: %{})
    {:failed, _tx, reason} = Job.run(Job.new("agent", work), ctx.world, snapshot(ctx.world), 1000)

    assert reason =~ "Nothing is stored"
    assert Snapshot.find(snapshot(ctx.world), id: "agent", attribute: "failed") != []
  end

  test "bytes that do not match the hash are refused", ctx do
    # Content-addressed: different bytes under the same key are not a stale
    # version, they are somebody else's module. Running them would be running
    # whatever the bucket happened to hold.
    tampered = %{ctx.image.key => String.replace(@writer, "1024", "2048")}
    work = Job.sandboxed(snapshot(ctx.world), "agent", Bucket, holding: tampered)

    {:failed, _tx, reason} = Job.run(Job.new("agent", work), ctx.world, snapshot(ctx.world), 1000)
    assert reason =~ "hashing to"
  end

  test "a job with no image says so rather than running nothing", ctx do
    {:ok, _} = World.append(ctx.world, Job.declare("empty"))
    work = Job.sandboxed(snapshot(ctx.world), "empty", Bucket, holding: ctx.holding)

    {:failed, _tx, reason} = Job.run(Job.new("empty", work), ctx.world, snapshot(ctx.world), 1000)
    assert reason =~ "no image"
  end

  test "a guest cannot claim provenance", ctx do
    # The guest returns three-wide rows and `Job.run` stamps them. There is no
    # fourth slot it could put a producer in.
    work = Job.sandboxed(snapshot(ctx.world), "agent", Bucket, holding: ctx.holding)
    {:ok, _tx} = Job.run(Job.new("agent", work), ctx.world, snapshot(ctx.world), 1000)

    assert Snapshot.find(snapshot(ctx.world), id: "ada")
           |> Enum.all?(&(&1.by == "agent"))
  end
end
