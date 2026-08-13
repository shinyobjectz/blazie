defmodule LazyRiver.Symbol do
  @moduledoc """
  A derived stand-in for content, sitting where a fact's value goes (`sym`):
  a vector, a hash, a sketch, a signature.

  You do not read a symbol, you compare it. A fact whose value is a literal
  asserts something; a fact whose value is a symbol represents something.
  Different in kind, same row — which is why search, traversal and query never
  became three systems here.

  Two rulings are enforced rather than documented:

    * **A symbol is always produced by a formula.** Never taken from outside,
      so `check/1` refuses one that names nothing.

    * **An attribute declares its space**, and comparing across spaces is
      refused. Two vectors from different models are not comparable, and
      comparing them anyway returns plausible nonsense — which is equivocation,
      the exact failure univocity exists to prevent.

  Search is one pass over the snapshot: exact, no index, nothing to maintain or
  invalidate. An index is a formula the engine writes for itself, and it should
  not write one until measurement says to.

      Ledger.append(ledger, Symbol.seed() ++
        Attribute.define("embedding", answers: "symbol", space: "potion_256"))
  """

  alias LazyRiver.{Attribute, Fact, Snapshot}

  @enforce_keys [:space, :values]
  defstruct [:space, :values]

  @type t :: %__MODULE__{space: String.t(), values: [float()]}
  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The attribute a symbol-valued attribute needs, defined the ordinary way."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed, do: Attribute.define("space", answers: "name")

  @doc "A symbol in a space. The space travels with it, so it can never be lost."
  @spec new(String.t(), [number()]) :: t()
  def new(space, values) when is_binary(space) and is_list(values) do
    %__MODULE__{space: space, values: Enum.map(values, &(&1 * 1.0))}
  end

  @doc "How many numbers wide."
  @spec dimension(t()) :: non_neg_integer()
  def dimension(%__MODULE__{values: values}), do: length(values)

  @doc """
  How near two symbols are, as cosine similarity in `-1.0..1.0`.

  Refused across spaces, and refused on differing width within one — a space
  whose members disagree about their dimension is not a space.
  """
  @spec near(t(), t()) :: {:ok, float()} | {:error, refusal()}
  def near(%__MODULE__{space: space} = a, %__MODULE__{space: space} = b) do
    cond do
      dimension(a) != dimension(b) ->
        {:error,
         %{
           problem: :dimension_mismatch,
           repair:
             "#{inspect(space)} holds symbols of #{dimension(a)} and #{dimension(b)} numbers. " <>
               "A space is one width: give the narrower one its own space."
         }}

      true ->
        {:ok, cosine(a.values, b.values)}
    end
  end

  def near(%__MODULE__{space: one}, %__MODULE__{space: other}) do
    {:error,
     %{
       problem: :different_spaces,
       repair:
         "#{inspect(one)} and #{inspect(other)} are different spaces, so nearness between them " <>
           "means nothing. Compare within a space, or derive one from the other with a formula."
     }}
  end

  @doc """
  The `k` nearest facts to a query symbol, nearest first.

  One pass over the snapshot — exact, so there is no recall to tune. Facts
  whose value is not a symbol, or is in another space, are skipped rather than
  refused: a search should not fail because unrelated data exists.
  """
  @spec nearest(Snapshot.t(), String.t(), t(), pos_integer()) :: [{Fact.t(), float()}]
  def nearest(%Snapshot{} = snapshot, attribute, %__MODULE__{} = query, k \\ 10) do
    snapshot
    |> Snapshot.find(attribute: attribute)
    |> Enum.flat_map(fn fact ->
      case fact.value do
        %__MODULE__{} = candidate ->
          case near(query, candidate) do
            {:ok, score} -> [{fact, score}]
            {:error, _} -> []
          end

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(k)
  end

  @doc """
  Refuse any symbol that came from outside.

  Composes with the vocabulary check — both run on the one serialized path, and
  both return their repair rather than raising.
  """
  @spec check([tuple()]) :: :ok | {:error, [refusal()]}
  def check(assertions) do
    assertions
    |> Enum.filter(&taken_from_outside?/1)
    |> case do
      [] ->
        :ok

      loose ->
        {:error,
         Enum.map(loose, fn {id, attribute, _value} ->
           %{
             problem: :symbol_from_outside,
             repair:
               "#{inspect(id)} #{inspect(attribute)} is a symbol naming no formula. A symbol " <>
                 "represents content, so something must have derived it — produce it with a " <>
                 "formula, or write the content it stands for instead."
           }
         end)}
    end
  end

  defp taken_from_outside?({_id, _attribute, %__MODULE__{}}), do: true
  defp taken_from_outside?(_), do: false

  defp cosine(a, b) do
    {dot, norm_a, norm_b} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    case norm_a * norm_b do
      product when product > 0 -> dot / :math.sqrt(product)
      # A symbol of all zeros points nowhere, so it is near nothing. Answering
      # zero beats dividing by it.
      _ -> 0.0
    end
  end
end
