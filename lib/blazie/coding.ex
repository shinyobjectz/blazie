defmodule Blazie.Coding do
  @moduledoc """
  A coding agent, declared in Lua and running against a world.

  An ordinary loop — read, edit, check, repeat — with nothing clever in the
  middle. What is different is where it lives: its files are facts, its tools
  are Lua somebody authored here, and the code it writes is a formula, which is
  the strongest sandbox in this tree by construction rather than by policy.

  ## Its tools are Lua, and that is the point

  Every tool below is a `Tool.declare` with a Lua `source`. Nothing about this
  agent is written in Elixir that could have been written in Lua — so changing
  what it can do is appending a fact, not shipping a release, and a tool added
  by somebody else runs under exactly the same fence as the ones here.

  A tool that arrives as a wasm module runs in the sandbox instead. That is the
  same `Tool.run/3`, and it is how an agent runs code nobody in this tree wrote.

  ## Nothing it writes lands unchecked

  A tool never writes to the world. `write` ANSWERS with the file it wants to
  write, and this loop appends it — after BOTH checks, and there are two:

    * `Attribute.check/2` is the vocabulary. Is this a field, does the value fit
      the shape, is it inside the closed set. `World.append` runs it.
    * `Attribute.unmet/2` is the requirements — the formulas attached to a field
      that decide whether a particular value is acceptable. `World.append` does
      NOT run it, and nothing else does either unless it asks.

  Only `Job.Generative` and `Formula.Generated` were asking, so "the answer only
  lands if the requirement holds" was true of a sampled job and of nothing else.
  A write from here goes through both, because an agent's output is exactly the
  kind that needs the second.

  Either refusal comes back as the reason, and the reason goes to the model as
  its next turn — `converse/5`'s repair path, the same one a sampled job uses.

  The ordering matters more than it looks: a tool that could write would be
  writing before anybody decided the answer was good, and an agent's answer is
  exactly the thing nobody has decided about yet.

  ## The prompt is assembled, never authored

  There is no prompt file. What the model is told is built from what is
  declared: the task, the tools' own `describe` facts, and what the workspace
  currently holds. So a tool's description cannot drift from the tool, and a
  prompt cannot describe a workspace that changed underneath it — the same rule
  as an agent's ask and a generated formula's brief.

  Which also makes the prompt refinable. `Refinement` may change a `describe`,
  and a `describe` is half this prompt, so the loop's instructions improve by
  the ordinary mechanism rather than by somebody editing a string.
  """

  alias Blazie.{Attribute, Model, Run, Snapshot, Tool, World}

  @doc "The attributes a workspace is written with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("path", answers: "name") ++
      Attribute.define("content", answers: "any")
  end

  @doc """
  The agent and its tools, as facts.

  Authored in Lua and declared like anything else, so this is a starting point
  rather than a fixed surface: appending another `Tool.declare` and another
  `may_use` gives the agent a verb, and nothing in this module has to know.

  `may_use` is how a tool becomes available to a caller, and it already existed
  — which is also the fence. An agent reaches the tools it was granted and not
  every tool declared in the world, so two agents in one world are not two
  agents with each other's hands.
  """
  @spec declare(String.t()) :: [tuple()]
  def declare(agent) do
    for(tool <- ~w(list read write run), do: {agent, "may_use", tool}) ++ tools()
  end

  @doc "The tool declarations themselves, without granting them to anybody."
  @spec tools() :: [tuple()]
  def tools do
    Tool.declare("list",
      describe: "Every file in the workspace, as paths. Takes nothing.",
      takes: %{},
      source: """
      answer.paths = {}
      for f in each { path = true } do
        table.insert(answer.paths, f.path)
      end
      """
    ) ++
      Tool.declare("read",
        describe: "The contents of one file. Takes `path`.",
        takes: %{"path" => %{"answers" => "name"}},
        source: """
        for f in each { path = args.path } do
          answer.content = f.content
          answer.path = f.path
        end
        if answer.content == nil then
          answer.missing = args.path
        end
        """
      ) ++
      Tool.declare("run",
        describe:
          "Run a python file from the workspace and see what it printed. Takes `path`. " <>
            "The whole workspace is there beside it, and anything it writes comes back.",
        takes: %{"path" => %{"answers" => "name"}},
        source: """
        answer.path = args.path
        answer.running = true
        """
      ) ++
      Tool.declare("write",
        describe:
          "Write a file. Takes `path` and `content`. This ANSWERS with what it would write; " <>
            "the write happens after it is checked, and you are told if it is refused.",
        takes: %{
          "path" => %{"answers" => "name"},
          "content" => %{"answers" => "name"}
        },
        source: """
        answer.path = args.path
        answer.content = args.content
        answer.writing = true
        """
      )
  end

  @doc """
  What the model is told, built from what is declared.

  Assembled here rather than kept in a file, so it cannot describe a tool the
  agent does not have or a workspace it is not looking at.
  """
  @spec prompt(Snapshot.t(), String.t(), String.t()) :: String.t()
  def prompt(%Snapshot{} = snapshot, agent, task) do
    """
    You are editing a workspace of files. Each file is an entity with a `path`
    and `content`.

    What is there now:
    #{listing(snapshot)}

    Your tools:
    #{Enum.map_join(Tool.available(snapshot, agent), "\n", &"  #{&1.name} — #{&1.describe}")}

    The task:
    #{task}

    Work in small steps. Read before you write. When the task is done, say what
    you changed and stop calling tools.
    """
    |> String.trim()
  end

  defp listing(snapshot) do
    case files(snapshot) do
      [] -> "  (empty)"
      paths -> Enum.map_join(paths, "\n", &"  #{&1}")
    end
  end

  @doc "Every path in the workspace."
  @spec files(Snapshot.t()) :: [String.t()]
  def files(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find(attribute: "path")
    |> Enum.map(& &1.value)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "What one file holds, at this snapshot."
  @spec read(Snapshot.t(), String.t()) :: String.t() | nil
  def read(%Snapshot{} = snapshot, path) do
    case Snapshot.find(snapshot, attribute: "path", value: path) do
      [] -> nil
      [fact | _] -> Snapshot.value(snapshot, fact.id, "content")
    end
  end

  @doc """
  Put the agent to work, and record everything it did under a run.

  Returns what it said and the trace, the same shape `converse/5` answers with —
  the run is where the durable account is, and it is a query afterwards.
  """
  @spec work(World.ref(), term(), String.t(), keyword()) ::
          {:ok, String.t(), [map()]} | {:error, map()}
  def work(world, run, task, opts) do
    model = Keyword.fetch!(opts, :asks)
    agent = Keyword.get(opts, :as, "coder")
    snapshot = Snapshot.open([world])

    {:ok, _} = Run.begin(world, run)

    Model.converse(
      model,
      prompt(snapshot, agent, task),
      Tool.available(snapshot, agent),
      &running(world, run, &1),
      Keyword.merge(
        [into: world, by: run, calls: Keyword.get(opts, :calls, 12)],
        Keyword.take(opts, [:provider, :timeout, :answers, :snapshot, :tries])
      )
    )
  end

  # One tool call. A `write` is applied here rather than in the tool, because a
  # tool that wrote would be writing before anybody checked it — and what comes
  # back on a refusal is the reason, which the loop hands to the model as its
  # next turn.
  defp running(world, run, call) do
    snapshot = Snapshot.open([world])

    case Tool.run(snapshot, call) do
      {:ok, %{"writing" => true} = answered} ->
        apply_write(world, run, answered)

      {:ok, %{"running" => true, "path" => path}} ->
        execute(world, run, path, snapshot)

      other ->
        other
    end
  end

  @doc """
  Run one of the workspace's files as python, in the sandbox.

  The world's files are written into a directory, the directory is handed to the
  guest as its only filesystem, and whatever it leaves behind comes back as
  facts. So the agent works in python the way anybody works in python — a file,
  an import, a thing it wrote next to it — and none of that reaches anything the
  caller did not hand over.

  `preopen` is what makes this ordinary rather than clever. A guest with no
  preopened directory has no filesystem at all; with one it has exactly that
  one. The fence is not a policy about paths, it is the absence of everything
  else.

  The directory is temporary and goes afterwards. The durable copy is the facts
  it was built from and the facts it produced, which is the only account that
  survives a restart.
  """
  @spec execute(World.ref(), term(), String.t(), Snapshot.t()) :: {:ok, map()} | {:error, map()}
  def execute(world, run, path, %Snapshot{} = snapshot) do
    case python() do
      nil ->
        {:error,
         %{
           problem: :no_python,
           repair:
             "This node has no python module, so nothing can be run. Set `:python_wasm` (or " <>
               "PYTHON_WASM) to a wasi build of cpython."
         }}

      bytes ->
        in_a_directory(snapshot, fn dir ->
          answered = away(bytes, dir, path)
          {:ok, Map.merge(answered, changed(world, run, snapshot, dir))}
        end)
    end
  end

  defp python do
    case Application.get_env(:blazie, :python_wasm) || System.get_env("PYTHON_WASM") do
      nil -> nil
      where -> if File.exists?(where), do: File.read!(where), else: nil
    end
  end

  # The workspace, on a disk, for exactly as long as the call takes.
  defp in_a_directory(snapshot, doing) do
    dir = Path.join(System.tmp_dir!(), "blazie-work-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for path <- files(snapshot) do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, to_string(read(snapshot, path) || ""))
    end

    try do
      doing.(dir)
    after
      File.rm_rf(dir)
    end
  end

  defp away(bytes, dir, path) do
    opts = [
      fuel: Application.get_env(:blazie, :python_fuel, 20_000_000_000),
      memory_bytes: Application.get_env(:blazie, :python_memory, 512 * 1024 * 1024),
      args: ["python", Path.join("/work", path)],
      preopen: [%Wasmex.Wasi.PreopenOptions{path: dir, alias: "/work"}]
    ]

    case Blazie.Sandbox.run_wasi(bytes, "", opts) do
      {:ok, said, spent} -> %{"printed" => said, "fuel" => spent.fuel}
      {:error, refusal} -> %{"failed" => refusal.repair, "problem" => to_string(refusal.problem)}
    end
  end

  # Whatever the guest left behind, back as facts. A run that wrote a file and
  # told nobody would be a run whose work vanished with the directory.
  defp changed(world, run, snapshot, dir) do
    before = MapSet.new(files(snapshot))

    written =
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.reject(fn path ->
        MapSet.member?(before, path) and read(snapshot, path) == File.read!(Path.join(dir, path))
      end)

    for path <- written do
      id = "file:" <> path
      content = File.read!(Path.join(dir, path))
      World.append(world, [{id, "path", path, run}, {id, "content", content, run}])
    end

    if written == [], do: %{}, else: %{"changed" => written}
  end

  defp apply_write(world, run, %{"path" => path, "content" => content}) do
    id = "file:" <> path
    writing = [{id, "path", path, run}, {id, "content", content, run}]

    # Requirements first and explicitly. `World.append`'s `check:` is the
    # vocabulary check and does not run them; a caller that wants them asks, and
    # an agent's output is the case that most needs asking.
    case Attribute.unmet(writing, Snapshot.open([world])) do
      [] -> appending(world, writing, path)
      unmet -> refused(path, unmet)
    end
  end

  defp apply_write(_world, _run, answered), do: {:ok, answered}

  defp appending(world, writing, path) do
    case World.append(world, writing, check: &Attribute.check/2) do
      {:ok, tx} -> {:ok, %{"wrote" => path, "at" => tx}}
      {:error, refusals} -> refused(path, refusals)
    end
  end

  defp refused(path, why) do
    # Handed back as an answer rather than raised, so the model reads it and
    # fixes it. A refusal the model never sees is a loop that repeats.
    {:error,
     %{
       problem: :refused,
       repair:
         "Writing #{path} was refused: " <>
           Enum.map_join(List.wrap(why), " ", &Map.get(&1, :repair, "no reason given"))
     }}
  end
end
