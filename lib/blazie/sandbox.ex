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

    with {:ok, store} <- store(fuel, memory_bytes),
         {:ok, pid, memory} <- instantiate(store, bytes),
         {:ok, encoded} <- encode(input),
         {:ok, answer} <- exchange(store, pid, memory, encoded) do
      {:ok, answer, spent(store, memory, fuel)}
    end
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

  defp store(fuel, memory_bytes) do
    config = Wasmex.EngineConfig.consume_fuel(%Wasmex.EngineConfig{}, true)

    with {:ok, engine} <- Wasmex.Engine.new(config),
         {:ok, store} <- Wasmex.Store.new(%Wasmex.StoreLimits{memory_size: memory_bytes}, engine),
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
  defp instantiate(store, bytes) do
    with {:ok, module} <- Wasmex.Module.compile(store, bytes),
         {:ok, pid} <- start_unlinked(store, module),
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
      send(parent, {:started, Wasmex.start_link(%{store: store, module: module})})
      # Hold the instance alive for as long as whoever asked for it lives.
      ref = Process.monitor(parent)

      receive do
        {:DOWN, ^ref, :process, ^parent, _why} -> :ok
      end
    end)

    receive do
      {:started, {:ok, pid}} -> {:ok, pid}
      {:started, {:error, why}} -> {:error, why}
    after
      30_000 -> {:error, "the sandbox did not start"}
    end
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
