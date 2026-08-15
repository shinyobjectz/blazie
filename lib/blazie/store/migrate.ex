defmodule Blazie.Store.Migrate do
  @moduledoc """
  The one-way door from a `.ledger` to a `.sqlite`, meaning preserved.

  This module parses no bytes. It opens the old world through `Store.File` —
  whose replay already reads every shape this database ever wrote (the
  `answer` slot, the `LazyRiver.Fact` tag; `Fact.from_stored/1`, pinned by
  `old_shapes_test`) — and appends the normalized facts into `Store.SQLite`
  with their original tx numbers, in replay order, so within-transaction
  position survives (the landmine `Snapshot.value/3` rests on).

  One-way and refusing to double: a target that already holds transactions is
  refused with the repair, because running a migration twice must not write a
  world twice. The ledger is untouched either way — it stays the read-only
  legacy record, and `Store.Record` stays alive to read it, forever.
  """

  alias Blazie.Store

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc """
  Migrate one world's ledger into a SQLite file in the same directory.

  Returns `{:ok, %{facts: n, transactions: n}}`, or a refusal when there is
  no ledger to read or the target already holds facts.
  """
  @spec ledger_to_sqlite(term(), keyword()) :: {:ok, map()} | {:error, refusal()}
  def ledger_to_sqlite(name, opts) do
    dir = Keyword.fetch!(opts, :dir)

    with :ok <- ledger_present(name, dir),
         {:ok, target} <- fresh_target(name, opts) do
      {:ok, source} = Store.File.open(name, dir: dir)
      facts = Store.File.replay(source)
      :ok = Store.File.close(source)

      # One SQL transaction for the whole copy: seq is assigned in insertion
      # order, and insertion order is replay order, so position is preserved.
      # The facts carry their ORIGINAL tx numbers.
      {:ok, target} =
        case facts do
          [] -> {:ok, target}
          facts -> Store.SQLite.append(target, facts)
        end

      :ok = Store.SQLite.close(target)

      {:ok,
       %{
         facts: length(facts),
         transactions: facts |> Enum.map(& &1.tx) |> Enum.uniq() |> length()
       }}
    end
  end

  defp ledger_present(name, dir) do
    if File.exists?(Path.join(dir, Store.File.filename(name))) do
      :ok
    else
      {:error,
       %{
         problem: :no_ledger,
         repair:
           "No ledger for #{inspect(name)} in #{dir}. A migration reads what exists; " <>
             "a world that never wrote one has nothing to migrate."
       }}
    end
  end

  defp fresh_target(name, opts) do
    {:ok, target} = Store.SQLite.open(name, opts)

    case Store.SQLite.last_tx(target) do
      0 ->
        {:ok, target}

      tx ->
        :ok = Store.SQLite.close(target)

        {:error,
         %{
           problem: :already_migrated,
           repair:
             "The sqlite file for #{inspect(name)} already holds #{tx} transactions. " <>
               "Migrating into it again would write the world twice; open it as it is, " <>
               "or delete the .sqlite file first if this was a failed attempt."
         }}
    end
  end
end
