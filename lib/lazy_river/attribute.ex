defmodule LazyRiver.Attribute do
  @moduledoc """
  What a fact says about an id (`att`).

  An attribute is itself a defined thing, with facts describing it — which is
  why schema and vocabulary need no words of their own. Defining `:height` is
  writing facts about `:height`, in the same ledger, in the same row shape.

  There is no attribute-versus-relation distinction: a value that is a
  literal reads as an attribute, a value that is another id reads as a
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

  @is "is"
  @answers "answers"
  @cardinality "cardinality"

  @root [@is, @answers, @cardinality]

  @type refusal :: %{attribute: String.t(), problem: atom(), repair: String.t()}

  @doc """
  The facts that make the attributes that define attributes.

  Self-describing on purpose: `:is` is asserted to be an attribute *using*
  `:is`. Nothing outside this list may be written before it.
  """
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Enum.flat_map(@root, fn name ->
      [{name, @is, "attribute"}, {name, @answers, "name"}, {name, @cardinality, "one"}]
    end)
  end

  @doc "The attributes that define attributes. Everything else is built from these."
  @spec root() :: [String.t()]
  def root, do: @root

  @doc """
  The facts that define an attribute.

      define(:height, answers: :integer)
      define(:tags, answers: :atom, cardinality: :many)
  """
  @spec define(String.t(), keyword()) :: [{String.t(), String.t(), term()}]
  def define(name, opts \\ []) when is_binary(name) do
    # Whatever you say about an attribute becomes a fact about it. This module
    # knows nothing about `:space` or anything else a later word wants to
    # declare — it only knows that describing a thing means writing facts.
    described = Keyword.merge([answers: "any", cardinality: "one"], opts)

    [
      {name, @is, "attribute"}
      | Enum.map(described, fn {key, value} -> {name, Atom.to_string(key), to_string(value)} end)
    ]
  end

  @doc "Every attribute defined in this snapshot."
  @spec known(Snapshot.t()) :: MapSet.t(String.t())
  def known(%Snapshot{} = snapshot) do
    # The root is always known. It defines itself, so a ledger that has never
    # been written to still has to accept the writes that seed it — otherwise
    # nothing could ever be defined anywhere.
    snapshot
    |> Snapshot.find(attribute: @is, value: "attribute")
    |> MapSet.new(& &1.id)
    |> MapSet.union(MapSet.new(@root))
  end

  @doc "Is this attribute defined here?"
  @spec defined?(Snapshot.t(), String.t()) :: boolean()
  def defined?(%Snapshot{} = snapshot, name), do: MapSet.member?(known(snapshot), name)

  @doc """
  Check assertions against a vocabulary.

  Returns `:ok`, or every refusal with what would repair it. A boundary that
  rejects without saying how to comply produces loops, not compliance.
  """
  @spec check([tuple()], MapSet.t(String.t())) :: :ok | {:error, [refusal()]}
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
  @spec cardinality(Snapshot.t(), String.t()) :: String.t()
  def cardinality(%Snapshot{} = snapshot, name) do
    Snapshot.value(snapshot, name, @cardinality) || "one"
  end

  @doc "The shape an attribute's answers take, defaulting to `:any`."
  @spec answers(Snapshot.t(), String.t()) :: String.t()
  def answers(%Snapshot{} = snapshot, name) do
    Snapshot.value(snapshot, name, @answers) || "any"
  end

  defp attribute_of({_id, attribute, _answer}), do: attribute
  defp attribute_of({_id, attribute, _answer, _by}), do: attribute

  defp refusal(name) do
    %{
      attribute: name,
      problem: :undefined,
      repair:
        "#{inspect(name)} is not an attribute here. Define it first: " <>
          "Ledger.append(ledger, Attribute.define(#{inspect(name)}))"
    }
  end
end
