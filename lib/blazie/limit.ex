defmodule Blazie.Limit do
  @moduledoc """
  The one bucket per vendor account, and who gets the next token.

  A vendor's rate limit is per ACCOUNT, not per tenant — so the bucket must
  see every tenant's traffic, and a per-run or per-world limiter is a limit
  that is global by definition held somewhere it cannot be enforced. This is
  the strongest reason Nexus's Gateway exists, and the one gap blazie had to
  OWN rather than integrate: every Studio's calls pass here before any
  vendor sees them, and a 429 from the vendor means this module was wrong,
  not that a second Studio got unlucky.

  ## The bucket

  A token bucket per vendor: `rate` tokens a second, holding at most `burst`.
  A call takes one token or is refused — and the refusal carries when to
  come back, computed from the refill rate, because a boundary that rejects
  without saying how to comply produces loops, and a retrying agent is the
  caller least able to guess.

  ## Fairness: a quota, not a mood

  When tokens are scarce, whoever asks fastest would win them all — one
  chatty Studio starving the others while the account-wide limit holds. The
  first design gated fairness on the bucket being "contended", and the probe
  that killed it is worth keeping: the system sat exactly ON the gate's
  boundary, where every refilled token crossed briefly into the uncontended
  band and the fast asker took it there — 910 grants to 100, with the slow
  caller pinned at its share and the gate never quite closing.

  So fairness is a QUOTA, always on: each caller may take `rate / active`
  grants per rolling second, where active counts everyone who ASKED this
  window — asked, not granted, or a caller refused at the door would not
  count as contending and the quota it deserved would be handed to whoever
  refused it. Under quota, first-come still wins the next token; at quota,
  the refill belongs to whoever is not. Measured: two saturating callers
  split evenly; a polite caller is never starved by a hammering one.

  ## What this is not

  Not a queue — a refused call is the caller's to retry at the time given,
  because a queue in front of a vendor is memory that grows exactly when
  the vendor is slowest. Not a spend limit — `most` on a remit bounds spend;
  this bounds RATE. And not vocabulary: vendors are configuration
  (`config :blazie, :limits, %{"openai" => {rate, burst}}`), never words.

  Time comes from outside: every public function takes `now` in
  milliseconds, so the tests own the clock and the one impure caller is the
  edge that reads it.
  """

  use GenServer

  @type refusal :: %{problem: atom(), repair: String.t(), retry_after_ms: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Take one token from `vendor`'s bucket as `caller`, or learn when to retry.

  A vendor with no configured limit passes — absence means "this account has
  no ceiling anybody wrote down", and inventing one would refuse traffic on
  a guess. Writing the ceiling down is one config line, and the price table
  holds the same position about costs.
  """
  @spec ask(GenServer.server(), String.t(), term(), integer()) :: :ok | {:error, refusal()}
  def ask(server \\ __MODULE__, vendor, caller, now \\ System.monotonic_time(:millisecond)) do
    GenServer.call(server, {:ask, vendor, caller, now})
  end

  @doc "What a vendor's bucket looks like right now — observability, not vocabulary."
  @spec held(GenServer.server(), String.t(), integer()) :: map() | nil
  def held(server \\ __MODULE__, vendor, now \\ System.monotonic_time(:millisecond)) do
    GenServer.call(server, {:held, vendor, now})
  end

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    limits =
      Keyword.get(opts, :limits, Application.get_env(:blazie, :limits, %{}))

    {:ok, %{limits: limits, buckets: %{}}}
  end

  @impl true
  def handle_call({:ask, vendor, caller, now}, _from, state) do
    case Map.fetch(state.limits, vendor) do
      :error ->
        {:reply, :ok, state}

      {:ok, {rate, burst}} ->
        bucket = state.buckets |> Map.get(vendor) |> refilled(rate, burst, now)
        {answer, bucket} = take(bucket, caller, rate, burst)
        {:reply, answer, put_in(state.buckets[vendor], bucket)}
    end
  end

  def handle_call({:held, vendor, now}, _from, state) do
    case Map.fetch(state.limits, vendor) do
      :error ->
        {:reply, nil, state}

      {:ok, {rate, burst}} ->
        bucket = state.buckets |> Map.get(vendor) |> refilled(rate, burst, now)

        {:reply,
         %{
           tokens: Float.round(bucket.tokens, 2),
           window: bucket.window,
           rate: rate,
           burst: burst
         }, state}
    end
  end

  # ── the bucket ─────────────────────────────────────────────────────────────

  defp refilled(nil, _rate, burst, now) do
    %{tokens: burst * 1.0, at: now, window: %{}, asked: MapSet.new(), window_at: now}
  end

  defp refilled(bucket, rate, burst, now) do
    tokens = min(burst * 1.0, bucket.tokens + (now - bucket.at) * rate / 1000)

    # The fairness window is a second — the bucket's own timescale. Rolled
    # rather than decayed: what matters is who has been taking DURING this
    # scarcity, and last minute's appetite is not this second's.
    if now - bucket.window_at >= 1_000 do
      %{bucket | tokens: tokens, at: now, window: %{}, asked: MapSet.new(), window_at: now}
    else
      %{bucket | tokens: tokens, at: now}
    end
  end

  defp take(bucket, caller, rate, _burst) do
    bucket = %{bucket | asked: MapSet.put(bucket.asked, caller)}
    active = max(MapSet.size(bucket.asked), 1)
    fair = rate / active

    cond do
      bucket.tokens < 1.0 ->
        {refusal(bucket, rate, "the bucket is empty"), bucket}

      Map.get(bucket.window, caller, 0) >= fair ->
        {refusal(
           bucket,
           rate,
           "this caller has its fair share for the second (#{trunc(fair)} of #{rate}, " <>
             "#{active} contending)"
         ), bucket}

      true ->
        window = Map.update(bucket.window, caller, 1, &(&1 + 1))
        {:ok, %{bucket | tokens: bucket.tokens - 1.0, window: window}}
    end
  end

  defp refusal(bucket, rate, why) do
    wait = max(trunc((1.0 - bucket.tokens) * 1000 / rate), 1)

    {:error,
     %{
       problem: :over_limit,
       retry_after_ms: wait,
       repair:
         "The vendor's account-wide limit is protecting itself: #{why}. Retry in #{wait}ms. " <>
           "This refusal is the alternative to the vendor refusing the whole account."
     }}
  end
end
