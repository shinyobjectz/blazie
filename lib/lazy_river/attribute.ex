defmodule LazyRiver.Attribute do
  @moduledoc """
  What a fact says about an id (`att`).

  An attribute is itself a defined thing, with facts describing it — which is
  why schema and vocabulary need no words of their own. Defining `:height` is
  writing facts about `:height`, in the same ledger, in the same row shape.

  There is no attribute-versus-relation distinction: an answer that is a
  literal reads as an attribute, an answer that is another id reads as a
  relation, and the row is identical.

  ## Bootstrapping

  Defining an attribute means writing facts, and those facts use attributes.
  So a small set defines itself: `seed/0` returns the facts that make `:is`,
  `:answers` and `:cardinality` attributes, asserted with themselves. Every
  other attribute in the system is defined using those three.

  ## Checking

  A write that names an undefined attribute is refused, and the refusal carries
  what would fix it. The ledger applies the check; it does not know what a
  vocabulary is.

      known = Attribute.known(snapshot)
      Ledger.append(ledger, assertions, check: &Attribute.check(&1, known))
  """

  alias LazyRiver.Snapshot

  @is :is
  @answers :answers
  @cardinality :cardinality

  @root [@is, @answers, @cardinality]

  @type refusal :: %{attribute: atom(), problem: atom(), repair: String.t()}

  @doc """
  The facts that make the attributes that define attributes.

  Self-describing on purpose: `:is` is asserted to be an attribute *using*
  `:is`. Nothing outside this list may be written before it.
  """
  @spec seed() :: [{atom(), atom(), term()}]
  def seed do
    Enum.flat_map(@root, fn name ->
      [{name, @is, :attribute}, {name, @answers, :atom}, {name, @cardinality, :one}]
    end)
  end

  @doc "The attributes that define attributes. Everything else is built from these."
  @spec root() :: [atom()]
  def root, do: @root

  @doc """
  The facts that define an attribute.

      define(:height, answers: :integer)
      define(:tags, answers: :atom, cardinality: :many)
  """
  @spec define(atom(), keyword()) :: [{atom(), atom(), term()}]
  def define(name, opts \\ []) when is_atom(name) do
    answers = Keyword.get(opts, :answers, :any)
    cardinality = Keyword.get(opts, :cardinality, :one)

    [
      {name, @is, :attribute},
      {name, @answers, answers},
      {name, @cardinality, cardinality}
    ]
  end

  @doc "Every attribute defined in this snapshot."
  @spec known(Snapshot.t()) :: MapSet.t(atom())
  def known(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find(attribute: @is, answer: :attribute)
    |> MapSet.new(& &1.id)
  end

  @doc "Is this attribute defined here?"
  @spec defined?(Snapshot.t(), atom()) :: boolean()
  def defined?(%Snapshot{} = snapshot, name), do: MapSet.member?(known(snapshot), name)

  @doc """
  Check assertions against a vocabulary.

  Returns `:ok`, or every refusal with what would repair it. A boundary that
  rejects without saying how to comply produces loops, not compliance.
  """
  @spec check([tuple()], MapSet.t(atom())) :: :ok | {:error, [refusal()]}
  def check(assertions, known) do
    assertions
    |> Enum.map(&attribute_of/1)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> case do
      [] -> :ok
      undefined -> {:error, Enum.map(undefined, &refusal/1)}
    end
  end

  @doc """
  The cardinality declared for an attribute, defaulting to `:one`.

  Cardinality is a fact about the attribute rather than a feature of the
  engine — if an attribute can say it, the engine does not grow.
  """
  @spec cardinality(Snapshot.t(), atom()) :: :one | :many
  def cardinality(%Snapshot{} = snapshot, name) do
    Snapshot.answer(snapshot, name, @cardinality) || :one
  end

  @doc "The shape an attribute's answers take, defaulting to `:any`."
  @spec answers(Snapshot.t(), atom()) :: atom()
  def answers(%Snapshot{} = snapshot, name) do
    Snapshot.answer(snapshot, name, @answers) || :any
  end

  defp attribute_of({_id, attribute, _answer}), do: attribute
  defp attribute_of({_id, attribute, _answer, _by}), do: attribute

  defp refusal(name) do
    %{
      attribute: name,
      problem: :undefined,
      repair:
        "#{inspect(name)} is not an attribute here. Define it first: " <>
          "Ledger.append(ledger, Attribute.define(#{inspect(name)}, answers: :any))"
    }
  end
end
