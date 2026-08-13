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
  A fact as it came off disk, in whatever shape it was written in.

  **An append-only store must read every shape it has ever written, forever.**
  Nothing is ever rewritten here, so a fact recorded under an older row shape
  is still on disk and still has to answer. There is no migration that could
  fix it, because a migration is a rewrite and a rewrite is the one thing this
  database does not do.

  This was found by a deployment rather than a test, and could not have been
  found by one: renaming the third slot from `answer` to `value` made every
  ledger already on the box unreadable, because `term_to_binary` stores a
  struct's keys and `binary_to_term` gives them straight back. Every test wrote
  its facts with the same code that read them, so every test passed.

  Shape is sniffed rather than versioned, because the records that need reading
  were written before there was a version to write. Records from here on carry
  their shape in their keys just the same, so the next rename adds a clause.
  """
  @spec from_stored(term()) :: term()
  def from_stored(%{__struct__: __MODULE__, answer: value} = older) do
    %__MODULE__{
      id: older.id,
      attribute: older.attribute,
      value: value,
      tx: older.tx,
      by: Map.get(older, :by)
    }
  end

  def from_stored(fact), do: fact

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
    # `Map.get` with a sentinel rather than `Map.fetch!`. This runs inside the
    # ledger, so raising here kills the ledger — and with a memory store that
    # loses every fact in it. A read must never be able to destroy what a
    # writer put there. A pattern naming a field that does not exist simply
    # matches nothing; it is refused where a pattern arrives, by `fields/1`,
    # which runs in the caller.
    Enum.all?(pattern, fn {key, want} -> Map.get(fact, key, :__no_such_field__) == want end)
  end

  @doc "The fields a pattern may name."
  @spec fields() :: [atom()]
  def fields, do: [:id, :attribute, :value, :tx, :by]

  @doc """
  Check a pattern names only fields a fact has, and say so if not.

  Called before a read crosses into the ledger, so a typo raises in the process
  that made it rather than in the one holding everybody's facts. `subject` is
  the example worth naming: it is a real attribute, and it is not a field.
  """
  @spec fields!(keyword()) :: :ok
  def fields!(pattern) do
    case Enum.reject(Keyword.keys(pattern), &(&1 in fields())) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "A pattern names the fields of a fact — #{Enum.join(fields(), ", ")}. " <>
                "#{Enum.map_join(unknown, ", ", &inspect/1)} " <>
                "#{if length(unknown) == 1, do: "is not one", else: "are not"}. " <>
                "To match on what an attribute says, name the attribute and the value: " <>
                "`[attribute: \"subject\", value: ...]`."
    end
  end
end
