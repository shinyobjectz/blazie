defmodule LazyRiver.Fact do
  @moduledoc """
  The row, and the only row shape (`fac`).

  An id, an attribute said about it, the value, and the transaction that
  recorded it. Optionally, the formula or job that produced it.

  An attribute is a binary, not an atom. Doctrine 10 has tenants and agents
  adding attributes while the system runs, and atoms are never collected — a
  name that arrives in a request must never become one.

  An id is a slot, not a word: it is opaque, carrying no type, no name and no
  contents, and everything known about it is other facts pointing at it.

  An edge is a fact whose value is another id, so a property graph is what
  facts already are — there is no node type and no edge type here because
  there is nothing left to add.
  """

  @enforce_keys [:id, :attribute, :value, :tx]
  defstruct [:id, :attribute, :value, :tx, by: nil]

  @type t :: %__MODULE__{
          id: term(),
          attribute: String.t(),
          value: term(),
          tx: pos_integer(),
          by: term() | nil
        }

  @doc """
  Did this fact reach the outside world?

  A fact naming no formula and no job came from outside and cannot be
  reproduced. Everything else is a function of a snapshot and can be recomputed
  at any time, which is why storing it is a performance choice.
  """
  @spec from_outside?(t()) :: boolean()
  def from_outside?(%__MODULE__{by: nil}), do: true
  def from_outside?(%__MODULE__{}), do: false

  @doc """
  Does this fact match a pattern? An absent key is a wildcard.

  The same predicate answers two questions, which is why it lives here rather
  than beside either caller: which facts a snapshot returns, and whether a fact
  that has since landed falls inside what a formula read.
  """
  @spec matches?(t(), keyword()) :: boolean()
  def matches?(%__MODULE__{} = fact, pattern) do
    Enum.all?(pattern, fn {key, want} -> Map.fetch!(fact, key) == want end)
  end
end
