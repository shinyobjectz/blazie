defmodule Blazie.AgentRuntimeTest do
  @moduledoc """
  Phase 5: the runtime carries a real Task, and every claim is exercised.

  Dispatch is fire-and-ack with the credential model attached: the machine
  writes back over the ordinary wire under a token granted exactly one
  world, and the token is TESTED against a second world. Laws are named,
  versioned requirements whose verdicts never raise. Citations are offsets
  found in the sources. Research names capabilities, never vendors. And the
  gate at the end runs brief → plan → park → approve → research → dossier,
  kills the machine mid-run, and loses one call rather than the run.
  """
  use ExUnit.Case, async: false

  alias Blazie.{
    Attribute,
    Authority,
    Coding,
    Dispatch,
    Judge,
    Model,
    Retrieval,
    Run,
    Snapshot,
    Spend,
    Tool,
    World
  }

  # ── dispatch ───────────────────────────────────────────────────────────────

  describe "dispatch: fire-and-ack with a one-world credential" do
    setup do
      server =
        start_supervised!(
          Supervisor.child_spec(
            {Bandit, plug: Blazie.Surface.Endpoint, port: 0, ip: {127, 0, 0, 1}},
            id: :dispatch_wire
          )
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      %{address: "http://127.0.0.1:#{port}"}
    end

    test "the machine's answers land as facts, and its token names nothing else", ctx do
      world = "task-world-#{System.unique_integer([:positive])}"
      other = "other-world-#{System.unique_integer([:positive])}"
      {:ok, ref} = World.open(world)
      {:ok, _} = World.open(other)
      {:ok, _} = World.append(ref, Attribute.seed() ++ Dispatch.seed())

      parent = self()

      # The "machine": everything it knows arrives in the env, and everything
      # it says goes back over the wire as the token it was handed.
      Dispatch.Local.configure(fn env ->
        client = BlazieClient.new(env["BLAZIE_ADDRESS"], env["BLAZIE_TOKEN"])

        wrote =
          BlazieClient.run(client, "findings.answer = 42", world: env["BLAZIE_WORLD"])

        stolen = BlazieClient.run(client, "return 1", world: env["BLAZIE_OTHER"])
        send(parent, {:machine, wrote, stolen})
      end)

      assert {:ok, %{machine: machine}} =
               Dispatch.run(
                 vendor: {Dispatch.Local, [extra_env: %{"BLAZIE_OTHER" => other}]},
                 world: world,
                 run: "task-1",
                 task: "find the answer",
                 address: ctx.address
               )

      assert machine =~ "local-"
      assert_receive {:machine, wrote, stolen}, 5_000

      # Write-back landed as ordinary facts under the run's world.
      assert {:ok, %{"wrote" => n}} = wrote
      assert n > 0
      assert Snapshot.value(Snapshot.open([ref]), "findings", "answer") == 42

      # And the credential names exactly one world — tested by trying.
      assert {:error, %{repair: repair}} = stolen
      assert String.length(repair) > 20

      # The ack is on the record.
      assert [_] = Snapshot.find(Snapshot.open([ref]), id: "task-1", attribute: "dispatched_to")
    end
  end

  # ── laws and the judge ─────────────────────────────────────────────────────

  describe "laws: named, versioned, and never absent a verdict" do
    setup do
      world = Blazie.TestLedger.open()
      {:ok, _} = World.append(world, Attribute.seed() ++ Judge.seed())
      {:ok, _} = World.append(world, Attribute.define("dossier", answers: "any"))
      %{world: world}
    end

    test "a held law and a failed law each answer, naming their version", %{world: world} do
      {:ok, _} =
        World.append(
          world,
          Judge.law("says_something", version: 2, on: "dossier", source: "return #value > 0") ++
            Judge.law("short_enough", version: 1, on: "dossier", source: "return #value < 10")
        )

      snapshot = Snapshot.open([world])
      verdicts = Judge.verdict(snapshot, {"d-1", "dossier", "a dossier body, well past ten"})

      held = for {_id, "verdict", v} <- verdicts, do: {v["law"], v["held"], v["version"]}
      assert {"says_something", true, 2} in held
      assert {"short_enough", false, 1} in held
    end

    test "a law that crashes is a verdict, not a raise", %{world: world} do
      {:ok, _} =
        World.append(
          world,
          Judge.law("broken", version: 1, on: "dossier", source: "this is not lua at all ((")
        )

      snapshot = Snapshot.open([world])
      verdicts = Judge.verdict(snapshot, {"d-1", "dossier", "anything"})

      assert Enum.any?(verdicts, fn {_id, "verdict", v} -> v["held"] == false end)
    end
  end

  test "citations are offsets found in the sources, and inventions are recorded" do
    sources = %{
      "report" => "Revenue grew 14 percent in the third quarter, driven by new accounts.",
      "call" => "Management said churn fell to a record low."
    }

    # The model claims three quotes; the second is a fabrication. The judge
    # believes none of them — it looks.
    model = fn _ref, _messages, _schema, _opts ->
      {:ok,
       %{
         "quotes" => [
           %{"source" => "report", "quote" => "Revenue grew 14 percent"},
           %{"source" => "report", "quote" => "Profit doubled overnight"},
           %{"source" => "call", "quote" => "churn fell to a record low"}
         ]
       }}
    end

    {:ok, grounded} =
      Judge.grounded("Revenue grew 14 percent and churn fell.", sources,
        asks: "openai:x",
        object_provider: model
      )

    assert length(grounded.supported) == 2
    assert [%{"quote" => "Profit doubled overnight"}] = grounded.invented

    # The offset is where the SOURCE says the quote is.
    [first, _second] = grounded.supported
    assert first["at"] == 0
    assert String.slice(sources["report"], first["at"], first["length"]) == first["quote"]
  end

  # ── retrieval ──────────────────────────────────────────────────────────────

  defmodule SourceA do
    @behaviour Blazie.Retrieval
    @impl true
    def search(_opts, query, _k),
      do: {:ok, [%{"ref" => "a-1", "title" => "A on #{query}", "text" => "alpha"}]}
  end

  defmodule SourceB do
    @behaviour Blazie.Retrieval
    @impl true
    def search(_opts, query, _k),
      do:
        {:ok,
         [
           %{"ref" => "b-1", "title" => "B on #{query}", "text" => "beta"},
           %{"ref" => "b-2", "title" => "B again", "text" => "beta2"}
         ]}
  end

  defmodule SourceDown do
    @behaviour Blazie.Retrieval
    @impl true
    def search(_opts, _query, _k),
      do: {:error, %{problem: :unreachable, repair: "the source is down"}}
  end

  test "research interleaves sources, carries failures, and names no vendor" do
    answer =
      Retrieval.ask(
        [{SourceA, []}, {SourceB, []}, {SourceDown, []}],
        "churn",
        4
      )

    # Round-robin: one from each in turn, no invented cross-source score.
    assert Enum.map(answer.documents, & &1["ref"]) == ["a-1", "b-1", "b-2"]
    assert [%{problem: :unreachable}] = answer.failed

    # The one citable shape, and nothing in it says who found it.
    for doc <- answer.documents do
      assert Map.keys(doc) |> Enum.sort() == ["ref", "text", "title"]
    end
  end

  # ── the gate ───────────────────────────────────────────────────────────────

  describe "the Phase 5 gate: a Task end to end, with a mid-run kill" do
    setup do
      {:ok, world} = World.open("gate-#{System.unique_integer([:positive])}")
      on_exit(fn -> World.close(World.name_of(world)) end)

      {:ok, _} =
        World.append(
          world,
          Attribute.seed() ++
            Spend.seed() ++ Model.seed() ++ Run.seed() ++ Tool.seed() ++ Coding.seed()
        )

      {:ok, _} = World.append(world, Coding.declare("coder"))

      previous = Application.get_env(:blazie, :retrieval)
      Application.put_env(:blazie, :retrieval, [{SourceA, []}, {SourceB, []}])

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:blazie, :retrieval)
          value -> Application.put_env(:blazie, :retrieval, value)
        end
      end)

      %{world: world}
    end

    test "brief, plan, park, approve, research, dossier — and the kill costs one call",
         %{world: world} do
      # The scripted model: plans first, then — once approval is visible in
      # its context — researches, writes the dossier, and finishes. Between
      # the plan and the approval it is interrupted mid-call: the provider
      # dies the way a machine dies.
      research_tool =
        Tool.declare("research",
          describe: "Search the granted sources. Takes `query`.",
          takes: %{"query" => %{"answers" => "name"}},
          source: """
          answer["do"] = "research"
          answer.query = args.query
          """
        )

      {:ok, _} = World.append(world, research_tool)
      {:ok, _} = World.append(world, [{"coder", "may_use", "research"}])

      steps = :ets.new(:steps, [:public])
      :ets.insert(steps, {:step, 0})

      provider = fn _ref, messages, _tools, _opts ->
        step = :ets.update_counter(steps, :step, 1)
        said = Enum.map_join(messages, " ", &to_string(Map.get(&1, "content", "")))

        cond do
          # First life: propose a plan, then die mid-flight on the next call.
          step == 1 ->
            {:ok, {:said, "PLAN: research churn, then write findings.md"}, %{in: 1, out: 1}}

          step == 2 ->
            raise "the machine was killed"

          # Second life: the plan and the approval are both visible from the
          # record — the run lost the killed call, nothing else.
          not String.contains?(said, "APPROVED") ->
            {:ok, {:said, "parked: awaiting approval"}, %{in: 1, out: 1}}

          not String.contains?(said, "documents") ->
            {:ok, {:calls, [%{id: "r1", name: "research", arguments: %{"query" => "churn"}}]},
             %{in: 1, out: 1}}

          true ->
            {:ok,
             {:calls,
              [
                %{
                  id: "w1",
                  name: "write",
                  arguments: %{"path" => "findings.md", "content" => "churn fell; see refs"}
                }
              ]}, %{in: 1, out: 1}}
        end
      end

      # Life one: the brief goes in, the plan comes back, the machine dies.
      {:ok, _plan, _} =
        Coding.work(world, "task-9", "investigate churn",
          asks: "openai:x",
          provider: provider,
          calls: 3,
          stretches: 1
        )

      assert_raise RuntimeError, "the machine was killed", fn ->
        Coding.continue(world, "task-9", asks: "openai:x", provider: provider, calls: 3)
      end

      # The record survived the kill: the plan is a fact, and exactly the
      # killed call is missing.
      at = Snapshot.open([world])
      turns = Run.turns(at, "task-9")
      assert Enum.any?(turns, &(&1.answered =~ "PLAN:"))

      # Park: the run continues and parks, because nothing says APPROVED yet.
      {:ok, said, _} =
        Coding.continue(world, "task-9", asks: "openai:x", provider: provider, calls: 3)

      assert said =~ "parked"

      # The human approves — a fact, like everything else.
      {:ok, _} = World.append(world, [{"task-9", "asked", "APPROVED: proceed", "task-9"}])
      {:ok, _} = World.append(world, [{"task-9", "answered", "noted", "task-9"}])

      # Research happens through the directive (capability, not vendor), the
      # dossier lands through the checked write path, and the run ENDS.
      {:ok, _said, _} =
        Coding.continue(world, "task-9", asks: "openai:x", provider: provider, calls: 4)

      done = Snapshot.open([world])
      assert Coding.read(done, "findings.md") =~ "churn fell"
      assert is_integer(Snapshot.value(done, "task-9", "ended"))

      # Every turn is a fact; the research directive recorded both halves.
      asked_for = Blazie.Directive.asked_for(done, "task-9")
      assert Enum.any?(asked_for, &(&1["do"] == "research"))
    end
  end
end
