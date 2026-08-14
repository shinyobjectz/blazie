defmodule Blazie.Price do
  @moduledoc """
  What a vendor charges, verified, and what each Studio's calls therefore cost.

  `Spend` records tokens and deliberately never refuses — observing is its
  whole job. This is the other half socialite's Book already proved out: a
  PRICE TABLE whose every row carries its source and the date somebody
  checked it, and a booked row per call attributed to whoever the call was
  for. Rollups are projections over the booked facts, because the facts are
  the ledger and a running total kept beside them is a second account that
  can disagree with the first.

  ## An unpriced vendor books nothing

  Not zero — NOTHING. A zero row reads as "measured, and free", which is the
  one lie a cost ledger must never tell. An unpriced call instead lands an
  `unpriced` fact naming the vendor, so "which calls are we flying blind on"
  is a query, and the repair is one `declare/3` away.

  ## A price without a source is refused

  Prices change under you, and a table nobody can re-verify decays into
  folklore. `declare/3` requires `source:` (where the number came from) and
  `checked:` (when somebody last looked), the same discipline as every other
  measured number in this tree.

      Price.declare("openai:gpt-4o",
        per_million_in: 2.50, per_million_out: 10.00,
        source: "https://openai.com/api/pricing", checked: "2026-08-14")
  """

  alias Blazie.{Attribute, Snapshot, World}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The attributes prices and bookings are written with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("per_million_in", answers: "number") ++
      Attribute.define("per_million_out", answers: "number") ++
      Attribute.define("per_gpu_second", answers: "number") ++
      Attribute.define("price_source", answers: "name") ++
      Attribute.define("price_checked", answers: "name") ++
      Attribute.define("booked", answers: "any", cardinality: "many") ++
      Attribute.define("unpriced", answers: "name", cardinality: "many")
  end

  @doc """
  The facts declaring one model's price. Refused without provenance.
  """
  @spec declare(String.t(), keyword()) :: {:ok, [tuple()]} | {:error, refusal()}
  def declare(model, opts) do
    source = Keyword.get(opts, :source)
    checked = Keyword.get(opts, :checked)

    if is_binary(source) and is_binary(checked) do
      id = "price:" <> model

      {:ok,
       [
         {id, "per_million_in", Keyword.get(opts, :per_million_in, 0.0) * 1.0},
         {id, "per_million_out", Keyword.get(opts, :per_million_out, 0.0) * 1.0},
         {id, "per_gpu_second", Keyword.get(opts, :per_gpu_second, 0.0) * 1.0},
         {id, "price_source", source},
         {id, "price_checked", checked}
       ]}
    else
      {:error,
       %{
         problem: :unverifiable_price,
         repair:
           "A price needs `source:` (where the number came from) and `checked:` (when " <>
             "somebody last looked). A table nobody can re-verify decays into folklore, " <>
             "and the bill it produces is folklore too."
       }}
    end
  end

  @doc "The current price for a model, or nil — and nil means book nothing."
  @spec of(Snapshot.t(), String.t()) :: %{in: float(), out: float(), gpu: float()} | nil
  def of(%Snapshot{} = snapshot, model) do
    id = "price:" <> model

    with per_in when is_number(per_in) <- Snapshot.value(snapshot, id, "per_million_in"),
         per_out when is_number(per_out) <- Snapshot.value(snapshot, id, "per_million_out") do
      %{in: per_in, out: per_out, gpu: Snapshot.value(snapshot, id, "per_gpu_second") || 0.0}
    else
      _ -> nil
    end
  end

  @doc "What one call cost at a price, in USD — tokens, GPU seconds, or both."
  @spec cost(map(), map()) :: float()
  def cost(price, usage) do
    Map.get(usage, :in, 0) / 1_000_000 * price.in +
      Map.get(usage, :out, 0) / 1_000_000 * price.out +
      Map.get(usage, :gpu_seconds, 0.0) * Map.get(price, :gpu, 0.0)
  end

  @doc """
  The facts booking one call — or the fact that says it could not be booked.

  Answered as assertions for the caller to land beside the call's own record,
  so the booking and the turn share a transaction and cannot disagree about
  whether the call happened.
  """
  @spec booking(
          term(),
          String.t(),
          %{in: non_neg_integer(), out: non_neg_integer()},
          Snapshot.t() | nil
        ) ::
          [tuple()]
  def booking(_for, _model, _usage, nil), do: []

  def booking(for_whom, model, usage, %Snapshot{} = prices) do
    case of(prices, model) do
      nil ->
        [{for_whom, "unpriced", model, "price"}]

      price ->
        [
          {for_whom, "booked",
           %{
             "model" => model,
             "usd" => cost(price, usage),
             "in" => Map.get(usage, :in, 0),
             "out" => Map.get(usage, :out, 0),
             "gpu_seconds" => Map.get(usage, :gpu_seconds, 0.0)
           }, "price"}
        ]
    end
  end

  @doc """
  What a Studio's calls cost, from the ledger — a projection, never a counter.

  Answers the total, the call count, the split by model, and how many calls
  were flying unpriced — because a bill that silently omits the unpriced
  half reads as smaller than the truth.
  """
  @spec bill(Snapshot.t(), term()) :: %{
          usd: float(),
          calls: non_neg_integer(),
          by_model: %{String.t() => float()},
          unpriced: non_neg_integer()
        }
  def bill(%Snapshot{} = snapshot, for_whom) do
    booked =
      snapshot
      |> Snapshot.find(id: for_whom, attribute: "booked")
      |> Enum.map(& &1.value)
      |> Enum.filter(&is_map/1)

    %{
      usd:
        booked
        |> Enum.map(&Map.get(&1, "usd", 0.0))
        |> Enum.sum()
        |> Kernel.*(1.0)
        |> Float.round(6),
      calls: length(booked),
      by_model:
        booked
        |> Enum.group_by(&Map.get(&1, "model"))
        |> Map.new(fn {model, rows} ->
          {model,
           rows
           |> Enum.map(&Map.get(&1, "usd", 0.0))
           |> Enum.sum()
           |> Kernel.*(1.0)
           |> Float.round(6)}
        end),
      unpriced: length(Snapshot.find(snapshot, id: for_whom, attribute: "unpriced"))
    }
  end

  @doc "The snapshot prices are read from, if a prices world is configured and open."
  @spec current() :: Snapshot.t() | nil
  def current do
    case Application.get_env(:blazie, :price_world) do
      nil ->
        nil

      world ->
        case World.open(world) do
          {:ok, ref} -> Snapshot.open([ref])
          _ -> nil
        end
    end
  end
end
