defmodule Blazie.Store.SQLite do
  @moduledoc """
  A world as one SQLite file — the engine rented, the discipline kept.

  Facts are rows in an append-only table; the sort orders `Store.File` holds
  in RAM (241 bytes a fact, 87% of it the indexes) become on-disk B-trees;
  atomicity comes from `BEGIN IMMEDIATE` instead of the torn-record CRC
  apparatus; WAL is what a replicator ships (docs/storage-plan.md, P4). The
  append-only property is NOT the engine's — SQLite would happily UPDATE — it
  is this module's: the only statement ever issued against `facts` is INSERT,
  the same one place `Store.File` kept the same promise.

  ## The two orderings, stated because one is a landmine

  Transactions order by `tx` (the World's counter, resumed via `last_tx/1`);
  facts WITHIN a transaction order by position, which here is `seq` — the
  rowid, assigned in insertion order. Every read is `ORDER BY tx, seq`,
  because `Snapshot.value/3` is last-write-wins by list position and a store
  that sorts by tx alone answers it wrong intermittently. The conformance
  suite pins this in memory and across a reopen.

  ## Keys are deterministic, decode is a trust boundary

  Ids and world names can be maps, and `term_to_binary/1` may order a map's
  pairs differently across OTP releases (EEP-18) — so every encoded key uses
  `[:deterministic]`, or the same id could stop matching itself after an
  upgrade. Reads decode with `[:safe]` and refuse what `Record.harmless?/1`
  refuses (C7): these bytes can come back from a restored replica, and a fun
  in a value is an attack, not data.

  Sync maps to the engine's own words: `sync: true` is `synchronous=FULL`,
  the default is `NORMAL` — WAL's honest middle, the same trade `LEDGER_SYNC`
  has always named.
  """

  @behaviour Blazie.Store

  alias Blazie.Fact
  alias Blazie.Store.Record
  alias Exqlite.Sqlite3

  @create """
  CREATE TABLE IF NOT EXISTS facts (
    seq       INTEGER PRIMARY KEY,
    tx        INTEGER NOT NULL,
    id_blob   BLOB    NOT NULL,
    attribute TEXT    NOT NULL,
    value     BLOB    NOT NULL,
    by_blob   BLOB
  )
  """
  @eavt "CREATE INDEX IF NOT EXISTS facts_eavt ON facts (id_blob, attribute, tx)"
  @aevt "CREATE INDEX IF NOT EXISTS facts_aevt ON facts (attribute, tx)"

  @impl true
  def open(name, opts) do
    dir = Keyword.get(opts, :dir, "priv/ledgers")
    File.mkdir_p!(dir)
    path = Path.join(dir, filename(name))

    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(db, "PRAGMA synchronous=#{synchronous(opts)}")
    :ok = Sqlite3.execute(db, @create)
    :ok = Sqlite3.execute(db, @eavt)
    :ok = Sqlite3.execute(db, @aevt)

    {:ok, %{db: db, path: path, last_tx: highest_tx(db)}}
  end

  @impl true
  def append(state, facts) do
    :ok = Sqlite3.execute(state.db, "BEGIN IMMEDIATE")

    {:ok, stmt} =
      Sqlite3.prepare(
        state.db,
        "INSERT INTO facts (tx, id_blob, attribute, value, by_blob) VALUES (?1, ?2, ?3, ?4, ?5)"
      )

    for %Fact{} = fact <- facts do
      :ok =
        Sqlite3.bind(stmt, [
          fact.tx,
          {:blob, key(fact.id)},
          fact.attribute,
          {:blob, :erlang.term_to_binary(fact.value)},
          fact.by && {:blob, key(fact.by)}
        ])

      :done = Sqlite3.step(state.db, stmt)
      :ok = Sqlite3.reset(stmt)
    end

    :ok = Sqlite3.release(state.db, stmt)
    :ok = Sqlite3.execute(state.db, "COMMIT")

    last = facts |> Enum.map(& &1.tx) |> Enum.max(fn -> state.last_tx end)
    {:ok, %{state | last_tx: max(state.last_tx, last)}}
  end

  @impl true
  def replay(state) do
    rows(state, "SELECT tx, id_blob, attribute, value, by_blob FROM facts ORDER BY tx, seq", [])
  end

  @impl true
  def close(state) do
    Sqlite3.close(state.db)
    :ok
  end

  @impl true
  def seek(state, pattern, upto) do
    {where, params} = narrow(pattern, upto)

    state
    |> rows(
      "SELECT tx, id_blob, attribute, value, by_blob FROM facts WHERE #{where} ORDER BY tx, seq",
      params
    )
    |> Enum.filter(&Fact.matches?(&1, pattern))
  end

  @impl true
  def tail(state, count) do
    rows(
      state,
      "SELECT tx, id_blob, attribute, value, by_blob FROM facts WHERE tx IN " <>
        "(SELECT DISTINCT tx FROM facts ORDER BY tx DESC LIMIT ?1) ORDER BY tx, seq",
      [count]
    )
  end

  @impl true
  def last_tx(state), do: state.last_tx

  @doc "What Storage reads — bytes on disk and transactions reached."
  def stats(state) do
    bytes =
      case File.stat(state.path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    %{bytes: bytes, transactions: state.last_tx, checkpoint_bytes: 0}
  end

  @doc "One name, one file — deterministic, so an upgrade cannot rename a tenant."
  def filename(name) do
    encoded = name |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64()
    encoded <> ".sqlite"
  end

  # ── reading ─────────────────────────────────────────────────────────────────

  defp rows(state, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(state.db, sql)
    :ok = if params == [], do: :ok, else: Sqlite3.bind(stmt, params)
    {:ok, raw} = Sqlite3.fetch_all(state.db, stmt)
    :ok = Sqlite3.release(state.db, stmt)
    Enum.map(raw, &fact/1)
  end

  defp fact([tx, id_blob, attribute, value_blob, by_blob]) do
    fact = %Fact{
      id: decode(id_blob),
      attribute: attribute,
      value: decode(value_blob),
      tx: tx,
      by: by_blob && decode(by_blob)
    }

    # The same gate every stored byte passes (C7): a shape that could execute
    # is refused, because these bytes can come back from a bucket.
    unless Record.stored_fact?(fact) and Record.harmless?(fact.value) do
      raise "refused a stored fact that is not harmless data: #{inspect(fact.id)}"
    end

    fact
  end

  defp decode(blob), do: :erlang.binary_to_term(blob, [:safe])

  defp key(term), do: :erlang.term_to_binary(term, [:deterministic])

  # The index-backed narrows; anything else (value:, by:) is answered by the
  # Fact.matches?/2 filter above, the same division Paged draws.
  defp narrow(pattern, upto) do
    base = {"tx <= ?1", [upto]}

    Enum.reduce(pattern, base, fn
      {:id, id}, {where, params} ->
        {where <> " AND id_blob = ?#{length(params) + 1}", params ++ [{:blob, key(id)}]}

      {:attribute, attribute}, {where, params} when is_binary(attribute) ->
        {where <> " AND attribute = ?#{length(params) + 1}", params ++ [attribute]}

      {:tx, tx}, {where, params} ->
        {where <> " AND tx = ?#{length(params) + 1}", params ++ [tx]}

      _other, acc ->
        acc
    end)
  end

  defp highest_tx(db) do
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT COALESCE(MAX(tx), 0) FROM facts")
    {:row, [tx]} = Sqlite3.step(db, stmt)
    :done = Sqlite3.step(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    tx
  end

  defp synchronous(opts) do
    sync = Keyword.get(opts, :sync, Application.get_env(:blazie, :ledger_sync, false))
    if sync, do: "FULL", else: "NORMAL"
  end
end
