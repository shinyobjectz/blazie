defmodule Blazie.Job.Author do
  @moduledoc """
  Agent-authored jobs, validated before they land — the parser whose error
  IS the product.

  An agent that writes a job needs the refusal more than a person does: a
  person reads a stack trace, an agent repairs from `{line, description,
  repair}` or loops forever. So the source is compiled — never run — before
  anything becomes a fact, and every way it can be wrong comes back as a
  line-addressed repair. The shape is `Nexus.Jobs.author/1`'s, which
  socialite built for exactly this loop.

  The id is guarded too: authored jobs arrive from outside, an id becomes a
  registry key, and the wire's rule holds everywhere — nothing a caller
  sends may mint an atom or smuggle a term where a name belongs.
  """

  alias Blazie.Job

  @type complaint :: %{line: non_neg_integer(), description: String.t(), repair: String.t()}

  @doc """
  The facts declaring an authored job, or every reason it cannot be one.

      Author.declare("refresh", "rates.gbp = 1.27", every: 300)
  """
  @spec declare(term(), String.t(), keyword()) :: {:ok, [tuple()]} | {:error, [complaint()]}
  def declare(id, source, opts \\ []) do
    with :ok <- named(id),
         :ok <- parses(source) do
      {:ok, Job.declare(id, opts) ++ [{id, "source", source}]}
    end
  end

  @doc "Compile only — the check an editor runs on every keystroke."
  @spec parses(String.t()) :: :ok | {:error, [complaint()]}
  def parses(source) when is_binary(source) do
    case :luerl.load(source, :luerl.init()) do
      {:ok, _chunk, _state} ->
        :ok

      {:error, errors, _warnings} ->
        {:error, Enum.map(errors, &complaint/1)}
    end
  rescue
    error ->
      {:error,
       [
         %{
           line: 0,
           description: Exception.message(error),
           repair: "The source did not compile at all. Check it is Lua."
         }
       ]}
  end

  def parses(_other) do
    {:error,
     [
       %{
         line: 0,
         description: "the source is not a string",
         repair: "A job's source is Lua text. Send the code itself."
       }
     ]}
  end

  defp named(id) when is_binary(id) and id != "" do
    if String.starts_with?(id, "$") do
      {:error,
       [
         %{
           line: 0,
           description: "the id is reserved",
           repair: "Names beginning with `$` belong to the node. Pick another id."
         }
       ]}
    else
      :ok
    end
  end

  defp named(id) do
    {:error,
     [
       %{
         line: 0,
         description: "the id is #{inspect(id)}",
         repair:
           "An authored job's id is a non-empty string — it becomes a registry key, and " <>
             "nothing sent from outside may be anything a registry key can leak through."
       }
     ]}
  end

  # Luerl's error terms carry the line and a formatter; both are used rather
  # than re-derived, because the parser knows what it meant.
  defp complaint({line, module, reason}) when is_integer(line) do
    description =
      try do
        module.format_error(reason) |> to_string()
      rescue
        _ -> inspect(reason)
      end

    %{
      line: line,
      description: description,
      repair: "Fix line #{line}: #{description}. Nothing was declared."
    }
  end

  defp complaint(other) do
    %{
      line: 0,
      description: inspect(other),
      repair: "The source did not parse. Nothing was declared."
    }
  end
end
