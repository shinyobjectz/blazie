defmodule Blazie.SpikeHintsTest do
  @moduledoc """
  The Hints spike: one socialite subsystem, living on blazie (bla-c3c2).

  Nexus Hints is the contract under test — "webhooks may only make a sweep run
  SOONER; polling is the backbone, so unplugging every webhook loses latency
  and nothing else" — plus the sweep rules around it: redelivery collides
  harmlessly, and the cursor advances only after the processing lands.

  What the spike is for is finding out how much of that has to be BUILT versus
  how much falls out of the substrate. The headline answer: the sooner-on-hint
  contract is not implemented anywhere in this file. The sweep is a job with a
  cadence; the job READS the hints; and blazie's observed dependency graph —
  a job is due when something it read has changed — is exactly "the webhook
  makes it run sooner". Nexus built that with Oban triggers and a hints table;
  here it is a property of declaring the work honestly.

  Everything an org does goes through the Elixir SDK over a real wire, because
  the spike is also the SDK's proving ground. The verdict lives in
  docs/spike-hints.md.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Job, Snapshot, World}
  alias Blazie.Job.Runner

  # The sweep, authored in Lua, declared as facts. It probes with `each`
  # rather than reading fields directly because a field nobody has written is
  # not yet vocabulary — a first-run read of `h.swept` would be refused, where
  # an `each` over the same field is simply empty. (Verdict item.)
  @sweep """
  local swept = {}
  for s in each { swept = true } do swept[tostring(s)] = true end

  local seen = 0
  for h in each { delivery = true } do
    if not swept[tostring(h)] then
      h.swept = true
      seen = seen + 1
    end
  end

  if seen > 0 then
    local total = 0
    for c in each { swept_total = true } do total = c.swept_total end
    cursor.swept_total = total + seen
  end

  return seen
  """

  setup do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: Blazie.Surface.Endpoint, port: 0, ip: {127, 0, 0, 1}},
          id: :hints_wire
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    org = "hints-org-#{System.unique_integer([:positive])}"
    token = "hints-token-#{System.unique_integer([:positive])}"
    client = BlazieClient.new("http://127.0.0.1:#{port}", token)

    # The org claims its own world — tenancy is which world, decided once.
    {:ok, %{"world" => ^org}} = BlazieClient.claim(client, org)

    # The operator side: base vocabulary and the sweep declared as facts. Done
    # with a local append because the SDK has no assertion-level verb — a
    # multi-line Lua source as a fact VALUE does not survive being quoted
    # inside a Lua chunk. Verdict item, not an accident.
    world = World.via(org)
    {:ok, _} = World.append(world, Attribute.seed() ++ Job.seed())

    {:ok, _} =
      World.append(world, [
        {"sweep", "is", "job"},
        {"sweep", "every", 3600},
        {"sweep", "source", @sweep}
      ])

    %{client: client, org: org, world: world}
  end

  # A webhook delivery, ingested through the SDK. Idempotent by probing for
  # the delivery id before staging anything — in an append-only world,
  # "insert if absent" is a read in the same chunk as the write, and the two
  # land atomically or not at all.
  defp ingest(client, org, delivery) do
    source = """
    local seen = false
    for h in each { delivery = "#{delivery}" } do seen = true end
    if not seen then
      hint_#{delivery}.delivery = "#{delivery}"
      hint_#{delivery}.platform = "bluesky"
    end
    return seen
    """

    {:ok, answer} = BlazieClient.run(client, source, world: org)
    answer
  end

  defp runner(world) do
    start_supervised!(
      {Runner,
       world: world,
       jobs: Job.declared(Snapshot.open([world])),
       name: :"hints_runner_#{System.unique_integer([:positive])}"}
    )
  end

  defp settle(runner) do
    Enum.reduce_while(1..400, nil, fn _, _ ->
      if Runner.in_flight(runner) == [], do: {:halt, :ok}, else: {:cont, Process.sleep(5)}
    end)
  end

  defp swept_total(world) do
    Snapshot.value(Snapshot.open([world]), "cursor", "swept_total")
  end

  test "redelivery collides harmlessly", %{client: client, org: org} do
    first = ingest(client, org, "D1")
    assert first["wrote"] > 0

    # The same delivery again: the probe finds it, nothing is staged, and the
    # answer says so. No dedup table, no unique index — a read in the chunk.
    again = ingest(client, org, "D1")
    assert again["wrote"] == 0
    assert again["value"] == true
  end

  test "the sweep processes, and the cursor lands WITH the results", %{
    client: client,
    org: org,
    world: world
  } do
    ingest(client, org, "D1")
    ingest(client, org, "D2")

    runner = runner(world)
    assert {:ok, ["sweep"]} = Runner.tick(runner, 1_000_000)
    settle(runner)

    assert swept_total(world) == 2

    # Cursor-after-write, strengthened: the swept marks, the cursor, and the
    # job's own bookkeeping share ONE transaction, because a job's staged
    # writes land atomically. Nexus enforces this ordering by discipline;
    # here it cannot be otherwise.
    snapshot = Snapshot.open([world])
    txs = for fact <- Snapshot.find(snapshot, attribute: "swept"), do: fact.tx
    [cursor_fact] = Snapshot.find(snapshot, id: "cursor", attribute: "swept_total")

    assert Enum.uniq(txs) == [cursor_fact.tx]
  end

  test "a hint makes the sweep run sooner, and polling is the backbone", %{
    client: client,
    org: org,
    world: world
  } do
    ingest(client, org, "D1")

    runner = runner(world)

    # The backbone: never ran, so the cadence makes it due.
    assert {:ok, ["sweep"]} = Runner.tick(runner, 1_000_000)
    settle(runner)
    assert swept_total(world) == 1

    # Well inside the cadence and nothing new: not due. Unplugging every
    # webhook would leave exactly this — the poll, later.
    assert {:ok, []} = Runner.tick(runner, 1_000_010)

    # A hint lands. The sweep READ the hints, so the write falls inside its
    # recorded read set, and the job is due NOW — 3590 seconds early. This is
    # the whole Hints contract, and nothing in this file implements it.
    ingest(client, org, "D2")
    assert {:ok, ["sweep"]} = Runner.tick(runner, 1_000_020)
    settle(runner)
    assert swept_total(world) == 2

    # And its own writes do not wake it: still quiet after the sweep.
    assert {:ok, []} = Runner.tick(runner, 1_000_030)
  end

  test "two orgs are two worlds, with nothing to filter", %{
    client: client,
    org: org,
    world: world
  } do
    ingest(client, org, "D1")

    other_org = "hints-org-#{System.unique_integer([:positive])}"
    other = %{client | token: "hints-token-#{System.unique_integer([:positive])}"}
    {:ok, _} = BlazieClient.claim(other, other_org)

    {:ok, %{"value" => count}} =
      BlazieClient.run(
        other,
        "local n = 0\nfor h in each { delivery = true } do n = n + 1 end\nreturn n",
        world: other_org
      )

    # Zero, and not because a filter ran: the other org's world has never
    # heard of these hints. There is no cross-world query to forget to scope.
    assert count == 0
    assert length(Snapshot.find(Snapshot.open([world]), attribute: "delivery")) == 1
  end
end
