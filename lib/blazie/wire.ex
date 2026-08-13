defmodule Blazie.Wire do
  @moduledoc """
  What travels, and how it becomes what the engine holds.

  Inside, an id is any term and an attribute is an atom. Over the wire both
  have to be something JSON can carry, and the translation is where two things
  have to hold:

    * **A caller cannot grow the atom table.** Attribute names are binaries
      all the way down, so nothing a caller sends ever becomes an atom. That
      is not a check here — it is why `Fact.attribute` is a binary at all.
      Doctrine 10 has tenants adding attributes while the system runs, and
      atoms are never collected, so the two could not both be true.

    * **A caller cannot claim a fact was derived.** A client is the outside
      world by definition, so everything it writes names no formula and no job.
      Sending `by` is refused rather than dropped — silently ignoring it would
      let a caller believe provenance was recorded when it was not.

  Every refusal carries its repair, the same as everywhere else.
  """

  alias Blazie.{Fact, Symbol}

  @type refusal :: %{problem: atom(), repair: String.t()}

  # ── in ─────────────────────────────────────────────────────────────────────

  @doc "A wire pattern becomes a keyword pattern, or a refusal."
  @spec pattern(map()) :: {:ok, keyword()} | {:error, refusal()}
  def pattern(sent) when is_map(sent) do
    Enum.reduce_while(["id", "attribute", "value", "by"], {:ok, []}, fn key, {:ok, acc} ->
      case {Map.fetch(sent, key), key} do
        {:error, _} -> {:cont, {:ok, acc}}
        {{:ok, value}, "attribute"} -> resolve_attribute(value, acc)
        {{:ok, value}, "by"} -> resolve_attribute(value, acc, :by)
        {{:ok, value}, _} -> {:cont, {:ok, [{String.to_existing_atom(key), value} | acc]}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  # Whatever a caller sends, it sends. A shape that is not a pattern is refused
  # on its own terms rather than reaching a guard with nothing to match.
  def pattern(sent),
    do:
      {:error,
       %{
         problem: :not_a_pattern,
         repair:
           "A pattern is an object of id, attribute, value or by — any of them, all of them, " <>
             "or none. #{inspect(sent)} is not one."
       }}

  @doc """
  A wire assertion becomes a three-wide assertion, or a refusal.

  Always three wide. A client writes facts that came from outside, and a fact
  from outside names nothing.
  """
  @spec assertion(map()) :: {:ok, tuple()} | {:error, refusal()}
  def assertion(%{"by" => _}),
    do:
      {:error,
       %{
         problem: :cannot_claim_derivation,
         repair:
           "A written fact came from outside and names no formula. Drop `by` — if this value " <>
             "was derived, declare the formula that derives it and let it produce the fact."
       }}

  def assertion(%{"id" => id, "attribute" => attribute, "value" => value}) do
    with {:ok, id} <- check_id(id),
         {:ok, attribute} <- existing_attribute(attribute),
         {:ok, value} <- decode_value(value) do
      {:ok, {id, attribute, value}}
    end
  end

  def assertion(_sent),
    do:
      {:error,
       %{
         problem: :incomplete_assertion,
         repair: "A fact is an id, an attribute and a value. Send all three."
       }}

  @doc "A wire snapshot name becomes an internal one, or a refusal."
  @spec snapshot_name(map()) :: {:ok, %{String.t() => non_neg_integer()}} | {:error, refusal()}
  def snapshot_name(sent) when is_map(sent) do
    sent
    |> Enum.find(fn {_ledger, tx} -> not (is_integer(tx) and tx >= 0) end)
    |> case do
      nil ->
        {:ok, sent}

      {ledger, _} ->
        {:error,
         %{
           problem: :bad_transaction,
           repair:
             "A snapshot name maps each ledger to the transaction it was read at. " <>
               "#{inspect(ledger)} was given something that is not a transaction number."
         }}
    end
  end

  def snapshot_name(sent),
    do:
      {:error,
       %{
         problem: :bad_transaction,
         repair:
           "A snapshot name maps each ledger to the transaction it was read at. " <>
             "#{inspect(sent)} is not a name."
       }}

  # ── out ────────────────────────────────────────────────────────────────────

  @doc "A snapshot name, ready to hand to a caller."
  @spec encode_snapshot_name(%{String.t() => non_neg_integer()}) :: map()
  def encode_snapshot_name(name), do: name

  @doc "A fact, ready to hand to a caller."
  @spec fact(Fact.t()) :: map()
  def fact(%Fact{} = fact) do
    %{
      "id" => fact.id,
      "attribute" => fact.attribute,
      "value" => encode_value(fact.value),
      "tx" => fact.tx,
      "by" => if(fact.by, do: to_string(fact.by))
    }
  end

  # ── the two hazards ────────────────────────────────────────────────────────

  defp resolve_attribute(value, acc, key \\ :attribute) do
    case existing_attribute(value) do
      {:ok, atom} -> {:cont, {:ok, [{key, atom} | acc]}}
      error -> {:halt, error}
    end
  end

  defp existing_attribute(value) when is_binary(value) and value != "", do: {:ok, value}

  defp existing_attribute(value),
    do:
      {:error,
       %{
         problem: :unknown_attribute,
         repair:
           "An attribute is a non-empty name. #{inspect(value)} is not one. Whether it has " <>
             "been defined is the ledger\'s question, answered by the vocabulary check on write."
       }}

  defp check_id(id) when is_integer(id) or is_binary(id), do: {:ok, id}

  defp check_id(id),
    do:
      {:error,
       %{
         problem: :bad_id,
         repair: "An id travels as a number or a string. #{inspect(id)} is neither."
       }}

  # ── values ─────────────────────────────────────────────────────────────────

  defp encode_value(%Symbol{} = symbol),
    do: %{"$symbol" => %{"space" => symbol.space, "values" => symbol.values}}

  defp encode_value(value), do: value

  defp decode_value(%{"$symbol" => _}),
    do:
      {:error,
       %{
         problem: :cannot_write_symbol,
         repair:
           "A symbol is always produced by a formula, never taken from outside. " <>
             "Write the content it stands for and let a formula derive the symbol."
       }}

  defp decode_value(value), do: {:ok, value}
end
