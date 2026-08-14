defmodule Blazie.PriceTest do
  @moduledoc """
  The verified price table, and the gate: two Studios contend for one
  limited vendor, the split is measured fair, and "what did this Studio
  cost this month" is a query whose numbers reconcile with what the vendor
  would bill.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Limit, Model, Price, Snapshot, TestLedger, World}

  setup do
    world = TestLedger.open()
    {:ok, _} = World.append(world, Attribute.seed() ++ Blazie.Spend.seed() ++ Model.seed())
    {:ok, _} = World.append(world, Price.seed())
    %{world: world}
  end

  defp priced(world, model, per_in, per_out) do
    {:ok, assertions} =
      Price.declare(model,
        per_million_in: per_in,
        per_million_out: per_out,
        source: "https://example.com/pricing",
        checked: "2026-08-14"
      )

    {:ok, _} = World.append(world, assertions)
    Snapshot.open([world])
  end

  test "a price without provenance is refused" do
    assert {:error, %{problem: :unverifiable_price, repair: repair}} =
             Price.declare("openai:gpt-4o", per_million_in: 2.5, per_million_out: 10.0)

    assert repair =~ "folklore"
  end

  test "an unpriced vendor books nothing, and the nothing is visible", %{world: world} do
    prices = Snapshot.open([world])

    assert [{"studio-1", "unpriced", "openai:gpt-4o", "price"}] =
             Price.booking("studio-1", "openai:gpt-4o", %{in: 100, out: 50}, prices)

    {:ok, _} =
      World.append(world, Price.booking("studio-1", "openai:gpt-4o", %{in: 1, out: 1}, prices))

    bill = Price.bill(Snapshot.open([world]), "studio-1")
    assert bill.usd == 0.0
    assert bill.calls == 0
    assert bill.unpriced == 1
  end

  test "a booked call carries exactly what the vendor would charge", %{world: world} do
    prices = priced(world, "openai:gpt-4o", 2.50, 10.00)
    usage = %{in: 1_000_000, out: 500_000}

    [{_id, "booked", booked, "price"}] = Price.booking("s", "openai:gpt-4o", usage, prices)

    assert booked["usd"] == 2.50 + 5.00
    assert booked["in"] == 1_000_000
  end

  test "the model wires the booking into the same transaction as the turn", %{world: world} do
    prices = priced(world, "openai:x", 1.0, 2.0)

    provider = fn _r, _m, _t, _o -> {:ok, {:said, "done"}, %{in: 1_000, out: 500}} end

    {:ok, "done", _} =
      Model.converse("openai:x", "hello", [], fn _ -> {:ok, %{}} end,
        provider: provider,
        into: world,
        by: "run-1",
        for: "studio-a",
        prices: prices
      )

    snapshot = Snapshot.open([world])
    [booked] = Snapshot.find(snapshot, id: "studio-a", attribute: "booked")
    [asked] = Snapshot.find(snapshot, id: "run-1", attribute: "asked")

    # Same transaction: the booking cannot disagree with the turn about
    # whether the call happened.
    assert booked.tx == asked.tx
    assert_in_delta booked.value["usd"], 1_000 / 1.0e6 * 1.0 + 500 / 1.0e6 * 2.0, 1.0e-9
  end

  describe "the Phase 3 gate" do
    test "two Studios contend, the split is fair, and both bills reconcile", %{world: world} do
      prices = priced(world, "openai:x", 2.0, 4.0)

      limiter = :"gate_limit_#{System.unique_integer([:positive])}"
      start_supervised!({Limit, name: limiter, limits: %{"openai" => {50, 10}}})

      provider = fn _r, _m, _t, _o -> {:ok, {:said, "ok"}, %{in: 2_000, out: 1_000}} end

      ask = fn studio, run ->
        Model.converse("openai:x", "go", [], fn _ -> {:ok, %{}} end,
          provider: provider,
          into: world,
          by: run,
          for: studio,
          prices: prices,
          limiter: limiter
        )
      end

      # Studio A hammers three asks to every one of Studio B's, both far past
      # what the vendor allows. The door decides who gets through.
      outcomes =
        for i <- 1..120 do
          a1 = ask.("studio-a", "a-#{i}-1")
          a2 = ask.("studio-a", "a-#{i}-2")
          a3 = ask.("studio-a", "a-#{i}-3")
          b = ask.("studio-b", "b-#{i}")
          Process.sleep(5)
          {[a1, a2, a3], [b]}
        end

      granted = fn list -> Enum.count(list, &match?({:ok, _, _}, &1)) end
      a_granted = outcomes |> Enum.flat_map(&elem(&1, 0)) |> then(granted)
      b_granted = outcomes |> Enum.flat_map(&elem(&1, 1)) |> then(granted)

      refused =
        outcomes
        |> Enum.flat_map(fn {a, b} -> a ++ b end)
        |> Enum.filter(&match?({:error, %{problem: :over_limit}}, &1))

      # The door refused somebody (both were over the account rate), the
      # refusals carried when to come back, and the polite Studio was not
      # crowded out: it holds at least a third of the grants despite asking
      # a quarter as often as it could have been drowned to.
      assert refused != []
      assert Enum.all?(refused, fn {:error, r} -> r.retry_after_ms > 0 end)

      assert b_granted >= (a_granted + b_granted) * 0.3,
             "the polite Studio was starved: #{b_granted} of #{a_granted + b_granted}"

      # The bills reconcile with what the vendor would charge: every granted
      # call cost (2000/1M)*2 + (1000/1M)*4 = 0.008 usd, and the ledger's
      # projection agrees to the cent with grants x price.
      snapshot = Snapshot.open([world])
      per_call = 2_000 / 1.0e6 * 2.0 + 1_000 / 1.0e6 * 4.0

      bill_a = Price.bill(snapshot, "studio-a")
      bill_b = Price.bill(snapshot, "studio-b")

      assert bill_a.calls == a_granted
      assert bill_b.calls == b_granted
      assert_in_delta bill_a.usd, a_granted * per_call, 1.0e-6
      assert_in_delta bill_b.usd, b_granted * per_call, 1.0e-6
      assert bill_a.unpriced == 0
    end
  end
end
