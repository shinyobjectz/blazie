defmodule Blazie.Directive do
  @moduledoc """
  What a tool asked the runtime to do, and the record of it doing so (dir).

  A tool answers; it does not act. That rule already existed here — `Tool.run/3`
  hands back a table and never writes — and what was missing was the other half:
  somewhere for "and then this should happen" to be a thing rather than a shape
  the loop happened to recognise.

  It was recognised by pattern. `Coding` matched `"writing" => true` and
  `"running" => true` out of a tool's answer and did the work inline, which is
  Jido's directive idea with no type, no registry and no record — and it meant
  every new effect was an edit to the loop. Delegation, a scheduled call, a tool
  that lives on somebody else's MCP server: three more branches in the same
  `case`.

  ## The registry is the bound

  `known/0` is everything the runtime can be asked for. An agent's reach is that
  list, so widening it is an edit somebody makes deliberately, and a tool asking
  for something absent is refused with what is available rather than ignored.

  ## A directive is a fact, which is what Jido's is not

  Jido's directives are runtime values: the server applies them and they are
  gone. Here what was ASKED and what CAME OF IT are both written, under the run
  that caused them. So "what did this agent actually do to the world" is a query
  rather than an inference from its prose, and a directive that failed is as
  visible as one that worked.

  That is also what makes an effect refusable after the fact. A write recorded
  as a directive can be corrected by a later fact naming the directive that made
  it, which a value applied and discarded cannot.
  """

  alias Blazie.{Snapshot, World}

  @type refusal :: %{problem: atom(), repair: String.t()}
  @type doing :: %{world: World.ref(), run: term(), snapshot: Snapshot.t(), opts: keyword()}

  @doc "The attributes a directive is written with."
  @spec seed() :: [tuple()]
  def seed do
    Blazie.Attribute.define("asked_for", answers: "any", cardinality: "many") ++
      Blazie.Attribute.define("came_of_it", answers: "any", cardinality: "many")
  end

  @doc """
  What the runtime knows how to do.

  A map rather than a case, so it can be read, listed in a prompt, and added to
  without touching whatever dispatches it.
  """
  @spec known() :: %{String.t() => module()}
  def known do
    Application.get_env(:blazie, :directives, %{
      "write" => Blazie.Directive.Write,
      "run" => Blazie.Directive.Run,
      "ask" => Blazie.Directive.Ask
    })
  end

  @doc """
  Perform one, recording both halves.

  Answers what the tool should be told. A refusal is an ANSWER — it goes back to
  the model with its repair — because a directive the model never learns was
  refused is a loop that asks for it again.
  """
  @spec perform(doing(), map()) :: {:ok, map()} | {:error, refusal()}
  def perform(doing, %{"do" => name} = asked) do
    write(doing, "asked_for", asked)

    case Map.fetch(known(), name) do
      {:ok, module} ->
        answered = module.perform(doing, asked)
        write(doing, "came_of_it", outcome(name, answered))
        answered

      :error ->
        refusal = unknown(name)
        write(doing, "came_of_it", %{"do" => name, "refused" => refusal.repair})
        {:error, refusal}
    end
  end

  def perform(_doing, answered), do: {:ok, answered}

  defp outcome(name, {:ok, answered}), do: %{"do" => name, "answered" => answered}
  defp outcome(name, {:error, refusal}), do: %{"do" => name, "refused" => refusal.repair}

  defp unknown(name) do
    %{
      problem: :no_such_directive,
      repair:
        "The runtime cannot #{inspect(name)}. It can: #{known() |> Map.keys() |> Enum.sort() |> Enum.join(", ")}. " <>
          "What an agent may do is a list rather than whatever a tool reaches for, so this is " <>
          "absent rather than forbidden."
    }
  end

  # Best effort, and deliberately so: a directive that could not be written down
  # must still be performed. A gap in the record is bad; work that did not happen
  # because its diary was full is worse.
  defp write(%{world: world, run: run}, attribute, value) do
    World.append(world, [{run, attribute, value, run}])
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Every directive this run asked for, oldest first."
  @spec asked_for(Snapshot.t(), term()) :: [map()]
  def asked_for(%Snapshot{} = snapshot, run) do
    snapshot
    |> Snapshot.find(id: run, attribute: "asked_for")
    |> Enum.map(& &1.value)
  end
