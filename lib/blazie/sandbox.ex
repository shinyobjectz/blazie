defmodule Blazie.Sandbox do
  @moduledoc """
  Running code nobody here wrote, inside a job.

  Not a word in the vocabulary and not a thing anybody names. A sandbox is *how*
  a job's work runs when that work arrived as a wasm module rather than as Lua:
  the job is still the job, the image is a `Blazie.Blob`, and the limits are
  attributes beside `every`. Nothing new to learn.

      {job, "is", "job"}
      {job, "image", %Blob{}}      -- the module, as bytes in object storage
      {job, "fuel", 10_000_000}    -- how much it may spend
      {job, "memory_bytes", 67108864}

  ## Why a job and never a formula

  A formula's answer is cached under a snapshot name forever, so an answer that
  differed on a second run would be a wrong answer with no expiry. Nothing about
  a foreign binary promises it will not differ. A job's answer happened once and
  is written down, which is the honest home for it — and a job is already the
  only thing handed the outside world, so a sandbox reaching one adds no hole.

  ## Two limits, and they are not optional

  A Lua guest gets a deadline because it is a BEAM process and `Process.exit`
  reaches it. A wasm guest is inside a NIF, and a NIF runs to completion — no
  signal, no timeout, no supervisor will stop it. Measured here: an infinite
  loop with no fuel never returns.

  So fuel is not a tuning knob, it is the entire kill switch, and
  `StoreLimits.memory_size` is its counterpart for memory. Both are enforced by
  wasmtime rather than by anything in this file, which is the same reason the
  Lua fence is trusted: there is nothing to enforce, so there is nothing to
  forget.

  ## The calling convention

  Deliberately tiny, and deliberately not WASI. A module exports:

      alloc(i32) -> i32          give me a buffer this big
      run(i32, i32) -> i64       here is your input; return (ptr << 32) | len

  The host writes JSON in, reads JSON out, and hands the guest nothing else. A
  module that wants a clock or a socket does not fail when it reaches for one —
  it fails to instantiate, because the import it names does not exist. That is a
  better place to find out, and it is what makes the isolation structural rather
  than a rule somebody has to keep.
  """

  alias Blazie.Blob

  @type refusal :: %{problem: atom(), repair: String.t()}

  # Enough to do real work and not enough to hang a node. A caller that needs
  # more says so on the job; a caller that says nothing gets a number that
  # cannot hurt anybody.
  @fuel 10_000_000
  @memory_bytes 64 * 1024 * 1024

  @doc """
  Run a module against some input, and hand back what it returned.

  `bytes` is the module itself — already fetched, because fetching is the job's
  business and this should be testable without a bucket.
  """
  @spec run(binary(), term(), keyword()) ::
          {:ok, term(), %{fuel: non_neg_integer(), memory_bytes: non_neg_integer()}}
          | {:error, refusal()}
  def run(bytes, input, opts \\ []) when is_binary(bytes) do
    fuel = Keyword.get(opts, :fuel, @fuel)
    memory_bytes = Keyword.get(opts, :memory_bytes, @memory_bytes)

    with {:ok, engine, module} <- compiled(bytes),
         {:ok, store} <- store(fuel, memory_bytes, engine),
         {:ok, pid, memory} <- instantiate(store, module),
         {:ok, encoded} <- encode(input),
         {:ok, answer} <- exchange(store, pid, memory, encoded) do
      {:ok, answer, spent(store, memory, fuel)}
    end
  end

  @doc """
  Run a WASI module, handing it stdin and reading stdout.

  The other contract, and the one a real language runtime needs. `run/3` speaks
  a bespoke protocol — export `alloc`, take a pointer, hand back a packed i64 —
  which is fine for a module written to be a blazie guest and impossible for one
  that was not. CPython compiled to wasm does not export `alloc`; it exports
  `_start`, and it talks over stdio like every other program.

  So: input goes in on stdin, whatever it prints comes back on stdout, and a
  non-zero exit comes back as a refusal carrying stderr. That is enough to run
  an interpreter, which is what makes a guest able to be Python rather than
  hand-written wasm.

  ## The fence is unchanged, which is the part worth checking

  Fuel is on the engine, so it bounds a WASI guest exactly as it bounds any
  other — the reason it exists does not change: a NIF runs to completion and no
  supervisor reaches inside one.

  What WASI adds is capability, and it is all opt-in. No `preopen` means no
  filesystem: a guest sees no directories at all unless a caller names one. No
  `env` means no environment. There is no network in WASI preview 1 to grant.
  A caller that hands over a directory has widened the fence deliberately and
  can be asked why; the default hands over nothing.
  """
  @spec run_wasi(binary(), binary(), keyword()) ::
          {:ok, String.t(), %{fuel: non_neg_integer()}} | {:error, refusal()}
  def run_wasi(bytes, input \\ "", opts \\ []) when is_binary(bytes) do
    fuel = Keyword.get(opts, :fuel, @fuel)
    memory_bytes = Keyword.get(opts, :memory_bytes, @memory_bytes)

    {:ok, stdin} = Wasmex.Pipe.new()
    {:ok, stdout} = Wasmex.Pipe.new()
    {:ok, stderr} = Wasmex.Pipe.new()

    if input != "" do
      Wasmex.Pipe.write(stdin, input)
      Wasmex.Pipe.seek(stdin, 0)
    end

    wasi = %Wasmex.Wasi.WasiOptions{
      stdin: stdin,
      stdout: stdout,
      stderr: stderr,
      args: Keyword.get(opts, :args, []),
      # Nothing by default. A guest that can read the disk is not a sandbox, and
      # every one of these is a hole somebody has to have decided to make.
      env: Keyword.get(opts, :env, %{}),
      preopen: Keyword.get(opts, :preopen, [])
    }

    with {:ok, engine, module} <- compiled(bytes),
         {:ok, store} <-
           Wasmex.Store.new_wasi(wasi, %Wasmex.StoreLimits{memory_size: memory_bytes}, engine),
         :ok <- Wasmex.StoreOrCaller.set_fuel(store, fuel),
         {:ok, pid} <- start_unlinked(store, module) do
      started(pid, store, stdout, stderr, fuel)
    else
      {:error, why} -> {:error, refusal(why)}
    end
  end

  # Compiled once per distinct module, however many times it runs. The cost
  # was paid per EVALUATION — for a CPython image that is most of a second,
  # every read, forever (C9). The engine travels with the module because a
  # wasmtime module only instantiates against stores from the engine that
  # compiled it. `:persistent_term` on purpose: no owner to die, and a
  # deployment's set of distinct modules is small and worth keeping warm for
  # the life of the node.
  defp compiled(bytes) do
    key = {__MODULE__, :crypto.hash(:sha256, bytes)}

    case :persistent_term.get(key, nil) do
      {engine, module} ->
        {:ok, engine, module}

      nil ->
        config = Wasmex.EngineConfig.consume_fuel(%Wasmex.EngineConfig{}, true)

        with {:ok, engine} <- Wasmex.Engine.new(config),
             {:ok, probe} <- Wasmex.Store.new(nil, engine),
             {:ok, module} <- Wasmex.Module.compile(probe, bytes) do
          :persistent_term.put(key, {engine, module})
          {:ok, engine, module}
        else
          {:error, why} ->
            {:error,
             %{
               problem: :will_not_load,
               repair: "This module did not compile: #{String.slice(to_string(why), 0, 300)}"
             }}
        end
    end
  end

  # `_start` is WASI's entry point. It returning an error is the guest exiting
  # non-zero, which is a failure the caller wants to read rather than a crash.
  defp started(pid, store, stdout, stderr, fuel) do
    case Wasmex.call_function(pid, :_start, []) do
      {:ok, _} ->
        Wasmex.Pipe.seek(stdout, 0)
        {:ok, Wasmex.Pipe.read(stdout), spent_fuel(store, fuel)}

      {:error, why} ->
        Wasmex.Pipe.seek(stderr, 0)
        said = Wasmex.Pipe.read(stderr)

        {:error,
         %{
           problem: problem_of(why),
           repair:
             "The guest exited without finishing: #{String.slice(to_string(why), 0, 200)}" <>
               if(said == "", do: "", else: " It said: #{String.slice(said, 0, 400)}")
         }}
    end
  end

  defp problem_of(why) do
    if to_string(why) =~ "fuel", do: :out_of_fuel, else: :would_not_finish
  end

  defp spent_fuel(store, started_with) do
    case Wasmex.StoreOrCaller.get_fuel(store) do
      {:ok, left} -> %{fuel: started_with - left}
      _ -> %{fuel: 0}
    end
  end

  defp refusal(why) do
    %{
      problem: :would_not_start,
      repair: "The module would not start: #{String.slice(to_string(why), 0, 300)}"
    }
  end

  @doc "What a job declares when its work is a module rather than a function."
  @spec declare(term(), Blob.t(), keyword()) :: [tuple()]
  def declare(id, %Blob{} = image, opts \\ []) do
    [{id, "image", image}] ++
      for {field, default} <- [fuel: @fuel, memory_bytes: @memory_bytes],
          value = Keyword.get(opts, field, default),
          do: {id, to_string(field), value}
  end

  @doc "The attributes a sandboxed job is described with."
  @spec seed() :: [tuple()]
  def seed do
    Blazie.Attribute.define("image", answers: "any") ++
      Blazie.Attribute.define("fuel", answers: "integer") ++
      Blazie.Attribute.define("memory_bytes", answers: "integer", cardinality: "many") ++
      Blazie.Attribute.define("fuel_spent", answers: "integer", cardinality: "many")
  end

  # ── the world a guest is given ─────────────────────────────────────────────

  defp store(fuel, memory_bytes, engine) do
    with {:ok, store} <- Wasmex.Store.new(%Wasmex.StoreLimits{memory_size: memory_bytes}, engine),
         :ok <- Wasmex.StoreOrCaller.set_fuel(store, fuel) do
      {:ok, store}
    else
      _ -> {:error, %{problem: :no_sandbox, repair: "This node could not build a sandbox."}}
    end
  end

  # No imports. A module naming one fails HERE, before it runs a single
  # instruction, which is the whole of the fence.
  #
  # Started UNLINKED, and that is not a detail. `Wasmex.start_link/1` raises
  # inside its own init when a module names an import that does not exist —
  # which is the fence doing its job — and a link turns that into an EXIT that
  # kills whoever asked. A malformed image would have taken the job runner's
  # task down with it, and `Job.run`'s `rescue` would not have caught it,
  # because an exit is not an exception.
  defp instantiate(store, module) do
    with {:ok, pid} <- start_unlinked(store, module),
         {:ok, memory} <- Wasmex.memory(pid) do
      {:ok, pid, memory}
    else
      {:error, why} ->
        {:error,
         %{
           problem: :will_not_load,
           repair:
             "This module did not instantiate: #{inspect(why)}. A sandbox hands in no " <>
               "imports, so a module that names one cannot load."
         }}
    end
  end

  defp start_unlinked(store, module) do
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      result = Wasmex.start_link(%{store: store, module: module})
      send(parent, {:started, result})

      # Hold the instance alive for as long as whoever asked for it lives —
      # and STOP it when they die. The holder used to just exit, and a normal
      # exit does not propagate through a link, so every evaluation left a
      # live Wasmex server behind (C9's third defect: measured as a process
      # per read, forever).
      with {:ok, pid} <- result do
        ref = Process.monitor(parent)

        receive do
          {:DOWN, ^ref, :process, ^parent, _why} -> stop_quietly(pid)
          {:EXIT, ^pid, _why} -> :ok
        end
      end
    end)

    receive do
      {:started, {:ok, pid}} -> {:ok, pid}
      {:started, {:error, why}} -> {:error, why}
    after
      30_000 -> {:error, "the sandbox did not start"}
    end
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp encode(input) do
    case Jason.encode(input) do
      {:ok, json} -> {:ok, json}
      {:error, why} -> {:error, %{problem: :input_not_json, repair: Exception.message(why)}}
    end
  end

  defp exchange(store, pid, memory, input) do
    size = byte_size(input)

    with {:ok, [ptr]} <- call(pid, "alloc", [size]),
         :ok <- Wasmex.Memory.write_binary(store, memory, ptr, input),
         {:ok, [packed]} <- call(pid, "run", [ptr, size]) do
      read_answer(store, memory, packed)
    end
  end

  # `run` returns the output's position and length in one i64, because a wasm
  # function returns one value and two numbers have to fit in it.
  defp read_answer(_store, _memory, 0),
    do: {:ok, nil}

  defp read_answer(store, memory, packed) do
    out_ptr = Bitwise.bsr(packed, 32)
    out_len = Bitwise.band(packed, 0xFFFFFFFF)

    # `read_binary/4` hands back the bytes, not `{:ok, bytes}` — so this reads
    # then decodes, rather than threading both through one `with`.
    with raw when is_binary(raw) <- Wasmex.Memory.read_binary(store, memory, out_ptr, out_len),
         {:ok, decoded} <- Jason.decode(raw) do
      {:ok, decoded}
    else
      _ ->
        {:error,
         %{
           problem: :output_not_json,
           repair:
             "A sandbox returns json: `run` hands back (ptr << 32) | len pointing at it. " <>
               "Return 0 to say nothing."
         }}
    end
  end

  defp call(pid, function, args) do
    case Wasmex.call_function(pid, function, args) do
      {:ok, values} ->
        {:ok, values}

      {:error, message} ->
        {:error, refusal_from(to_string(message), function)}
    end
  end

  # A trap is how every limit announces itself, so the message is the only thing
  # that says which one — and a caller told "it trapped" cannot do anything
  # about it, while a caller told "it ran out of fuel" can raise the fuel.
  defp refusal_from(message, function) do
    cond do
      String.contains?(message, "fuel") ->
        %{
          problem: :out_of_fuel,
          repair:
            "This spent all its fuel and was stopped. Raise `fuel` on the job if the work " <>
              "is honest; a module that never finishes will never finish."
        }

      String.contains?(message, "memory") or String.contains?(message, "allocat") ->
        %{
          problem: :out_of_memory,
          repair: "This asked for more memory than the job allows. Raise `memory_bytes`."
        }

      String.contains?(message, "not exported") or String.contains?(message, "unknown import") ->
        %{
          problem: :wrong_shape,
          repair:
            "A sandbox calls `alloc(i32) -> i32` and `run(i32, i32) -> i64`. This module " <>
              "does not export #{inspect(function)}."
        }

      true ->
        %{problem: :trapped, repair: message}
    end
  end

  defp spent(store, memory, started_with) do
    left =
      case Wasmex.StoreOrCaller.get_fuel(store) do
        {:ok, remaining} -> remaining
        _ -> 0
      end

    %{fuel: started_with - left, memory_bytes: Wasmex.Memory.size(store, memory)}
  end
end
