defmodule Blazie.Surface.Controller do
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

  alias Blazie.{Attribute, Authority, Ledger, Snapshot, Wire}

  def open(conn, %{"ledgers" => []}) do
    refuse(conn, %{
      problem: :no_ledgers,
      repair: "Name the ledgers to open. Opening none is not opening everything."
    })
  end

  def open(conn, %{"ledgers" => names}) when is_list(names) do
    with {:ok, refs} <- open_all(names) do
      json(conn, %{"name" => refs |> Snapshot.open() |> Snapshot.name()})
    else
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  def open(conn, _params), do: refuse(conn, missing("ledgers"))

  @doc """
  Claim a ledger name, and hold what you claimed.

  Opening a ledger already creates it, so this adds no storage concept — what it
  adds is the grant, which is the part a caller could not write for itself. That
  is the whole reason a caller could not previously make one: every operation is
  checked against the ledgers it may name, so naming a new one was refused
  before anything could be created, and the only way a ledger came to exist was
  somebody with a shell writing a grant by hand.

  Names are global on a cluster, so this is first-come. A name already in use is
  refused rather than joined — quietly handing over somebody else's ledger
  because the name matched is the one outcome that must not happen here.
  """
  def claim(conn, %{"ledger" => name}) when is_binary(name) do
    token = conn.assigns.caller

    with {:ok, name} <- claimable(name),
         {:ok, _ref} <- Ledger.open(name),
         {:ok, _tx} <- Authority.grant_checked(token, name) do
      conn
      |> put_status(:created)
      |> json(%{"ledger" => name, "name" => %{name => 0}})
    else
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  def claim(conn, _params),
    do:
      refuse(conn, %{
        problem: :incomplete_request,
        repair: "Claiming a ledger needs `ledger`: the name to take."
      })

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
         # Arity two, so the ledger runs it inside itself against the facts this
         # write lands on. A caller can write a declaration like any other fact,
         # so the boundary has to ask what a redeclaration would do to what is
         # already there — and has to ask it where nothing can land in between.
         {:ok, tx} <- Ledger.append(ledger, assertions, check: &Attribute.check/2) do
      json(conn, %{"name" => %{name => tx}})
    else
      {:error, [refusal | _]} -> refuse(conn, refusal)
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  def write(conn, _params), do: refuse(conn, missing("ledger and facts"))

  # ── plumbing ───────────────────────────────────────────────────────────────

  # `$` is how the node's own ledgers are spelled — `$vitals`, `$authority`,
  # `$identities`. Reserving the prefix rather than listing the names means a
  # ledger added later is covered without anybody remembering to add it here.
  defp claimable("$" <> _ = name),
    do:
      {:error,
       %{
         problem: :reserved_name,
         repair:
           "Names beginning with `$` belong to the node itself, so #{inspect(name)} cannot be " <>
             "claimed. Pick a name that does not start with `$`."
       }}

  defp claimable(name) when byte_size(name) == 0,
    do:
      {:error,
       %{problem: :empty_name, repair: "A ledger needs a name. The empty string is not one."}}

  defp claimable(name) do
    if Ledger.exists?(name) do
      {:error,
       %{
         problem: :name_taken,
         repair:
           "#{inspect(name)} already holds facts, so it was not claimed. Pick another name, or " <>
             "ask whoever holds it to grant it to this caller."
       }}
    else
      {:ok, name}
    end
  end

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

  # A name goes out exactly as it is held: keyed by what each ledger is called.
  # There is nothing to translate, which is the point — the version of this that
  # translated zipped a map's values against the caller's list and trusted the
  # two to line up, and a map does not promise the order anybody put things in.
  defp reopen(name) do
    Enum.reduce_while(name, {:ok, %{}}, fn {ledger, tx}, {:ok, acc} ->
      # Opened rather than merely trusted: a name is a plain map a caller can
      # write by hand, so naming a ledger here has to go through the same door
      # as naming one anywhere else.
      case Ledger.open(ledger) do
        {:ok, _ref} ->
          {:cont, {:ok, Map.put(acc, ledger, tx)}}

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
