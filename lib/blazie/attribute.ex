defmodule Blazie.Attribute do
  @moduledoc """
  What a fact says about an id (`att`).

  An attribute is itself a defined thing, with facts describing it — which is
  why schema and vocabulary need no words of their own. Defining `:height` is
  writing facts about `:height`, in the same world, in the same row shape.

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
  what would fix it. The world applies the check; it does not know what a
  vocabulary is.

      known = Attribute.known(snapshot)
      World.append(world, assertions, check: &Attribute.check(&1, known))

  Hand it the snapshot rather than the names taken from one, and the same
  check also asks what a redeclaration would do to the facts already written:

      World.append(world, assertions, check: &Attribute.check(&1, snapshot))

  ## Redeclaring

  A declaration is facts, so changing one is a later fact and the earlier one
  still answers at the snapshot it was written into. What the later fact may
  not do is change an answer that has already been given.

  Widening what an attribute answers is free: a value that satisfied the
  narrower shape satisfies the wider one, so nothing answers differently.
  Narrowing is refused while any current answer fails the new shape, and the
  repair is the additive one — write a later fact for each id whose answer does
  not fit, then narrow again. That is widen, backfill, narrow, with corrections
  where another database would rewrite rows.

  Cardinality has no such dance. Under `one` only the latest fact answers;
  under `many` every distinct value does. So flipping it on an attribute whose
  ids have been corrected either resurrects superseded answers or silences live
  ones, and there is nothing to backfill because the history *is* the data. It
  is refused in both directions, and the repair is a second attribute. Where no
  id has been corrected the two readings agree, so both directions are free.

  The limit, said out loud: this checks a declaration against the facts, never
  the facts against the declaration. An ordinary write is not shape-checked
  here, so a narrowing that passes today can be contradicted by tomorrow's
  fact. `satisfies?/2` is the predicate that check would be built from.
  """

  alias Blazie.{Fact, Snapshot}

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

  @doc """
  The attributes a requirement is written with.

  `requires` points an attribute at a formula; `source` is the lua that formula
  runs. Neither is a word — both are data, sitting beside `answers` and
  `cardinality` on the same shelf.
  """
  @spec requires_seed() :: [{String.t(), String.t(), term()}]
  def requires_seed do
    define("requires", answers: "name", cardinality: "many") ++
      define("source", answers: "any")
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
  def known(source) do
    # The root is always known. It defines itself, so a world that has never
    # been written to still has to accept the writes that seed it — otherwise
    # nothing could ever be defined anywhere.
    source
    |> facts_of()
    |> find_in(attribute: @is, value: "attribute")
    |> MapSet.new(& &1.id)
    |> MapSet.union(MapSet.new(@root))
  end

  @doc "Is this attribute defined here?"
  @spec defined?(Snapshot.t(), String.t()) :: boolean()
  def defined?(source, name), do: MapSet.member?(known(source), name)

  @doc """
  Check assertions against a vocabulary, or against a whole snapshot.

  Given the names a snapshot knows, this asks only whether every attribute
  named is one of them. Given the snapshot itself, it also asks what any
  redeclaration in the write would do to the facts already there — the
  vocabulary check first, because a redeclaration of an attribute nobody has
  defined is a spelling mistake and should be named as one.

  Returns `:ok`, or every refusal with what would repair it. A boundary that
  rejects without saying how to comply produces loops, not compliance.
  """
  @spec check([tuple()], Snapshot.t() | MapSet.t(String.t())) :: :ok | {:error, [refusal()]}
  def check(assertions, %Snapshot{} = snapshot),
    do: check(assertions, Snapshot.facts(snapshot))

  def check(assertions, facts) when is_list(facts) do
    # Given facts rather than a snapshot, this is what the world runs inside
    # itself, against the state the write is about to land on. Given a snapshot
    # it is the same check one transaction earlier — correct for a caller that
    # wants to know before it asks, and not a substitute for the one the world
    # runs, because only that one is serialised with the append.
    with :ok <- check(assertions, known(facts)) do
      assertions
      |> redeclarations(facts)
      |> Enum.flat_map(&contradicted(facts, &1))
      |> case do
        [] -> :ok
        refusals -> {:error, refusals}
      end
    end
  end

  def check(assertions, known) do
    # A transaction is atomic, so a batch that defines a field and uses it is
    # coherent: at the moment anything can read this, both are there. Checking
    # only against what was already written refused exactly that batch, which
    # made "define it first" a separate round trip nobody could avoid — and
    # made a surface where fields declare themselves impossible to build.
    known = MapSet.union(known, declared_in(assertions))

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
  What an attribute requires of its values, beyond its shape.

  A requirement is a **formula** — Lua, pure, no clock and no network — attached
  to an attribute by an ordinary fact:

      {"height", "requires", "positive"}
      {"positive", "is", "formula"}
      {"positive", "source", "return value > 0"}

  No new vocabulary. `answers:` says what shape a value has and this says what
  must be true of it, which is the same question asked one level deeper.

  The chunk is handed `value`, and answers `true`, `false`, or a string — where
  a string is the reason, because a requirement that can say WHY it refused is
  worth more than one that can only say no. That is the same rule as every other
  boundary here: reject with the repair attached.
  """
  @spec requirements(Snapshot.t(), String.t()) :: [String.t()]
  def requirements(%Snapshot{} = snapshot, attribute) do
    snapshot
    |> Snapshot.find(id: attribute, attribute: "requires")
    |> Enum.map(& &1.value)
    |> Enum.uniq()
  end

  @doc """
  Which requirements these assertions fail, and why.

  Returns `[]` when everything holds. Checked BEFORE anything is written, which
  is what lets a generative job sample again rather than write something wrong
  and correct it afterwards — a correction is cheap here, but a wrong answer
  that was never checked is not a correction, it is a lie with a timestamp.
  """
  @spec unmet([tuple()], Snapshot.t()) :: [map()]
  def unmet(assertions, %Snapshot{} = snapshot) do
    for assertion <- assertions,
        {id, attribute, value} <- [three(assertion)],
        requirement <- requirements(snapshot, attribute),
        result = judge(requirement, value, snapshot),
        result != :ok,
        do: %{
          id: id,
          attribute: attribute,
          requirement: requirement,
          problem: :unmet,
          repair: reason(result, requirement, attribute)
        }
  end

  defp three({id, attribute, value}), do: {id, attribute, value}
  defp three({id, attribute, value, _by}), do: {id, attribute, value}

  # The chunk is a formula, so it runs in the formula world: a frozen clock, no
  # network, and a deadline. A requirement that could reach outside would make
  # "does this hold" depend on when you asked.
  defp judge(requirement, value, snapshot) do
    case Snapshot.value(snapshot, requirement, "source") do
      nil ->
        {:missing, requirement}

      source when is_binary(source) ->
        case Blazie.Lua.Binding.run(bind(value) <> source, snapshot, as: :formula) do
          {:ok, true, _wrote} -> :ok
          {:ok, false, _wrote} -> :refused
          {:ok, nil, _wrote} -> :refused
          {:ok, why, _wrote} when is_binary(why) -> {:because, why}
          {:ok, _other, _wrote} -> :ok
          {:error, refusal} -> {:broken, refusal}
        end

      _other ->
        {:missing, requirement}
    end
  end

  # Set as a real global, so `_G`'s metatable never sees the name and it stays a
  # value rather than becoming an empty entity.
  defp bind(value), do: "value = " <> literal(value) <> "\n"

  defp literal(value) when is_number(value), do: to_string(value)
  defp literal(value) when is_boolean(value), do: to_string(value)
  defp literal(nil), do: "nil"

  defp literal(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
    "'" <> escaped <> "'"
  end

  # Anything else — a symbol, a blob, a table — is handed over as nil rather
  # than as a broken literal. A requirement that wants one of those wants a
  # formula over the world, not a predicate over a scalar.
  defp literal(_value), do: "nil"

  defp reason(:refused, requirement, attribute),
    do: "#{inspect(attribute)} requires #{inspect(requirement)}, and this value does not satisfy it."

  defp reason({:because, why}, requirement, _attribute), do: "#{inspect(requirement)}: #{why}"

  defp reason({:missing, requirement}, _r, attribute),
    do:
      "#{inspect(attribute)} requires #{inspect(requirement)}, which has no `source`. " <>
        "Write the lua it should run, or drop the requirement."

  defp reason({:broken, refusal}, requirement, _attribute),
    do: "#{inspect(requirement)} did not run: #{Map.get(refusal, :repair, inspect(refusal))}"

  defp declared_in(assertions) do
    for {id, @is, "attribute"} <- assertions, into: MapSet.new(), do: id
  end

  @doc """
  Does this value satisfy a declared shape?

  Four shapes have a predicate here. Anything else is a name the engine has no
  way to evaluate, and a value cannot contradict a shape nobody can decide — so
  it satisfies. That is worth stating rather than hiding: `answers: "email"`
  records what a caller meant and constrains nothing.
  """
  @spec satisfies?(term(), String.t()) :: boolean()
  def satisfies?(_value, "any"), do: true
  def satisfies?(value, "integer"), do: is_integer(value)
  def satisfies?(value, "name"), do: is_binary(value) and value != ""
  def satisfies?(value, "symbol"), do: is_struct(value, Blazie.Symbol)
  def satisfies?(_value, _shape), do: true

  @doc """
  The cardinality declared for an attribute, defaulting to `:one`.

  Cardinality is a fact about the attribute rather than a feature of the
  engine — if an attribute can say it, the engine does not grow.
  """
  @spec cardinality(Snapshot.t(), String.t()) :: String.t()
  def cardinality(source, name) do
    value_in(facts_of(source), name, @cardinality) || "one"
  end

  @doc "The shape an attribute's answers take, defaulting to `:any`."
  @spec answers(Snapshot.t(), String.t()) :: String.t()
  def answers(source, name) do
    value_in(facts_of(source), name, @answers) || "any"
  end

  # ── reading a snapshot, or the facts themselves ────────────────────────────
  #
  # Everything above works on a list. A snapshot is materialised once on the way
  # in, so the same check runs in the caller — which holds a snapshot — or
  # inside the world, which holds its own facts and cannot ask itself for them
  # without calling into the process it is already inside.

  defp facts_of(%Snapshot{} = snapshot), do: Snapshot.facts(snapshot)
  defp facts_of(facts) when is_list(facts), do: facts

  defp find_in(facts, pattern), do: Enum.filter(facts, &Fact.matches?(&1, pattern))

  defp value_in(facts, id, attribute) do
    facts
    |> find_in(id: id, attribute: attribute)
    |> List.last()
    |> case do
      nil -> nil
      fact -> fact.value
    end
  end

  # ── redeclaring ────────────────────────────────────────────────────────────
  #
  # A redeclaration is a fact that says something different about an attribute
  # from what this snapshot already says about it. Saying the same thing again
  # is not one, which is why re-running a seed costs nothing and why the
  # defaults `define/2` always restates are only ever checked when they differ.

  defp redeclarations(assertions, snapshot) do
    assertions
    |> Enum.flat_map(&declaration_in/1)
    |> Enum.uniq()
    |> Enum.reject(fn {name, key, declared} -> declared(snapshot, key, name) == declared end)
  end

  defp declaration_in({name, key, declared}), do: declaration_in(name, key, declared)
  defp declaration_in({name, key, declared, _by}), do: declaration_in(name, key, declared)

  defp declaration_in(name, key, declared)
       when key in [@answers, @cardinality] and is_binary(declared),
       do: [{name, key, declared}]

  defp declaration_in(_name, _key, _declared), do: []

  defp declared(snapshot, @answers, name), do: answers(snapshot, name)
  defp declared(snapshot, @cardinality, name), do: cardinality(snapshot, name)

  # What an attribute answers can be narrowed as soon as every live answer fits
  # the narrower shape — and a later fact is how this database changes a live
  # answer at all, so the backfill other systems do by rewriting is done here
  # by writing.
  defp contradicted(snapshot, {name, @answers, shape}) do
    snapshot
    |> answered_now(name)
    |> Enum.reject(fn {_id, value} -> satisfies?(value, shape) end)
    |> case do
      [] -> []
      refused -> [narrower_than_the_facts(name, shape, answers(snapshot, name), refused)]
    end
  end

  # Cardinality is not a shape. It says which of an id's facts count as answers,
  # so changing it changes answers rather than constraining them — and the ids
  # it changes nothing for are exactly the ones nobody has corrected.
  defp contradicted(snapshot, {name, @cardinality, declared}) do
    case corrected(snapshot, name) do
      [] -> []
      ids -> [reread_of_the_facts(name, cardinality(snapshot, name), declared, ids)]
    end
  end

  # Which values answer now, read the way the attribute is declared today: under
  # `one` a later fact supersedes an earlier one, under `many` it joins it.
  defp answered_now(snapshot, name) do
    reading = cardinality(snapshot, name)

    snapshot
    |> by_id(name)
    |> Enum.flat_map(fn {id, values} -> Enum.map(live(values, reading), &{id, &1}) end)
  end

  defp live(values, "many"), do: Enum.uniq(values)
  defp live(values, _one), do: [List.last(values)]

  # The ids the two readings disagree about, which is the whole of what a
  # cardinality change would move.
  defp corrected(snapshot, name) do
    snapshot
    |> by_id(name)
    |> Enum.filter(fn {_id, values} -> length(Enum.uniq(values)) > 1 end)
    |> Enum.map(fn {id, _values} -> id end)
  end

  defp by_id(source, name) do
    source
    |> facts_of()
    |> find_in(attribute: name)
    |> Enum.group_by(& &1.id, & &1.value)
  end

  defp narrower_than_the_facts(name, shape, was, refused) do
    %{
      attribute: name,
      problem: :contradicted,
      repair:
        "#{inspect(name)} is answered by #{count(refused, "value")} that #{inspect(shape)} " <>
          "refuses, across ids #{listing(Enum.map(refused, &elem(&1, 0)))}. Nothing here is " <>
          "rewritten, so narrow in three steps: leave it answering #{inspect(was)}, write a " <>
          "later fact for each of those ids whose answer fits, then declare #{inspect(shape)} " <>
          "again. Find them with Snapshot.find(snapshot, attribute: #{inspect(name)})."
    }
  end

  defp reread_of_the_facts(name, was, declared, ids) do
    %{
      attribute: name,
      problem: :would_change_answers,
      repair:
        "#{inspect(name)} answers #{inspect(was)}, and #{count(ids, "id")} already hold more " <>
          "than one value for it: #{listing(ids)}. Reading it as #{inspect(declared)} would " <>
          "#{effect(declared)}, and a correction cannot be un-written, so there is nothing to " <>
          "backfill. Define a second attribute with cardinality #{inspect(declared)} and write " <>
          "there what each id should hold. Find them with " <>
          "Snapshot.find(snapshot, attribute: #{inspect(name)})."
    }
  end

  defp effect("many"), do: "make every superseded correction answer again"
  defp effect(_one), do: "silence every answer but the latest"

  defp count(things, noun) do
    case length(things) do
      1 -> "1 #{noun}"
      many -> "#{many} #{noun}s"
    end
  end

  # Enough ids to go and look at, never all of them — a refusal that pastes ten
  # thousand is a wall, and the question that finds the rest is in the repair.
  defp listing(ids) do
    case ids |> Enum.uniq() |> Enum.split(3) do
      {shown, []} -> Enum.map_join(shown, ", ", &inspect/1)
      {shown, rest} -> Enum.map_join(shown, ", ", &inspect/1) <> " and #{length(rest)} more"
    end
  end

  defp attribute_of({_id, attribute, _answer}), do: attribute
  defp attribute_of({_id, attribute, _answer, _by}), do: attribute

  defp refusal(name) do
    %{
      attribute: name,
      problem: :undefined,
      repair:
        "#{inspect(name)} is not a field here, and nothing in this write declares it. " <>
          "Assigning it declares it — `something.#{name} = <a value>` in a chunk — so " <>
          "reaching this means the declaration was dropped on the way in."
    }
  end
end
