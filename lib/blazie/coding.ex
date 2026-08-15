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

  alias Blazie.{Attribute, Job, Model, Run, Snapshot, Tool, World}

  @doc "The attributes a workspace is written with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("path", answers: "name") ++
      Attribute.define("content", answers: "any") ++
      Attribute.define("task", answers: "name") ++
      Attribute.define("resumed", answers: "integer", cardinality: "many")
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
    for(tool <- ~w(list read write run ask), do: {agent, "may_use", tool}) ++ tools()
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
          "Run a file from the workspace and see what it printed. Takes `path`. Write it " <>
            "as .lua — the whole workspace is there through file.read/write/list, and " <>
            "anything it writes comes back.",
        takes: %{"path" => %{"answers" => "name"}},
        source: """
        answer["do"] = "run"
        answer.path = args.path
        """
      ) ++
      Tool.declare("ask",
        describe:
          "Hand a sub-task to another agent and get back what it said. Takes `task`. " <>
            "Use it for work that is separable — not for something you could do in a step.",
        takes: %{"task" => %{"answers" => "name"}},
        source: """
        answer["do"] = "ask"
        answer.task = args.task
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
        answer["do"] = "write"
        answer.path = args.path
        answer.content = args.content
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
    {:ok, _} = Run.begin(world, run)

    # The task is a fact, not an argument that dies with this call. It is what
    # makes the run continuable by something that was not on the stack when it
    # began — which is the whole of autonomous continuation.
    {:ok, _} = World.append(world, [{run, "task", task, run}])

    carry(world, run, task, opts)
  end

  @doc """
  Continue a run from its own record, one more round of stretches.

  Everything needed is already facts: the task, the turns, the workspace. So
  continuing is not resuming a process — there is no process — it is calling
  the same loop with the same policy against a record that never went away.

  A run that never recorded a task cannot be continued, and says so.
  """
  @spec continue(World.ref(), term(), keyword()) ::
          {:ok, String.t(), [map()]} | {:error, map()}
  def continue(world, run, opts) do
    snapshot = Snapshot.open([world])

    case Snapshot.value(snapshot, run, "task") do
      nil ->
        {:error,
         %{
           problem: :no_task,
           repair:
             "Run #{inspect(run)} never recorded a task, so there is nothing to continue it " <>
               "toward. Runs begun by `work/4` record one; this one was not."
         }}

      task ->
        {:ok, _} = World.append(world, [{run, "resumed", System.system_time(:second), run}])
        carry(world, run, task, opts)
    end
  end

  @doc """
  The job that picks up what stopped.

  A run that spent its stretches is stopped rather than ended — `work/4` only
  records `ended` when the model actually answered — and everything needed to
  carry it on is facts. So continuation needs no new machinery: the runner
  already ticks, the world is already the queue, and this is a job like any
  other. Declare a cadence, register the work:

      Job.Runner.register(runner, Coding.heartbeat(world, asks: "...", provider: ...))
      World.append(world, Job.declare("heartbeat", every: 60))

  Which is the prime-agent shape without the daemon: the harness continues its
  own work, and what did the continuing is readable afterwards because every
  resume is a fact on the run it resumed.

  Bounded twice, because an unbounded resumer is a bill. A run must have
  RESTED — `rest:` seconds since it began or was last resumed, 300 unless told
  — so nothing running right now is grabbed by its own heartbeat. And a run is
  given up on after `most:` resumes (three), because a run that three
  continuations could not finish needs a person looking at it, not a fourth
  continuation. A continuation that fails writes the refusal as a `failed`
  fact on the run, which is exactly what `Refinement.triggers/2` reads — so a
  heartbeat that keeps hitting the same wall becomes a refinement trigger
  rather than a quiet loop.
  """
  @spec heartbeat(World.ref(), keyword()) :: Job.t()
  def heartbeat(world, opts) do
    Job.new("heartbeat", fn snapshot ->
      now = System.system_time(:second)

      Enum.flat_map(stalled(snapshot, now, opts), fn run ->
        case continue(world, run, opts) do
          {:ok, _said, _made} -> []
          {:error, refusal} -> [{run, "failed", Map.get(refusal, :repair, inspect(refusal))}]
        end
      end)
    end)
  end

  @doc """
  The runs a heartbeat would pick up, at `now`.

  Begun and not ended, with a task on record, nobody's delegation — a child
  whose parent already took its answer is not carried on for an audience that
  moved on — rested past `rest:`, and short of `most:` resumes.
  """
  @spec stalled(Snapshot.t(), integer(), keyword()) :: [term()]
  def stalled(%Snapshot{} = snapshot, now, opts \\ []) do
    rest = Keyword.get(opts, :rest, 300)
    most = Keyword.get(opts, :most, 3)

    for run <- Run.all(snapshot),
        Snapshot.value(snapshot, run, "ended") == nil,
        Snapshot.value(snapshot, run, "asked_by") == nil,
        Snapshot.value(snapshot, run, "task") != nil,
        length(resumes(snapshot, run)) < most,
        quiet(snapshot, run) <= now - rest,
        do: run
  end

  defp resumes(snapshot, run) do
    snapshot |> Snapshot.find(id: run, attribute: "resumed") |> Enum.map(& &1.value)
  end

  # When the run last moved, as far as its own record says: begun, or resumed.
  defp quiet(snapshot, run) do
    Enum.max([Snapshot.value(snapshot, run, "began") || 0 | resumes(snapshot, run)])
  end

  # Finish is recorded only when the model actually answered. A run that ran
  # out of stretches is stopped, not ended — which is exactly the difference
  # the heartbeat reads.
  defp carry(world, run, task, opts) do
    case stretch(world, run, task, opts, Keyword.get(opts, :stretches, 1), []) do
      {:done, said, made} ->
        {:ok, _} = Run.finish(world, run)
        {:ok, said, made}

      {:paused, made} ->
        {:ok, "out of stretches", made}

      {:error, refusal} ->
        {:error, refusal}
    end
  end

  # One stretch of work, then reassemble and go again.
  #
  # `converse/5` accumulates its messages in memory for the length of one call —
  # correct for a call, and the one thing in this stack that grows without a
  # bound. A long session is therefore several calls, and between them the
  # context is rebuilt from facts under whatever policy `keep:` names.
  #
  # Which is Mellea's position reached from the other side: the context is per
  # call and the durable thing is the record. Our own harness says it plainly —
  # a frozen spec plus a fresh context has almost nothing to persist, so a run
  # that dies mid-flight loses one call and not a conversation. Here it also
  # means a session has no length limit; what it has is an assembly that stays
  # the size the policy says however long the session runs.
  defp stretch(world, run, _task, _opts, 0, _made),
    do: {:paused, did(world, run)}

  defp stretch(world, run, task, opts, left, made) do
    model = Keyword.fetch!(opts, :asks)
    agent = Keyword.get(opts, :as, "coder")

    with :ok <- shorten(world, run, opts) do
      snapshot = Snapshot.open([world])

      answered =
        Model.converse(
          model,
          [%{"role" => "user", "content" => prompt(snapshot, agent, task)}] ++
            Run.messages(snapshot, run,
              keep: Keyword.get(opts, :keep, 6),
              # The task is what this run is about, so turns that fell out of
              # the window come back when they bear on it — recency decides
              # what is verbatim, relevance decides what is recalled.
              about: task,
              recall: Keyword.get(opts, :recall, 3)
            ),
          Tool.available(snapshot, agent),
          &running(world, run, opts, &1),
          Keyword.merge(
            [into: world, by: run, calls: Keyword.get(opts, :calls, 12)],
            Keyword.take(opts, [:provider, :timeout, :answers, :snapshot, :tries])
          )
        )

      case answered do
        # It answered without running out of calls, so it is done.
        {:ok, said, turns} ->
          {:done, said, made ++ turns}

        # It spent its calls without answering. That is not a failure of the
        # work, it is the end of a stretch — so the context is rebuilt, which
        # is where compaction happens, and it carries on with what it did
        # already visible to it as facts.
        {:error, %{problem: :too_many_calls}} ->
          stretch(world, run, task, opts, left - 1, made)

        {:error, refusal} ->
          {:error, refusal}
      end
    end
  end

  # What it did, read back from the run rather than carried.
  #
  # `converse/5` answers `{:error, :too_many_calls}` with no trace, so a stretch
  # that ended at its ceiling loses the calls it made — carried in memory. They
  # are not lost: every one was written as a `called` fact when it happened, and
  # the record is the durable account. Reading them back is both simpler and
  # the same answer a query would give afterwards.
  defp did(world, run) do
    Snapshot.open([world])
    |> Snapshot.find(id: run, attribute: "called")
    |> Enum.map(fn fact ->
      %{
        call: %{
          name: Map.get(fact.value, "tool"),
          arguments: Map.get(fact.value, "arguments", %{})
        },
        answered: Map.get(fact.value, "answered")
      }
    end)
  end

  # Fold the older turns into a summary when there are more than the policy
  # keeps. Skipped silently when there is nothing to fold, and a failure to
  # summarise does not stop the work — a long context is a cost, and stopping
  # is worse than paying it.
  defp shorten(world, run, opts) do
    snapshot = Snapshot.open([world])
    keep = Keyword.get(opts, :keep, 6)

    if Run.outstanding(snapshot, run) > keep * 2 do
      Run.compact_with(world, run, snapshot, Keyword.put(opts, :keep, keep))
    end

    :ok
  end

  # One tool call. A `write` is applied here rather than in the tool, because a
  # tool that wrote would be writing before anybody checked it — and what comes
  # back on a refusal is the reason, which the loop hands to the model as its
  # next turn.
  defp running(world, run, opts, call) do
    snapshot = Snapshot.open([world])

    # The loop no longer knows what any particular tool means. It runs the tool
    # and hands whatever came back to the runtime, which performs it if it is a
    # directive and passes it through if it is an answer.
    case Tool.run(snapshot, call) do
      {:ok, answered} ->
        Blazie.Directive.perform(
          %{world: world, run: run, snapshot: snapshot, opts: opts},
          answered
        )

      other ->
        other
    end
  end

  @doc """
  Run one of the workspace.s files, fenced.

  A `.lua` file needs no directory and no wasm: the workspace facts become the
  guest.s map (`Lua.workspace/3`), and what it wrote comes back as facts — the
  LT2 path (docs/storage-plan.md). Anything else takes the legacy python/WASI
  lane below, kept until LT3 retires wasmex: the files are written into a
  directory, the directory is preopened as the guest.s only filesystem, and
  whatever it leaves behind comes back as facts. So the agent works in python the way anybody works in python — a file,
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
    if String.ends_with?(path, ".lua") do
      execute_lua(world, run, path, snapshot)
    else
      execute_python(world, run, path, snapshot)
    end
  end

  # The Lua path (LT2, docs/storage-plan.md): no directory and no wasm — the
  # workspace facts become the guest's map (`Lua.workspace/3`), the guest
  # computes, and what changed comes back as facts with the run's provenance.
  # Same fence posture the python sandbox had: files and print, nothing that
  # reaches, frozen clock.
  defp execute_lua(world, run, path, snapshot) do
    files = Map.new(files(snapshot), fn p -> {p, to_string(read(snapshot, p) || "")} end)

    case Map.fetch(files, path) do
      :error ->
        {:ok, %{"failed" => "There is no #{path} in the workspace.", "problem" => "no_such_file"}}

      {:ok, source} ->
        case Blazie.Lua.workspace(source, files) do
          {:ok, answer} ->
            written =
              answer.files
              |> Enum.reject(fn {p, content} -> Map.get(files, p) == content end)
              |> Enum.map(&elem(&1, 0))
              |> Enum.sort()

            for p <- written do
              id = "file:" <> p
              World.append(world, [{id, "path", p, run}, {id, "content", answer.files[p], run}])
            end

            answered = %{"printed" => answer.printed}
            {:ok, if(written == [], do: answered, else: Map.put(answered, "changed", written))}

          {:error, refusal} ->
            {:ok, %{"failed" => refusal.repair, "problem" => to_string(refusal.problem)}}
        end
    end
  end

  # The python path — the WASI lane, kept until LT3 retires wasmex.
  defp execute_python(world, run, path, snapshot) do
    case python() do
      nil ->
        {:error,
         %{
           problem: :no_python,
           repair:
             "This node has no python module, so nothing can be run. Set `:python_wasm` (or " <>
               "PYTHON_WASM) to a wasi build of cpython — or write the file as .lua, which " <>
               "runs everywhere."
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
end
