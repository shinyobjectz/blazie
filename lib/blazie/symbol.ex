defmodule Blazie.Symbol do
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

      World.append(world, Symbol.seed() ++
        Attribute.define("embedding", answers: "symbol", space: "potion_256"))
  """

  alias Blazie.{Attribute, Fact, Snapshot}

  @enforce_keys [:space, :values]
  defstruct [:space, :values, :norm]

  # `values` is a binary of little-endian float64s, not a list of floats, and
  # the difference is not cosmetic.
  #
  # A list of 768 floats costs 24,576 bytes resident — a cons cell and a boxed
  # float per element — against 6,144 as a binary. Worse, a list is COPIED when
  # it is sent to another process, so fanning the scan out across cores made it
  # slower rather than faster: measured at 50k vectors, 1,003ms serial against
  # 5,123ms across ten cores. Binaries over 64 bytes are refcounted and shared,
  # which is what makes parallelism available at all.
  #
  # `norm` is precomputed, because the old `cosine/2` recomputed the QUERY's
  # norm once per candidate — O(N·d) of pure waste on every search.
  @type t :: %__MODULE__{space: String.t(), values: binary(), norm: float()}
  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The attribute a symbol-valued attribute needs, defined the ordinary way."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed, do: Attribute.define("space", answers: "name")

  @doc "A symbol in a space. The space travels with it, so it can never be lost."
  @spec new(String.t(), [number()]) :: t()
  def new(space, values) when is_binary(space) and is_list(values) do
    packed = for value <- values, into: <<>>, do: <<value * 1.0::float-64-little>>
    %__MODULE__{space: space, values: packed, norm: norm_of(packed)}
  end

  def new(space, values) when is_binary(space) and is_binary(values) do
    %__MODULE__{space: space, values: values, norm: norm_of(values)}
  end

  @doc """
  Normalise a symbol that was stored under an older shape.

  `values` used to be a list of floats and there was no `norm`. Anything read
  back from a world may still be that, because nothing here is ever rewritten —
  so every path that compares symbols goes through this first. Renaming a stored
  shape without a shim is how this tree has lost data three times.
  """
  @spec from_stored(t() | map()) :: t()
  def from_stored(%__MODULE__{values: values, norm: norm} = symbol)
      when is_binary(values) and is_float(norm),
      do: symbol

  def from_stored(%__MODULE__{values: values, space: space}) when is_list(values),
    do: new(space, values)

  def from_stored(%__MODULE__{values: values, space: space}) when is_binary(values),
    do: new(space, values)

  def from_stored(other), do: other

  @doc "The numbers, as a list. What the wire carries — json has no binaries."
  @spec numbers(t()) :: [float()]
  def numbers(%__MODULE__{} = symbol) do
    for <<value::float-64-little <- from_stored(symbol).values>>, do: value
  end

  defp norm_of(packed) do
    packed |> sum_squares(0.0) |> :math.sqrt()
  end

  defp sum_squares(<<value::float-64-little, rest::binary>>, acc),
    do: sum_squares(rest, acc + value * value)

  defp sum_squares(<<>>, acc), do: acc

  @doc "How many numbers wide."
  @spec dimension(t()) :: non_neg_integer()
  def dimension(%__MODULE__{values: values}) when is_binary(values), do: div(byte_size(values), 8)
  def dimension(%__MODULE__{values: values}) when is_list(values), do: length(values)

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
        {:ok, cosine(from_stored(a), from_stored(b))}
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

  # Both norms are already known, so this walks the two binaries once and does
  # nothing else. The old version zipped the two lists — allocating an
  # N-element list of tuples per comparison — and recomputed both norms every
  # time, including the query's, which is identical across the whole search.
  defp cosine(%__MODULE__{} = a, %__MODULE__{} = b) do
    case a.norm * b.norm do
      product when product > 0 -> dot(a.values, b.values, 0.0) / product
      # A symbol of all zeros points nowhere, so it is near nothing. Answering
      # zero beats dividing by it.
      _ -> 0.0
    end
  end

  defp dot(<<x::float-64-little, a::binary>>, <<y::float-64-little, b::binary>>, acc),
    do: dot(a, b, acc + x * y)

  defp dot(_a, _b, acc), do: acc
end
