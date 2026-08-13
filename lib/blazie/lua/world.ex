defmodule Blazie.Lua.World do
  @moduledoc """
  The database, as ordinary Lua tables (`wor`).

  This is the surface everybody outside this repo is shown, and the reason it
  exists is that the words underneath it — fact, attribute, assertion, pattern —
  are how the thing is *built*, not something anyone should have to learn to use
  it. An entity is a table. A field is a field. An edge is a field whose value
  is another entity.

      ada.height = 180
      ada.friend = grace

      print(ada.friend.height)

      for p in each { height = 180 } do print(p.id) end
      print(at(42).ada.height)

  Nothing above names a fact, and none of it is a translation layer bolted on
  afterwards: a fact already *is* an id, a field and a value, so a table is the
  shape it was in before anybody wrote it down.

  ## Reads come from a snapshot; writes go nowhere yet

  Reading asks the snapshot the world was built on, so the same code at the same
  name answers the same forever. Writing stages an assertion and returns it to
  the host — a guest never touches a ledger. That is what lets one path serve
  both a formula, whose writes are its answer, and a job, whose writes are
  appended after it returns.

  ## Fields declare themselves

  A write to an undeclared field declares it, inferring what it answers from
  what was assigned. The vocabulary is real and still checked; it is just no
  longer something a person has to write down first. Before this, the first
  write into a fresh ledger was refused until somebody defined an attribute by
  hand — correct, and an absurd thing to ask of someone whose whole interface is
  `ada.height = 180`.

  ## The cost of bare names

  `_G` carries a metatable, so any name that is not already a global is an
  entity. That is what buys `ada.height` instead of `db.ada.height`, and the
  price is that a typo is an empty entity rather than an error. It is a real
  cost, taken deliberately: the surface is meant to read like Lua, and a prefix
  on every line is a tax paid by every reader forever to catch a typo once.
  """

  alias Blazie.{Attribute, Fact, Snapshot}

  @typedoc "An assertion a guest staged: id, field, value."
  @type assertion :: {term(), String.t(), term()}

  # Staged writes live in the guest's own process dictionary. Each guest runs in
  # a process of its own that is killed on deadline or heap limit, so this is
  # already scoped to exactly one run and dies with it — an Agent or an ETS
  # table would be a second thing to clean up on a path whose whole point is
  # that it can be killed at any moment.
  @staged :blazie_lua_staged

  @doc """
  Bind a snapshot into a Luerl state as tables.

  Returns the state with the world in it. Reads answer from `snapshot`; writes
  accumulate and are collected with `staged/0`.
  """
  @spec bind(term(), Snapshot.t()) :: term()
  def bind(state, %Snapshot{} = snapshot) do
    Process.put(@staged, [])
    Process.put(:blazie_lua_snapshot, snapshot)

    state
    |> bind_functions()
    |> load_prelude()
  end

  @doc "Everything the guest wrote, in the order it wrote it."
  @spec staged() :: [assertion()]
  def staged, do: @staged |> Process.get([]) |> Enum.reverse()

  @doc """
  Run a chunk against a snapshot, and hand back what it returned and wrote.

      {:ok, value, assertions} = World.run("ada.height = 180", snapshot)

  Nothing is appended here. A formula's assertions *are* its answer and get
  cached; a job's are appended after it returns. Keeping the decision outside
  means one path serves both, and neither can write by accident.
  """
  @spec run(binary(), Snapshot.t(), keyword()) ::
          {:ok, term(), [assertion()]} | {:error, map()}
  def run(source, %Snapshot{} = snapshot, opts \\ []) do
    Blazie.Lua.collect(source, Keyword.put(opts, :snapshot, snapshot))
  end

  # ── the bridge ─────────────────────────────────────────────────────────────

  defp bind_functions(state) do
    [
      {"__read", &read/2},
      {"__write", &write/2},
      {"__each", &each/2},
      {"__fields", &fields/2}
    ]
    |> Enum.reduce(state, fn {name, fun}, acc ->
      {_, acc} = :luerl.set_table_keys([name], {:erl_func, fun}, acc)
      acc
    end)
  end

  # Two values back, not one: the second says whether the first is another
  # entity's id. There is no marker on a stored value that would say so — a
  # relation and an attribute are the identical row — so the answer comes from
  # what the field was declared to answer, which is exactly what a declaration
  # is for.
  defp read([id, field | rest], state) do
    snapshot = at_snapshot(List.first(rest))

    case Snapshot.value(snapshot, entity_id(id), to_string(field)) do
      nil -> {[nil, false], state}
      value -> {[value, reference?(snapshot, to_string(field))], state}
    end
  end

  defp read(_args, state), do: {[nil, false], state}

  # Extra arguments are ignored rather than dropping the call. These are plain
  # globals a guest can call directly, so arity is something a guest chooses —
  # and a silent no-op that looks like a successful write is worse than an
  # ignored argument. There is no fourth slot to put a producer in either way:
  # what is staged is three wide, so provenance cannot be claimed from in here.
  defp write([id, field, value, reference? | _rest], state) do
    field = to_string(field)
    snapshot = Process.get(:blazie_lua_snapshot)
    known? = Attribute.defined?(snapshot, field) or declared_here?(field)

    cond do
      # Retracting a field nobody ever wrote. There is nothing to unsay, and
      # declaring one so that its retraction can be recorded would leave a
      # ledger describing a field that never held anything.
      is_nil(value) and not known? ->
        {[], state}

      true ->
        declaration =
          if known?, do: [], else: Attribute.define(field, answers: answers_for(value, reference?))

        stage(declaration ++ [{entity_id(id), field, value}])
        {[], state}
    end
  end

  defp write(_args, state), do: {[], state}

  defp each([spec | rest], state) do
    snapshot = at_snapshot(List.first(rest))
    wanted = :luerl.decode(spec, state)

    ids =
      snapshot
      |> Snapshot.find(narrowest(wanted))
      |> Enum.filter(&matches_all?(&1, wanted, snapshot))
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.sort_by(&inspect/1)

    # Luerl builds its own tables; an Erlang list is encoded as one here so the
    # prelude can index it.
    {encoded, state} = :luerl.encode(ids, state)
    {[encoded], state}
  end

  defp each(_args, state), do: {[nil], state}

  # Everything currently said about one entity, which is what `pairs(ada)`
  # iterates. A retracted field is absent rather than present-and-nil: it was
  # unsaid, and a data browser listing it as a column with nothing under it
  # would be showing the retraction rather than the data.
  defp fields([id | rest], state) do
    snapshot = at_snapshot(List.first(rest))
    id = entity_id(id)

    held =
      snapshot
      |> Snapshot.find(id: id)
      |> Enum.map(& &1.attribute)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce([], fn field, acc ->
        case Snapshot.value(snapshot, id, field) do
          nil -> acc
          value -> [{field, value} | acc]
        end
      end)
      |> Enum.reverse()

    {encoded, state} = :luerl.encode(held, state)
    {[encoded], state}
  end

  defp fields(_args, state), do: {[nil], state}

  # ── deciding what a value is ───────────────────────────────────────────────

  # Which constraint to hand the ledger, so it can use an index instead of
  # returning everything for this to filter.
  #
  # A ledger indexes by id, by attribute, and by value, so an exact value is the
  # narrowest thing there is to ask for and a bare field is the next. Asking for
  # everything and filtering here read the whole ledger for a query that matched
  # one row — correct, and it made `each` cost the size of the database rather
  # than the size of the answer.
  #
  # The filter below still runs: it is what applies the *remaining* constraints,
  # and one pattern can only carry one.
  defp narrowest(wanted) do
    exact = Enum.find(wanted, fn {_field, want} -> want != true end)
    any = Enum.find(wanted, fn {_field, want} -> want == true end)

    cond do
      exact -> [attribute: to_string(elem(exact, 0)), value: elem(exact, 1)]
      any -> [attribute: to_string(elem(any, 0))]
      # An empty spec is everyone, and everyone is the whole ledger.
      true -> []
    end
  end

  # `true` in a spec means "has this field at all", which is the difference
  # between asking who is 18 and asking who has an age.
  defp matches_all?(%Fact{} = fact, wanted, snapshot) do
    Enum.all?(wanted, fn {field, want} ->
      held = Snapshot.value(snapshot, fact.id, to_string(field))

      case want do
        true -> held != nil
        other -> held == other
      end
    end)
  end

  defp reference?(snapshot, field) do
    Snapshot.value(snapshot, field, "answers") == "id" or staged_answers(field) == "id"
  end

  # A field declared in this same run is not in the snapshot yet, so the
  # staged declarations have to be consulted too — otherwise writing an edge
  # and reading it back in one chunk would come back as a bare string.
  defp staged_answers(field) do
    Enum.find_value(Process.get(@staged, []), fn
      {^field, "answers", value} -> value
      _ -> nil
    end)
  end

  defp declared_here?(field) do
    Enum.any?(Process.get(@staged, []), fn
      {^field, "is", "attribute"} -> true
      _ -> false
    end)
  end

  defp answers_for(_value, true), do: "id"
  defp answers_for(value, _) when is_integer(value), do: "integer"
  defp answers_for(value, _) when is_number(value), do: "number"
  defp answers_for(value, _) when is_boolean(value), do: "boolean"
  defp answers_for(value, _) when is_binary(value), do: "name"
  defp answers_for(_value, _), do: "any"

  defp stage(assertions), do: Process.put(@staged, Enum.reverse(assertions) ++ Process.get(@staged, []))

  defp at_snapshot(nil), do: Process.get(:blazie_lua_snapshot)

  # `at(42)` reads "no later than 42". With one ledger that is exactly what it
  # says; with several it caps each, because a single number cannot name a
  # position in more than one sequence and capping is the reading that never
  # invents a transaction a ledger never had.
  defp at_snapshot(tx) when is_number(tx) do
    %Snapshot{at: at} = Process.get(:blazie_lua_snapshot)

    at
    |> Map.new(fn {ledger, held} -> {ledger, min(held, trunc(tx))} end)
    |> Snapshot.reopen()
  end

  defp at_snapshot(_), do: Process.get(:blazie_lua_snapshot)

  # An id travels from Lua as a string or a number and is stored as it arrives.
  defp entity_id(id) when is_binary(id), do: id
  defp entity_id(id) when is_number(id), do: id
  defp entity_id(id), do: to_string(id)

  # ── the surface, written in Lua ────────────────────────────────────────────

  # Written in Lua rather than assembled from Erlang because it IS Lua: three
  # metatables and two loops. Building it through `set_table_keys` would be the
  # same code with every line turned inside out.
  @prelude """
  __held = {}

  function __entity(id, tx)
    local key = tostring(id) .. ':' .. tostring(tx or '')
    if __held[key] then return __held[key] end

    local e = { id = id, __entity = true }
    setmetatable(e, {
      __index = function(_, field)
        local value, is_ref = __read(id, field, tx)
        if is_ref then return __entity(value, tx) end
        return value
      end,
      __newindex = function(_, field, value)
        if type(value) == 'table' and rawget(value, '__entity') then
          __write(id, field, value.id, true)
        else
          __write(id, field, value, false)
        end
      end,
      __tostring = function() return tostring(id) end,
      -- `pairs(ada)` walks what is currently said about it. Lua 5.2's
      -- __pairs, which Luerl honours, so listing an entity's fields needs no
      -- vocabulary of its own.
      __pairs = function() return next, __fields(id, tx), nil end,
    })

    __held[key] = e
    return e
  end

  -- Any name that is not already a global is an entity. This is the whole of
  -- what makes `ada.height` work without a prefix.
  --
  -- Except the names this host deliberately removed. Without this, stripping
  -- `io` would turn it from absent into an empty entity called "io" — and a
  -- fence whose story is "there is nothing to reach" cannot have every name
  -- answer with a table. It would still fail on the call, but it would fail as
  -- a typo rather than as a wall, and the next binding mistake would hide here.
  setmetatable(_G, {
    __index = function(_, name)
      if __denied[name] then return nil end
      return __entity(name, nil)
    end
  })

  function each(spec, tx)
    local ids = __each(spec or {}, tx)
    local i = 0
    return function()
      i = i + 1
      if ids[i] ~= nil then return __entity(ids[i], tx) end
    end
  end

  -- The same world, read at an older transaction. Entities from it carry the
  -- transaction with them, so following an edge stays in the past.
  function at(tx)
    return setmetatable({}, {
      __index = function(_, name) return __entity(name, tx) end,
      __call  = function(_, spec) return each(spec, tx) end,
    })
  end
  """

  defp load_prelude(state) do
    denied =
      Blazie.Lua.removed()
      |> Enum.map_join("\n", &"__denied['#{&1}'] = true")

    {:ok, _, state} = :luerl.do("__denied = {}\n" <> denied <> "\n" <> @prelude, state)
    state
  end
end
