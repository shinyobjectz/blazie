defmodule LazyRiver.Fact do
  @moduledoc """
  The row, and the only row shape (`fac`).

  An id, an attribute said about it, the answer, and the transaction that
  recorded it. Optionally, the formula or job that produced it.

  An id is a slot, not a word: it is opaque, carrying no type, no name and no
  contents, and everything known about it is other facts pointing at it.

  An edge is a fact whose answer is another id, so a property graph is what
  facts already are — there is no node type and no edge type here because
  there is nothing left to add.
  """

  @enforce_keys [:id, :attribute, :answer, :tx]
  defstruct [:id, :attribute, :answer, :tx, by: nil]

  @type t :: %__MODULE__{
          id: term(),
          attribute: atom(),
          answer: term(),
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
end
