defmodule LazyRiver.Snapshot do
  @moduledoc """
  One or more ledgers read at a transaction (`snp`).

  A snapshot is what you hold and compute over — the argument to a question,
  never the endpoint of one. Composing ledgers is the only operation that
  crosses a ledger boundary, which is why nothing can leak across one by
  accident: you get what you opened and nothing else.

  A caller outside the cluster does not hold the bytes. It holds the
  snapshot's `name/1` — which ledgers, at which transaction — and asks
  questions of it. The part that matters survives the wire: an answer at a
  named snapshot is the same answer forever, so a client caches on
  `{name, question}` and never invalidates.
  """

  alias LazyRiver.{Fact, Ledger}

  @enforce_keys [:at]
  defstruct [:at]

  @type name :: %{Ledger.ref() => non_neg_integer()}
  @type t :: %__MODULE__{at: name()}

  @doc """
  Open a snapshot over these ledgers, at wherever each one currently is.

  Authorization belongs here and nowhere else: which ledgers a caller may open
  is the whole of it. Not row rules, not predicates.
  """
  @spec open([Ledger.ref()]) :: t()
  def open(ledgers) when is_list(ledgers) do
    %__MODULE__{at: Map.new(ledgers, &{&1, Ledger.tx(&1)})}
  end

  @doc "The snapshot's name — small, stable, and safe to hand to a caller."
  @spec name(t()) :: name()
  def name(%__MODULE__{at: at}), do: at

  @doc "Reopen a snapshot from a name. The same name is the same snapshot."
  @spec reopen(name()) :: t()
  def reopen(at) when is_map(at), do: %__MODULE__{at: at}

  @doc "Every fact visible in this snapshot, oldest first across all ledgers."
  @spec facts(t()) :: [Fact.t()]
  def facts(%__MODULE__{at: at}) do
    at
    |> Enum.flat_map(fn {ledger, tx} -> Ledger.facts_at(ledger, tx) end)
    |> Enum.sort_by(& &1.tx)
  end

  @doc """
  The facts matching a pattern. An absent key is a wildcard.

      find(snapshot, id: 42)
      find(snapshot, attribute: :height)
      find(snapshot, id: 42, attribute: :height)

  This is the read a formula will make, which is why it is a pattern rather
  than a language: the evaluator can record what a question read, and that
  read set is what tells it when to answer again.
  """
  @spec find(t(), keyword()) :: [Fact.t()]
  def find(%__MODULE__{} = snapshot, pattern) do
    record_read(pattern)
    snapshot |> facts() |> Enum.filter(&Fact.matches?(&1, pattern))
  end

  @doc """
  The current answer for an id's attribute, or nil.

  Current means latest: nothing is rewritten, so a later fact corrects an
  earlier one and the correction is simply the one with the higher transaction.
  """
  @spec answer(t(), term(), atom()) :: term() | nil
  def answer(%__MODULE__{} = snapshot, id, attribute) do
    snapshot
    |> find(id: id, attribute: attribute)
    |> List.last()
    |> case do
      nil -> nil
      fact -> fact.answer
    end
  end

  # ── read tracking ──────────────────────────────────────────────────────────
  #
  # What a question read is what tells the evaluator when to answer it again.
  # Tracking is process-local and off by default, so an ordinary read costs a
  # `Process.get/1` and nothing else — only a formula turns it on.

  @reads :lazy_river_reads

  @doc """
  Run `fun`, and return what it returned alongside every pattern it read.

  This is the whole of re-execution: record the read set, and when a later fact
  falls inside it, answer again.
  """
  @spec track_reads((-> result)) :: {result, [keyword()]} when result: term()
  def track_reads(fun) when is_function(fun, 0) do
    outer = Process.put(@reads, [])

    try do
      result = fun.()
      {result, Process.get(@reads) |> Enum.reverse() |> Enum.uniq()}
    after
      if outer, do: Process.put(@reads, outer), else: Process.delete(@reads)
    end
  end

  defp record_read(pattern) do
    case Process.get(@reads) do
      nil -> :ok
      reads -> Process.put(@reads, [Enum.sort(pattern) | reads])
    end
  end
end
