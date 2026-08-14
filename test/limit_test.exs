defmodule Blazie.LimitTest do
  @moduledoc """
  The account-wide bucket, and who gets the next token.

  Time is an argument everywhere, so these tests own the clock — fairness
  claims measured against wall time are fairness claims measured against the
  scheduler, and the scheduler is not under test.
  """
  use ExUnit.Case, async: true

  alias Blazie.Limit

  defp limiter(limits) do
    name = :"limit_#{System.unique_integer([:positive])}"
    start_supervised!({Limit, name: name, limits: limits})
    name
  end

  test "a vendor with no ceiling written down passes" do
    server = limiter(%{})
    assert :ok = Limit.ask(server, "openai", "anyone", 0)
  end

  test "an empty bucket refuses with when to come back" do
    server = limiter(%{"openai" => {10, 5}})

    for _ <- 1..5, do: assert(:ok = Limit.ask(server, "openai", "s1", 0))

    assert {:error, %{problem: :over_limit, retry_after_ms: wait, repair: repair}} =
             Limit.ask(server, "openai", "s1", 0)

    # Ten a second is one per hundred milliseconds.
    assert wait in 50..200
    assert repair =~ "Retry in"
  end

  test "the bucket refills at the rate, up to the burst" do
    server = limiter(%{"openai" => {10, 5}})

    for _ <- 1..5, do: :ok = Limit.ask(server, "openai", "s1", 0)
    assert {:error, _} = Limit.ask(server, "openai", "s1", 0)

    # 500ms refills five tokens; 10 seconds refills five, not a hundred.
    assert :ok = Limit.ask(server, "openai", "s1", 500)
    assert %{tokens: tokens} = Limit.held(server, "openai", 100_000)
    assert tokens <= 5.0
  end

  test "two saturating Studios split a scarce bucket within tolerance" do
    server = limiter(%{"openai" => {100, 20}})

    # Both hammer: s1 asks three times for every s2 ask, across ten simulated
    # seconds. Without fairness s1 takes ~75% of the grants.
    grants =
      Enum.reduce(0..9_999, %{"s1" => 0, "s2" => 0}, fn ms, acc ->
        acc =
          case Limit.ask(server, "openai", "s1", ms) do
            :ok -> Map.update!(acc, "s1", &(&1 + 1))
            _ -> acc
          end

        acc =
          if rem(ms, 3) == 0 do
            case Limit.ask(server, "openai", "s2", ms) do
              :ok -> Map.update!(acc, "s2", &(&1 + 1))
              _ -> acc
            end
          else
            acc
          end

        acc
      end)

    total = grants["s1"] + grants["s2"]

    # The account ceiling held: ~100/s over 10s plus the initial burst.
    assert total <= 1_100

    # And the split is a split — the slower asker holds its half within
    # tolerance, rather than the 3:1 its politeness would otherwise cost it.
    assert abs(grants["s1"] - grants["s2"]) < total * 0.2,
           "unfair split: #{inspect(grants)}"
  end

  test "a slow caller is never starved by a fast one" do
    server = limiter(%{"openai" => {10, 4}})

    # s1 hammers every ms; s2 asks once every 500ms — twenty asks in all.
    {_acc, s2_granted} =
      Enum.reduce(0..9_999, {nil, 0}, fn ms, {_ignored, s2} ->
        Limit.ask(server, "openai", "s1", ms)

        s2 =
          if rem(ms, 500) == 0 do
            case Limit.ask(server, "openai", "s2", ms) do
              :ok -> s2 + 1
              _ -> s2
            end
          else
            s2
          end

        {nil, s2}
      end)

    assert s2_granted >= 15, "the polite caller was starved: #{s2_granted}/20"
  end
end
