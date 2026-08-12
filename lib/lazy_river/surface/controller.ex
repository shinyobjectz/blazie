defmodule LazyRiver.Surface.Controller do
  @moduledoc """
  Open, ask, write. Doctrine 17, over the wire.

  A caller never holds a snapshot — it holds the name, which is which ledgers
  at which transaction, and asks questions of it. `write` returns a name too,
  which is what lets a caller read its own write without polling: the name it
  gets back is the snapshot its facts are in.

  Every refusal comes back as 422 with its repair, because a boundary that
  rejects without saying how to comply produces loops rather than compliance.
  """

  use Phoenix.Controller, formats: [:json]

  alias LazyRiver.{Attribute, Ledger, Snapshot, Wire}

  def open(conn, %{"ledgers" => []}) do
    refuse(conn, %{
      problem: :no_ledgers,
      repair: "Name the ledgers to open. Opening none is not opening everything."
    })
  end

  def open(conn, %{"ledgers" => names}) when is_list(names) do
    with {:ok, refs} <- open_all(names) do
      json(conn, %{"name" => refs |> Snapshot.open() |> Snapshot.name() |> named(names)})
    else
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  def open(conn, _params), do: refuse(conn, missing("ledgers"))

  def ask(conn, %{"name" => sent, "pattern" => pattern}) when is_map(sent) do
    with {:ok, name} <- Wire.snapshot_name(sent),
         {:ok, pattern} <- Wire.pattern(pattern),
         {:ok, snapshot} <- reopen(name) do
      json(conn, %{"facts" => snapshot |> Snapshot.find(pattern) |> Enum.map(&Wire.fact/1)})
    else
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  def ask(conn, _params), do: refuse(conn, missing("name and pattern"))

  def write(conn, %{"ledger" => name, "facts" => sent}) when is_list(sent) do
    with {:ok, assertions} <- assertions(sent),
         {:ok, ledger} <- Ledger.open(name),
         known = Attribute.known(Snapshot.open([ledger])),
         {:ok, tx} <- Ledger.append(ledger, assertions, check: &Attribute.check(&1, known)) do
      json(conn, %{"name" => %{name => tx}})
    else
      {:error, [refusal | _]} -> refuse(conn, refusal)
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  def write(conn, _params), do: refuse(conn, missing("ledger and facts"))

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp open_all(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Ledger.open(name) do
        {:ok, ref} ->
          {:cont, {:ok, [ref | acc]}}

        _ ->
          {:halt, {:error, %{problem: :cannot_open, repair: "#{inspect(name)} would not open."}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  # A snapshot's name is keyed by ledger reference inside; over the wire it is
  # keyed by the name the caller used.
  defp named(internal, names) do
    internal |> Map.values() |> Enum.zip(names) |> Map.new(fn {tx, name} -> {name, tx} end)
  end

  defp reopen(name) do
    Enum.reduce_while(name, {:ok, %{}}, fn {ledger, tx}, {:ok, acc} ->
      case Ledger.open(ledger) do
        {:ok, ref} ->
          {:cont, {:ok, Map.put(acc, ref, tx)}}

        _ ->
          {:halt,
           {:error, %{problem: :cannot_open, repair: "#{inspect(ledger)} would not open."}}}
      end
    end)
    |> case do
      {:ok, at} -> {:ok, Snapshot.reopen(at)}
      error -> error
    end
  end

  defp assertions(sent) do
    Enum.reduce_while(sent, {:ok, []}, fn one, {:ok, acc} ->
      case Wire.assertion(one) do
        {:ok, assertion} -> {:cont, {:ok, [assertion | acc]}}
        {:error, refusal} -> {:halt, {:error, refusal}}
      end
    end)
    |> case do
      {:ok, assertions} -> {:ok, Enum.reverse(assertions)}
      error -> error
    end
  end

  defp missing(what),
    do: %{problem: :incomplete_request, repair: "This operation needs #{what}."}

  defp refuse(conn, refusal) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      "error" => %{
        "problem" => to_string(refusal.problem),
        "repair" => refusal.repair
      }
    })
  end
end
