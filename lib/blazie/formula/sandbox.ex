defmodule Blazie.Formula.Sandbox do
  @moduledoc """
  Formulas written by somebody we do not trust (doctrine 14).

  Until this existed the trust tiers were described and unenforced — nothing
  stopped a formula opening a socket. Code that arrives from an app or an agent
  now runs in WebAssembly, and the isolation is structural rather than policy:
  the host builds the guest's entire world out of the functions it hands in,
  and it hands in none. There is no rule being enforced, so there is no rule
  anyone can forget or misconfigure.

  A module that wants something from outside does not fail at the moment it
  reaches — it fails to build at all, because the import it names does not
  exist. That is a better place to find out.

      {:ok, formula} =
        Sandbox.mapping("doubling", wat, over: [attribute: "height"], into: "doubled")

  What comes back is an ordinary `Blazie.Formula`. It records what it read,
  its answers name it, and the engine caches it like any other — the tier
  changes where the body runs, not what a formula is.

  ## What this shape is, and is not

  A mapping applies an exported `apply` to every value matching a pattern.
  That covers the transform case honestly and nothing more: no strings, no
  structures, no access to the snapshot from inside the guest. Widening it
  means designing what the guest may ask for, and every widening is a hole in
  the fence — so it should be done one deliberate import at a time, not by
  handing over WASI.
  """

  alias Blazie.{Formula, Snapshot}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc """
  What the guest is given.

  Empty, and that is the whole design. Kept as a function so it is somewhere to
  look and somewhere for a test to assert on, rather than an absence that has
  to be inferred.
  """
  @spec imports() :: map()
  def imports, do: %{}

  @doc """
  A formula that applies a WebAssembly `apply` to every answer matching
  `over:`, writing the result under `into:`.

  Refused rather than raised if the module will not build, and refused at build
  time rather than at run time if it names an import nobody granted.
  """
  @spec mapping(term(), binary(), keyword()) :: {:ok, Formula.t()} | {:error, refusal()}
  def mapping(id, source, opts) do
    over = Keyword.fetch!(opts, :over)
    into = Keyword.fetch!(opts, :into)

    with {:ok, store} <- store(),
         {:ok, module} <- compile(store, source),
         :ok <- instantiable(store, module) do
      {:ok,
       Formula.new(id, fn snapshot ->
         {:ok, run_store} = Wasmex.Store.new()
         {:ok, run_module} = Wasmex.Module.compile(run_store, source)

         {:ok, guest} =
           Wasmex.start_link(%{store: run_store, module: run_module, links: imports()})

         for fact <- Snapshot.find(snapshot, over), is_integer(fact.value) do
           {:ok, [value]} = Wasmex.call_function(guest, "apply", [fact.value])
           {fact.id, into, value}
         end
       end)}
    end
  end

  defp store do
    case Wasmex.Store.new() do
      {:ok, store} -> {:ok, store}
      _ -> {:error, %{problem: :no_store, repair: "The WebAssembly engine would not start."}}
    end
  end

  defp compile(store, source) do
    case Wasmex.Module.compile(store, source) do
      {:ok, module} ->
        {:ok, module}

      {:error, why} ->
        {:error,
         %{
           problem: :not_a_module,
           repair: "This is not a WebAssembly module the engine will take: #{inspect(why)}"
         }}
    end
  end

  # Building it is the fence. A module naming an import it was not given cannot
  # be instantiated, so code that wants the outside world is refused here
  # rather than somewhere later and quieter. Everything that can go wrong at
  # build time is found at build time — including a missing entry point, which
  # would otherwise surface halfway through answering.
  defp instantiable(store, module) do
    trapping = Process.flag(:trap_exit, true)

    result =
      try do
        case Wasmex.start_link(%{store: store, module: module, links: imports()}) do
          {:ok, pid} -> check_entry_point(pid)
          {:error, why} -> {:error, denied(why)}
        end
      catch
        # Wasmex reports a missing import by dying in init rather than
        # returning, so refusing it means catching that rather than matching.
        :exit, reason -> {:error, denied(reason)}
      after
        Process.flag(:trap_exit, trapping)
      end

    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end

    result
  end

  defp check_entry_point(pid) do
    exists = Wasmex.function_exists(pid, "apply")
    GenServer.stop(pid)

    if exists do
      :ok
    else
      {:error,
       %{
         problem: :no_entry_point,
         repair:
           "A mapping calls an exported function named `apply`, taking one number and " <>
             "returning one. This module does not export it."
       }}
    end
  end

  defp denied(why) do
    %{
      problem: :wanted_something_it_was_not_given,
      repair:
        "This module names an import that does not exist here. Tenant code holds no " <>
          "capability at all — no network, no clock, no filesystem — so anything it needs " <>
          "must come in as an answer it was handed. (#{inspect(why)})"
    }
  end
end
