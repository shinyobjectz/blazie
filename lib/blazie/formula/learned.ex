defmodule Blazie.Formula.Learned do
  @moduledoc """
  A brief written from what a run actually did, rather than by hand.

  `Formula.Generated` already turns a declaration into a verified program: given
  `produces`, `given` and a set of `example` facts, it asks a model for a body,
  runs the candidate against every example in a scratch world, and refuses to
  write the source unless all of them pass and every `requires` holds. That is
  the hard half and it was already built.

  Its examples were hand-written. This is where they come from instead.

  ## A repeated tool call is a function nobody has written down

  An agent that calls `plan_of(customer)` forty times and gets the same answer
  for the same customer is doing arithmetic over the network. Each call is an
  input and an output — which is exactly the shape of an example — so the run's
  own history is a specification for a formula that would make the call
  unnecessary.

  That is the narrow, honest reading of "an agent learns a skill": not that it
  gets better at reasoning, but that something it kept doing by asking is now
  something it can compute, and the evidence that the computation is right is
  the forty times it already happened.

  ## Why this is safe, and where the safety comes from

  Nothing here decides anything. It writes `example` facts, and `Generated`
  decides — which means a learned formula clears the same fence as a
  hand-written one: it runs in a world with no clock, no network and no io, it
  must reproduce every example, and it must satisfy every requirement on what it
  produces. A harvest that proposed a body would be a second, weaker path to
  adoption; a harvest that proposes only evidence cannot be.

  ## Disagreement is a refusal, not a vote

  Two calls with the same arguments and different answers mean the thing is not
  a function — it depends on the clock, on somebody else's state, or on
  something not in the arguments. Learning it as a formula would bake one of the
  two answers in forever. So a contradiction stops the harvest with its reason,
  rather than picking a winner by count.

  ## Staleness comes free

  `Generated.wanted/1` already lists formulas whose newest example is later than
  their source. So a call that contradicts what was learned is a new example,
  and the formula it invalidates is on the work list the moment that fact lands.
  Nothing has to notice; the read set already did.
  """

  alias Blazie.{Snapshot, Tool}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc """
  Every call a run made to one tool, as `{arguments, answer}`.

  Read from the `called` facts `converse/5` writes, so this is what the agent
  did rather than what it was asked to do.
  """
  @spec calls(Snapshot.t(), term(), String.t()) :: [{map(), term()}]
  def calls(%Snapshot{} = snapshot, run, tool) do
    snapshot
    |> Snapshot.find(id: run, attribute: "called")
    |> Enum.map(& &1.value)
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "tool") == tool))
    |> Enum.map(&{Map.get(&1, "arguments", %{}), Map.get(&1, "answered")})
  end

  @doc """
  A brief for a formula that would do what the tool was doing.

  Answers the facts `Generated` needs — the declaration and one `example` per
  distinct call — or a refusal saying why this tool is not a function.

      harvest(snapshot, "run-1", "plan_of", produces: "plan", given: ["customer"])

  `enough:` is how many distinct examples are required before it is worth
  learning anything. One call is a coincidence; the default of three is a
  judgement, not a discovery, and it is a keyword so a caller who knows better
  can say so.
  """
  @spec harvest(Snapshot.t(), term(), String.t(), keyword()) ::
          {:ok, [tuple()]} | {:error, refusal()}
  def harvest(%Snapshot{} = snapshot, run, tool, opts) do
    produces = Keyword.fetch!(opts, :produces)
    given = Keyword.fetch!(opts, :given)
    enough = Keyword.get(opts, :enough, 3)
    id = Keyword.get(opts, :as, tool)

    with {:ok, seen} <- agreed(calls(snapshot, run, tool)),
         :ok <- plenty(seen, enough, tool) do
      {:ok,
       Blazie.Formula.Generated.declare(id,
         produces: produces,
         given: given,
         examples:
           Enum.map(seen, fn {arguments, answer} ->
             %{"given" => arguments, "expect" => answer}
           end)
       )}
    end
  end

  # One answer per set of arguments, or a refusal naming the disagreement.
  defp agreed(calls) do
    calls
    |> Enum.group_by(fn {arguments, _answer} -> arguments end, fn {_a, answer} -> answer end)
    |> Enum.reduce_while({:ok, []}, fn {arguments, answers}, {:ok, kept} ->
      case Enum.uniq(answers) do
        [one] ->
          {:cont, {:ok, kept ++ [{arguments, one}]}}

        many ->
          {:halt,
           {:error,
            %{
              problem: :not_a_function,
              repair:
                "Called with #{inspect(arguments)} and answered #{inspect(many)} — more than one " <>
                  "answer for the same arguments, so this depends on something that is not in " <>
                  "them. A formula would bake one of those in forever. Add what it actually " <>
                  "depends on to the arguments, or leave it as a tool."
            }}}
      end
    end)
  end

  defp plenty(seen, enough, tool) when length(seen) < enough do
    {:error,
     %{
       problem: :too_few,
       repair:
         "#{inspect(tool)} was called with #{length(seen)} distinct argument(s) and #{enough} are " <>
           "wanted before learning anything from it. One call is a coincidence; wait until it has " <>
           "happened enough to be a pattern, or lower `enough:` if you are sure."
     }}
  end

  defp plenty(_seen, _enough, _tool), do: :ok

  @doc """
  What this run called often enough to be worth looking at, with how often.

  A starting point for "what could this agent stop asking for", answered from
  the trajectory rather than from anybody's intuition about it.
  """
  @spec repeated(Snapshot.t(), term()) :: [{String.t(), non_neg_integer()}]
  def repeated(%Snapshot{} = snapshot, run) do
    snapshot
    |> Snapshot.find(id: run, attribute: "called")
    |> Enum.map(& &1.value)
    |> Enum.filter(&is_map/1)
    |> Enum.frequencies_by(&Map.get(&1, "tool"))
    |> Enum.sort_by(fn {_tool, times} -> -times end)
  end

  @doc false
  @spec seed() :: [tuple()]
  def seed, do: Tool.seed()
end
