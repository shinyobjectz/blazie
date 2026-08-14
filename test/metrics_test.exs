defmodule Blazie.MetricsTest do
  @moduledoc """
  The facts projected outward, and the alarm on the number whose silence
  matters most.

  The projection renders only what the worlds actually say — an absent
  reading is absent, never zero — and the alarm is a transition, ringing
  once when proven_at goes stale and clearing once when the drill proves
  again, with the whole history readable in between.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Job, Metrics, Snapshot, TestLedger, World}

  test "the exposition renders what is open and nothing it cannot see" do
    # The node worlds may or may not be open in this run; what must hold is
    # shape — every line is `name value` or `name{labels} value` — and that
    # rendering never raises with worlds missing.
    text = Metrics.render()
    assert is_binary(text)

    for line <- String.split(text, "\n", trim: true) do
      assert line =~ ~r/^blazie_[a-z_]+(\{[^}]*\})? [\d.]+$/,
             "not exposition-shaped: #{line}"
    end
  end

  test "the metrics route answers text over the wire" do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: Blazie.Surface.Endpoint, port: 0, ip: {127, 0, 0, 1}},
          id: :metrics_wire
        )
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    {:ok, {{_http, 200, _}, headers, _body}} =
      :httpc.request(
        :get,
        {~c"http://127.0.0.1:#{port}/metrics", [{~c"authorization", ~c"Bearer metrics-token"}]},
        [],
        body_format: :binary
      )

    content = List.keyfind(headers, ~c"content-type", 0)
    assert content != nil and to_string(elem(content, 1)) =~ "text/plain"
  end

  describe "the backup alarm is a transition" do
    setup do
      world = TestLedger.open()
      {:ok, _} = World.append(world, Attribute.seed() ++ Job.seed() ++ Metrics.seed())
      %{world: world}
    end

    defp last_alarm(world) do
      Snapshot.open([world])
      |> Snapshot.find(id: "alarms", attribute: "alarm")
      |> List.last()
      |> case do
        nil -> nil
        fact -> fact.value
      end
    end

    test "never-proven rings once, then clears when the drill proves", %{world: world} do
      proven = :ets.new(:proven, [:public])
      :ets.insert(proven, {:at, nil})

      job =
        Metrics.alarm_job(
          proven_at: fn -> :ets.lookup_element(proven, :at, 2) end,
          clock: fn -> 1_000_000 end,
          stale: 3_600
        )

      # Rings — and only once, however many times the watchdog looks.
      {:ok, _} = Job.run(job, world, Snapshot.open([world]), 1)
      assert %{"name" => "backup-never-proven", "repair" => repair} = last_alarm(world)
      assert repair =~ "rumour"

      {:ok, _} = Job.run(job, world, Snapshot.open([world]), 2)

      count =
        Snapshot.open([world]) |> Snapshot.find(id: "alarms", attribute: "alarm") |> length()

      assert count == 1

      # The drill proves; the alarm clears itself, once.
      :ets.insert(proven, {:at, 999_900})
      {:ok, _} = Job.run(job, world, Snapshot.open([world]), 3)
      assert %{"cleared" => true} = last_alarm(world)

      {:ok, _} = Job.run(job, world, Snapshot.open([world]), 4)

      final =
        Snapshot.open([world]) |> Snapshot.find(id: "alarms", attribute: "alarm") |> length()

      assert final == 2
    end

    test "stale proven_at rings with the age and the ceiling", %{world: world} do
      job =
        Metrics.alarm_job(
          proven_at: fn -> 1_000_000 - 90_000 end,
          clock: fn -> 1_000_000 end,
          stale: 86_400
        )

      {:ok, _} = Job.run(job, world, Snapshot.open([world]), 1)
      assert %{"name" => "backup-stale", "repair" => repair} = last_alarm(world)
      assert repair =~ "90000s"
    end
  end
end