end

defmodule Blazie.Directive.Write do
  @moduledoc """
  Put a file in the world.

  Checked twice before it lands — the vocabulary by `Attribute.check/2`, the
  requirements by `Attribute.unmet/2` — because `World.append` runs the first
  and not the second, and an agent's output is the case that most needs both.
  """

  alias Blazie.{Attribute, Snapshot, World}

  @spec perform(Blazie.Directive.doing(), map()) :: {:ok, map()} | {:error, map()}
  def perform(%{world: world, run: run}, %{"path" => path, "content" => content}) do
    id = "file:" <> path
    writing = [{id, "path", path, run}, {id, "content", content, run}]

    case Attribute.unmet(writing, Snapshot.open([world])) do
      [] -> appending(world, writing, path)
      unmet -> refused(path, unmet)
    end
  end

  def perform(_doing, _asked),
    do: {:error, %{problem: :incomplete, repair: "Writing a file needs `path` and `content`."}}

  defp appending(world, writing, path) do
    case World.append(world, writing, check: &Attribute.check/2) do
      {:ok, tx} -> {:ok, %{"wrote" => path, "at" => tx}}
      {:error, refusals} -> refused(path, refusals)
    end
  end

  defp refused(path, why) do
    {:error,
     %{
       problem: :refused,
       repair:
         "Writing #{path} was refused: " <>
           Enum.map_join(List.wrap(why), " ", &Map.get(&1, :repair, "no reason given"))
     }}
  end
end

defmodule Blazie.Directive.Run do
  @moduledoc "Run a file from the world as python, in the sandbox."

  @spec perform(Blazie.Directive.doing(), map()) :: {:ok, map()} | {:error, map()}
  def perform(%{world: world, run: run, snapshot: snapshot}, %{"path" => path}) do
    Blazie.Coding.execute(world, run, path, snapshot)
  end

  def perform(_doing, _asked),
    do: {:error, %{problem: :incomplete, repair: "Running needs `path`."}}
end

defmodule Blazie.Directive.Ask do
  @moduledoc """
  Hand a task to another agent, and answer with what it said.

  Delegation, which every harness worth the name has and this one did not. Prime
  Intellect's spawns a whole instance; Jido's `SpawnAgent` starts a process. Here
  it is a RUN, which is the thing this tree already knows how to resume, fork,
  compact and read afterwards — so a child is not a new kind of thing, it is a
  run with a parent.

  ## Depth is bounded and the bound is the point

  A child that could delegate without limit is a fork bomb with a language model
  attached, and the bill arrives before the recursion does. `depth` is carried on
  the run and refused past `@deepest`.

  Prime Intellect bounds this by relationship — messaging limited to "parent,
  sibling, or child". Same instinct, different axis: what is dangerous here is
  not who talks to whom but how many of them a single ask can summon.
  """

  alias Blazie.{Run, Snapshot}

  @deepest 2

  @spec perform(Blazie.Directive.doing(), map()) :: {:ok, map()} | {:error, map()}
  def perform(%{world: world, run: run, opts: opts}, %{"task" => task}) do
    depth = Snapshot.open([world]) |> Snapshot.value(run, "depth") || 0

    if depth >= @deepest do
      {:error,
       %{
         problem: :too_deep,
         repair:
           "This is #{depth} deep already and #{@deepest} is the limit. Delegation that can " <>
             "delegate without end is a bill before it is a recursion — do this one yourself."
       }}
    else
      child = "#{run}/#{System.unique_integer([:positive])}"

      Blazie.World.append(world, [
        {child, "depth", depth + 1, run},
        {child, "asked_by", to_string(run), run}
      ])

      case Blazie.Coding.work(world, child, task, Keyword.put(opts, :stretches, 1)) do
        {:ok, said, _made} ->
          {:ok, %{"asked" => child, "said" => said}}

        {:error, refusal} ->
          {:error, refusal}
      end
    end
  end

  def perform(_doing, _asked),
    do: {:error, %{problem: :incomplete, repair: "Asking another agent needs a `task`."}}

  @doc "The attributes a delegated run is written with."
  @spec seed() :: [tuple()]
  def seed do
    Blazie.Attribute.define("depth", answers: "integer") ++
      Blazie.Attribute.define("asked_by", answers: "name") ++
      Run.seed()
  end
end
