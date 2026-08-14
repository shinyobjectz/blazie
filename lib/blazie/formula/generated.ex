defmodule Blazie.Formula.Generated do
  @moduledoc """
  A formula whose source a model wrote, verified before anything uses it.

  This is the one place in the tree where a model writes code that later runs,
  and the reason it is allowed is narrow: what it writes is a **formula**. No
  clock, no network, a deadline, and the guest world is built out of what the
  host binds — which for a formula is nothing that reaches. So the blast radius
  of a bad generation is a wrong answer, never a reached socket. If that ever
  stops being true this module stops being safe, which is why the adversarial
  test sits beside it rather than being left implied.

  ## Intent, as facts

      {"adults", "is", "formula"}
      {"adults", "produces", "adult"}
      {"adults", "given", "age"}
      {"adults", "example", %{"given" => %{"age" => 41}, "expect" => true}}
      {"adults", "example", %{"given" => %{"age" => 9},  "expect" => false}}

  No source. The declaration says what must come out, what may go in, and what
  the answer is for cases somebody already knows — which is the whole brief a
  model needs, and the whole brief a verifier needs. One description, two
  readers, so they cannot disagree.

  ## Nothing is adopted unverified

  A candidate runs against every example in a scratch world before its source is
  written. All must pass and all `requires` on the produced attribute must hold,
  or the source is not written at all — the candidate is recorded as a failure
  with why, because a rejected program is evidence rather than noise.

  That ordering is the difference between generation and a promise. An unchecked
  program in the world would run on real data before anybody found out it was
  wrong, and a correction after that is not a correction — it is an apology.

  ## Which version answered

  The source fact names the job that wrote it, so `at(42)` says which version of
  the program produced which answer. A generated formula that was wrong in March
  and right in April has both, and the answers from March are still explicable
  by the source that made them.
  """

  alias Blazie.{Attribute, Formula, Snapshot, World}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The attributes an intent is declared with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("produces", answers: "name") ++
      Attribute.define("given", answers: "name", cardinality: "many") ++
      Attribute.define("example", answers: "any", cardinality: "many") ++
      Attribute.define("rejected", answers: "any", cardinality: "many")
  end

  @doc """
  Declare intent without a body.

      declare("adults", produces: "adult", given: ["age"],
        examples: [%{"given" => %{"age" => 41}, "expect" => true}])
  """
  @spec declare(String.t(), keyword()) :: [tuple()]
  def declare(id, opts) do
    [{id, "is", "formula"}, {id, "produces", Keyword.fetch!(opts, :produces)}] ++
      for(field <- Keyword.get(opts, :given, []), do: {id, "given", field}) ++
      for(example <- Keyword.get(opts, :examples, []), do: {id, "example", example})
  end

  @doc """
  Formulas that want a body — the work list.

  Two ways to want one: never had a source, or an example changed after the
  source was written. The second is what makes a generated program MAINTAINED
  rather than generated once — correct an example and the program that no longer
  satisfies it is stale, exactly as a derived value is stale when its input
  moves.

  Decided by transaction rather than by re-verifying: the tx of the newest
  example against the tx of the source. Verification runs the candidate against
  every case in a world of its own, which is the right cost to pay before
  ADOPTING one and the wrong cost to pay on every tick to discover there is
  nothing to do.
  """
  @spec wanted(Snapshot.t()) :: [String.t()]
  def wanted(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find(attribute: "produces")
    |> Enum.map(&to_string(&1.id))
    |> Enum.uniq()
    |> Enum.filter(&wants_body?(snapshot, &1))
    |> Enum.sort()
  end

  defp wants_body?(snapshot, id) do
    case latest_tx(snapshot, id, "source") do
      nil -> true
      wrote_at -> (latest_tx(snapshot, id, "example") || 0) > wrote_at
    end
  end

  defp latest_tx(snapshot, id, attribute) do
    snapshot
    |> Snapshot.find(id: id, attribute: attribute)
    |> Enum.map(& &1.tx)
    |> Enum.max(fn -> nil end)
  end

  @doc """
  Everything a model needs to write the body, and a verifier needs to check it.

  Assembled from the declaration, never authored — same rule as an agent's ask.
  """
  @spec brief(Snapshot.t(), String.t()) :: String.t()
  def brief(%Snapshot{} = snapshot, id) do
    produces = Snapshot.value(snapshot, id, "produces")
    given = values(snapshot, id, "given")

    """
    Write the body of a blazie formula called #{id}.

    It sets `#{produces}` on every entity that has #{Enum.join(given, " and ")}.

    The language is Lua 5.x — Lua's `for ... in ... do ... end`, never any
    other language's block syntax. An entity is a table: `ada.age` reads a
    field and `ada.#{produces} = x` writes one. Iteration looks exactly like
    this:

        for e in each { age = true } do
          e.adult = e.age >= 18
        end

    There is no clock, no network and no io — a formula that reaches for one
    will not run. (The first live authoring attempt answered Ruby-shaped
    blocks because this brief showed `each` without the loop around it; a
    brief that under-specifies the idiom measures the model's guess, not its
    ability.)

    Answer with the body only. No markdown fence, no explanation.

    It must satisfy every one of these:

    #{examples(snapshot, id) |> Enum.map_join("\n", &describe_example(&1, produces, given))}
    """
    |> String.trim()
  end

  @doc """
  Check a candidate against every example, in a world of its own.

  Returns `:ok`, or every example it failed and how. Run before the source is
  written and never after — a candidate that is checked once it is already the
  formula has been checked too late.
  """
  @spec verify(Snapshot.t(), String.t(), String.t()) :: :ok | {:error, [map()]}
  def verify(%Snapshot{} = snapshot, id, candidate) do
    produces = Snapshot.value(snapshot, id, "produces")
    formula = Formula.of_source(id, candidate)

    snapshot
    |> examples(id)
    |> Enum.flat_map(&check_example(&1, formula, produces, snapshot))
    |> case do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  # Each example gets its own scratch world, so one cannot leave facts behind
  # that make the next one pass. A verifier whose cases can see each other is a
  # verifier that reports on the order they ran in.
  defp check_example(example, formula, produces, declared) do
    given = Map.get(example, "given", %{})
    expect = Map.get(example, "expect")
    name = "verify-#{System.unique_integer([:positive])}"

    {:ok, world} = World.open(name)

    try do
      {:ok, _} = World.append(world, Attribute.seed())

      seeded =
        for {field, value} <- given do
          Attribute.define(field, answers: answers_for(value)) ++ [{"subject", field, value}]
        end
        |> List.flatten()

      {:ok, _} =
        World.append(world, seeded ++ Attribute.define(produces, answers: answers_for(expect)))

      case run_candidate(formula, Snapshot.open([world])) do
        {:error, why} ->
          [%{example: example, problem: :did_not_run, repair: why}]

        {:ok, assertions} ->
          answered =
            Enum.find_value(assertions, fn
              {"subject", ^produces, value} -> {:answered, value}
              {"subject", ^produces, value, _by} -> {:answered, value}
              _ -> nil
            end)

          case answered do
            {:answered, ^expect} ->
              unmet(assertions, declared, example)

            {:answered, other} ->
              [
                %{
                  example: example,
                  problem: :wrong_answer,
                  repair:
                    "given #{inspect(given)} it answered #{inspect(other)}, not #{inspect(expect)}"
                }
              ]

            nil ->
              [
                %{
                  example: example,
                  problem: :answered_nothing,
                  repair: "given #{inspect(given)} it set no #{inspect(produces)} at all"
                }
              ]
          end
      end
    after
      World.close(name)
    end
  end

  # An example passing is not enough: whatever the produced attribute REQUIRES
  # must hold too, or a formula could satisfy three cases and still write
  # something the world refuses.
  defp unmet(assertions, declared, example) do
    three =
      Enum.map(assertions, fn
        {id, field, value} -> {id, field, value}
        {id, field, value, _by} -> {id, field, value}
      end)

    case Attribute.unmet(three, declared) do
      [] -> []
      failures -> Enum.map(failures, &%{example: example, problem: :unmet, repair: &1.repair})
    end
  end

  defp run_candidate(formula, snapshot) do
    {assertions, _read} = Formula.run(formula, snapshot)
    {:ok, assertions}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  @doc "The facts adopting a verified candidate, or recording a rejected one."
  @spec adopt(String.t(), String.t(), term()) :: [tuple()]
  def adopt(id, candidate, by), do: [{id, "source", candidate, by}]

  @doc false
  @spec reject(String.t(), String.t(), [map()], term()) :: [tuple()]
  def reject(id, candidate, failures, by) do
    [{id, "rejected", %{"source" => candidate, "why" => Enum.map(failures, & &1.repair)}, by}]
  end

  @doc """
  A job that writes the bodies of every formula declared without one.

  Generation is a job and verification is a formula, and the order is the whole
  safety property: ask, check in a world of its own, and only then write. A
  candidate that fails is recorded as a rejection with why, so the next attempt
  has something to learn from and a person has something to read.
  """
  @spec author(Snapshot.t(), keyword()) :: (Snapshot.t(), pos_integer() -> [tuple()])
  def author(%Snapshot{} = declared, opts \\ []) do
    model = Keyword.get(opts, :asks) || Snapshot.value(declared, "author", "asks")
    by = Keyword.get(opts, :by, "author")

    fn snapshot, attempt ->
      Enum.flat_map(wanted(snapshot), fn id ->
        brief = brief(snapshot, id)

        # Told which attempt this is, so a retry can say what went wrong last
        # time rather than asking the same question and hoping.
        prompt =
          case last_rejection(snapshot, id) do
            nil -> brief
            why -> brief <> "\n\nA previous attempt failed: " <> why
          end

        case Blazie.Model.generate(model, prompt, opts) do
          {:error, refusal} ->
            raise refusal.repair

          {:ok, candidate} ->
            candidate = strip_fence(candidate)

            case verify(snapshot, id, candidate) do
              :ok -> adopt(id, candidate, by)
              {:error, failures} when attempt > 1 -> reject(id, candidate, failures, by)
              {:error, failures} -> reject(id, candidate, failures, by)
            end
        end
      end)
    end
  end

  defp last_rejection(snapshot, id) do
    snapshot
    |> Snapshot.find(id: id, attribute: "rejected")
    |> List.last()
    |> case do
      %{value: %{"why" => why}} when is_list(why) -> Enum.join(why, "; ")
      _ -> nil
    end
  end

  # Models fence code even when told not to. Stripping it here rather than
  # asking harder: a verifier that refused a correct formula for its packaging
  # would be rejecting the right answer for the wrong reason.
  defp strip_fence(said) do
    said
    |> String.trim()
    |> String.replace(~r/\A```[a-zA-Z]*\n/, "")
    |> String.replace(~r/\n```\z/, "")
    |> String.trim()
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp examples(snapshot, id) do
    snapshot
    |> Snapshot.find(id: id, attribute: "example")
    |> Enum.map(& &1.value)
    |> Enum.filter(&is_map/1)
  end

  defp values(snapshot, id, attribute) do
    snapshot |> Snapshot.find(id: id, attribute: attribute) |> Enum.map(& &1.value) |> Enum.uniq()
  end

  defp describe_example(example, produces, _given) do
    "  given #{inspect(Map.get(example, "given"))} then #{produces} is #{inspect(Map.get(example, "expect"))}"
  end

  defp answers_for(value) when is_integer(value), do: "integer"
  defp answers_for(value) when is_number(value), do: "number"
  defp answers_for(value) when is_boolean(value), do: "boolean"
  defp answers_for(value) when is_binary(value), do: "name"
  defp answers_for(_value), do: "any"
end
