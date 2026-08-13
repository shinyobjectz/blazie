defmodule Blazie.Surface.Controller do
  @moduledoc """
  Run, and claim. That is the whole of it.

  There used to be `open`, `ask` and `write` here, and between them they asked a
  caller to know what a fact is, what a pattern is, and that a snapshot's name is
  a map of ledgers to transactions. All three still happen — `run/2` opens, runs,
  and appends — but as steps inside one operation rather than vocabulary anybody
  has to learn. What a caller sends is Lua.

  The properties survive the change, because they were never properties of the
  three verbs. A caller still holds a name and never the bytes; pinning `name`
  still makes the same source answer the same forever; and a write still comes
  back as the name its facts landed in, so a caller reads its own write without
  polling for it.

  Every refusal comes back as 422 with its repair, because a boundary that
  rejects without saying how to comply produces loops rather than compliance.
  """

  use Phoenix.Controller, formats: [:json]

  alias Blazie.{Attribute, Authority, Ledger, Lua, Snapshot, Wire}

  @doc """
  Run Lua against a ledger, and append whatever it wrote.

  This is the whole public surface. `open`, `ask` and `write` were three
  operations that between them required a caller to know what a fact is, what a
  pattern is, and that a name is a map of ledgers to transactions. All three are
  still here underneath — this opens, runs, and appends — but none of them is
  something anybody has to learn.

      {"ledger": "main", "source": "ada.height = 180  return ada.height"}

  `name` pins which snapshot to read, so re-running the same source at the same
  name is the same answer forever. Left out, it reads now. `also` adds
  read-only ledgers to the world; writes always land in `ledger`, because a
  chunk that could write anywhere would need a syntax for saying where, and
  there is nothing to say it with that is not a fact again.
  """
  def run(conn, %{"ledger" => name, "source" => source} = params) when is_binary(source) do
    with {:ok, snapshot} <- world_for(name, params),
         {:ok, value, staged} <- evaluate(source, snapshot, params),
         {:ok, at} <- append(name, staged) do
      json(conn, %{
        "value" => value,
        "name" => Map.merge(Snapshot.name(snapshot), at),
        "wrote" => length(staged)
      })
    else
      {:error, [refusal | _]} -> refuse(conn, refusal)
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  def run(conn, _params),
    do:
      refuse(conn, %{
        problem: :incomplete_request,
        repair: "Running needs `ledger` and `source`: where to run, and the Lua to run."
      })

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

  # ── running ────────────────────────────────────────────────────────────────

  # Every ledger here has already been through the door: `Authorize` reads
  # `ledger`, `also` and the keys of `name` off the params, so a caller cannot
  # widen the world by adding one.
  defp world_for(name, params) do
    ledgers = [name | List.wrap(Map.get(params, "also", []))] |> Enum.uniq()

    with {:ok, refs} <- open_all(ledgers) do
      case Map.get(params, "name") do
        nil -> {:ok, Snapshot.open(refs)}
        pinned -> with {:ok, at} <- Wire.snapshot_name(pinned), do: {:ok, Snapshot.reopen(at)}
      end
    end
  end

  # A job gets the real clock and http; a formula gets neither. Defaulting to
  # formula means the reaching kind is always something a caller asked for.
  defp evaluate(source, snapshot, params) do
    kind = if Map.get(params, "as") == "job", do: :job, else: :formula
    at = snapshot |> Snapshot.name() |> Map.values() |> Enum.max(fn -> 0 end)

    Lua.World.run(source, snapshot, as: kind, at: at)
  end

  # Nothing written is not an error — plenty of useful chunks only read. The
  # empty map merges cleanly into the name that goes back.
  defp append(_ledger, []), do: {:ok, %{}}

  defp append(ledger, staged) do
    with {:ok, ref} <- Ledger.open(ledger),
         {:ok, tx} <- Ledger.append(ref, staged, check: &Attribute.check/2) do
      {:ok, %{ledger => tx}}
    end
  end

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
