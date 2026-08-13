defmodule Blazie.Lua.Binding do
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
  the host — a guest never touches a world. That is what lets one path serve
  both a formula, whose writes are its answer, and a job, whose writes are
  appended after it returns.

  ## Fields declare themselves

  A write to an undeclared field declares it, inferring what it answers from
  what was assigned. The vocabulary is real and still checked; it is just no
  longer something a person has to write down first. Before this, the first
  write into a fresh world was refused until somebody defined an attribute by
  hand — correct, and an absurd thing to ask of someone whose whole interface is
  `ada.height = 180`.

  ## The cost of bare names

  `_G` carries a metatable, so any name that is not already a global is an
  entity. That is what buys `ada.height` instead of `db.ada.height`, and the
  price is that a typo is an empty entity rather than an error. It is a real
  cost, taken deliberately: the surface is meant to read like Lua, and a prefix
  on every line is a tax paid by every reader forever to catch a typo once.
  """

  alias Blazie.{Attribute, Blob, Snapshot, Symbol}

  @typedoc "An assertion a guest staged: id, field, value."
  @type assertion :: {term(), String.t(), term()}

  # Staged writes live in the guest's own process dictionary. Each guest runs in
  # a process of its own that is killed on deadline or heap limit, so this is
  # already scoped to exactly one run and dies with it — an Agent or an ETS
  # table would be a second thing to clean up on a path whose whole point is
  # that it can be killed at any moment.
  @staged :blazie_lua_staged

  # Where `each` parks the ids it matched, for the same reason and with the same
  # lifetime: one key per open cursor, in a dictionary that dies with the run.
  @cursors :blazie_lua_cursor

  # How far each cursor has walked, which is what decides when to sweep.
  @swept :blazie_lua_swept

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
    case watching(source, snapshot, opts) do
      {:ok, value, staged, _read} -> {:ok, value, staged}
      error -> error
    end
  end

  @doc """
  The same run, plus what it read.

  A subscription needs the read set and nothing else does: what a chunk read is
  what makes its answer stale, and it is the only thing that can decide when to
  run it again. Kept separate so the common path is not carrying a value only
  one caller wants.
  """
  @spec watching(binary(), Snapshot.t(), keyword()) ::
          {:ok, term(), [assertion()], [keyword()]} | {:error, map()}
  def watching(source, %Snapshot{} = snapshot, opts \\ []) do
    Blazie.Lua.collect(source, Keyword.put(opts, :snapshot, snapshot))
  end

  # ── the bridge ─────────────────────────────────────────────────────────────

  defp bind_functions(state) do
    [
      {"__read", &read/2},
      {"__write", &write/2},
      {"__each", &each/2},
      {"__next", &next_id/2},
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
      nil ->
        {[nil, false], state}

      %Blob{} = blob ->
        as_table(blob, state)

      %Symbol{} = symbol ->
        as_table(symbol, state)

      value ->
        {[value, reference?(snapshot, to_string(field))], state}
    end
  end

  defp read(_args, state), do: {[nil, false], state}

  defp as_table(struct, state) do
    {encoded, state} = :luerl.encode(shown(struct), state)
    {[encoded, false], state}
  end

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
      # world describing a field that never held anything.
      is_nil(value) and not known? ->
        {[], state}

      true ->
        declaration =
          if known?,
            do: [],
            else: Attribute.define(field, answers: answers_for(value, reference?))

        stage(declaration ++ [{entity_id(id), field, value}])
        {[], state}
    end
  end

  defp write(_args, state), do: {[], state}

  # The matching ids stay here, in Erlang, and the guest is handed a number to
  # pull them through one at a time.
  #
  # They used to be encoded into a Lua table, which is the obvious thing to do
  # and put a hard ceiling on how big a world could be looked at: a table of
  # 12,400 ids exceeded the heap limit, so counting a world was refused for
  # being too large to count. An Erlang list of the same ids is a fraction of
  # the size and is never copied — the guest process owns it already.
  #
  # A cursor nobody drains to the end is left behind, and that is fine for the
  # same reason staged writes are: this dictionary belongs to one guest process
  # which is killed on deadline or heap limit, so it cannot outlive the run.
  defp each([spec | rest], state) do
    snapshot = at_snapshot(List.first(rest))
    wanted = :luerl.decode(spec, state)

    # Ids, then filter — rather than facts, filter, then ids. Three things
    # follow. The world hands back one id per entity instead of every fact it
    # holds; the remaining constraints are checked once per entity rather than
    # once per fact about it, which for an entity holding twenty fields was
    # nineteen repetitions of the same answer; and the order arrives already
    # decided, so nothing here sorts.
    ids =
      snapshot
      |> Snapshot.ids(narrowest(wanted))
      |> Enum.filter(&matches_all?(&1, wanted, snapshot))

    cursor = System.unique_integer([:positive])
    Process.put({@cursors, cursor}, ids)
    {[cursor], state}
  end

  defp each(_args, state), do: {[nil], state}

  # One id, or nil at the end. Ids are strings and numbers, never nil, so nil is
  # unambiguously "no more" and the loop needs no separate done flag.
  #
  # Every `@sweep` ids this collects the Lua heap, and that is what removes the
  # ceiling rather than merely raising it. Luerl has no automatic collector: a
  # table lives in the interpreter state until something sweeps, so a loop that
  # touches an entity per iteration grows by the size of the world even when it
  # keeps nothing. Measured plainly — fifty thousand tables built and discarded,
  # holding none of them, still exhausted the heap.
  #
  # Walking a world is exactly the operation that makes tables in proportion to
  # the data, and this is the one point inside that walk where the host holds
  # the state, so it is the only place a sweep can go. It is a real mark and
  # sweep from the globals, the stack and the call stack, which is why entities
  # a chunk is still holding survive it: `collectgarbage` in Luerl's own basic
  # library is this call from this position.
  defp next_id([cursor | _rest], state) when is_number(cursor) do
    key = {@cursors, trunc(cursor)}

    case Process.get(key) do
      [id | rest] ->
        Process.put(key, rest)
        {[id], sweep(key, state)}

      _ ->
        Process.delete(key)
        Process.delete({@swept, key})
        {[nil], state}
    end
  end

  defp next_id(_args, state), do: {[nil], state}

  # Often enough that memory stays flat over a large world, rarely enough that
  # the cost is not paid by a chunk reading ten entities. A sweep is proportional
  # to what is LIVE, so a loop holding nothing sweeps almost nothing.
  @sweep 1_000

  defp sweep(key, state) do
    seen = Process.get({@swept, key}, 0) + 1
    Process.put({@swept, key}, seen)

    if rem(seen, @sweep) == 0, do: :luerl.gc(state), else: state
  end

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
          value -> [{field, shown(value)} | acc]
        end
      end)
      |> Enum.reverse()

    {encoded, state} = :luerl.encode(held, state)
    {[encoded], state}
  end

  defp fields(_args, state), do: {[nil], state}

  # A blob and a symbol are structs, and a guest has no way to hold one. Both
  # become plain tables, which is the only shape Lua has — so `ada.avatar.bytes`
  # works without the guest knowing what a struct is.
  #
  # One function, because there are two ways a value reaches a guest — reading a
  # field, and listing an entity's fields — and only the first knew about
  # structs. So `ada.vec` gave you a space and a dimension while `pairs(ada)`
  # gave you a symbol's packed float64s, which are not text and not JSON. A world
  # holding embeddings answered a page that only wanted to list its rows with
  # `Jason.EncodeError: invalid byte 0xE0`, surfacing as a bare 500.
  #
  # A symbol's numbers are deliberately not among what comes back. You do not
  # read a symbol, you compare it; handing 768 floats to a guest that cannot do
  # anything with them is a megabyte spent to display noise.
  defp shown(%Blob{} = blob) do
    [
      {"key", blob.key},
      {"hash", blob.hash},
      {"bytes", blob.bytes},
      {"media_type", blob.media_type}
    ]
  end

  defp shown(%Symbol{} = symbol) do
    [{"space", symbol.space}, {"dimensions", Symbol.dimension(symbol)}]
  end

  defp shown(value), do: value

  # ── deciding what a value is ───────────────────────────────────────────────

  # Which constraint to hand the world, so it can use an index instead of
  # returning everything for this to filter.
  #
  # A world indexes by id, by attribute, and by value, so an exact value is the
  # narrowest thing there is to ask for and a bare field is the next. Asking for
  # everything and filtering here read the whole world for a query that matched
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
      # An empty spec is everyone, and everyone is the whole world.
      true -> []
    end
  end

  # `true` in a spec means "has this field at all", which is the difference
  # between asking who is 18 and asking who has an age.
  defp matches_all?(id, wanted, snapshot) do
    Enum.all?(wanted, fn {field, want} ->
      held = Snapshot.value(snapshot, id, to_string(field))

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

  defp stage(assertions),
    do: Process.put(@staged, Enum.reverse(assertions) ++ Process.get(@staged, []))

  defp at_snapshot(nil), do: Process.get(:blazie_lua_snapshot)

  # `at(42)` reads "no later than 42". With one world that is exactly what it
  # says; with several it caps each, because a single number cannot name a
  # position in more than one sequence and capping is the reading that never
  # invents a transaction a world never had.
  defp at_snapshot(tx) when is_number(tx) do
    %Snapshot{at: at} = Process.get(:blazie_lua_snapshot)

    at
    |> Map.new(fn {world, held} -> {world, min(held, trunc(tx))} end)
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
  -- One metatable per transaction, shared by every entity read at it — so the
  -- usual run has exactly one and `at(42)` adds a second.
  --
  -- Every entity used to carry its own, holding four closures over its id. That
  -- is the natural way to write it and it costs the size of the world: looking
  -- at 12,400 entities built 12,400 metatables and 49,600 closures, which is
  -- what put a ceiling on how large a world could be looked at. The id comes off
  -- the table with `rawget` instead, and the only thing left worth closing over
  -- is the transaction — which is shared, because that is what the key is.
  __metas = {}

  function __meta(tx)
    local key = tostring(tx or '')
    if __metas[key] then return __metas[key] end

    local m = {
      __index = function(e, field)
        local value, is_ref = __read(rawget(e, 'id'), field, tx)
        if is_ref then return __entity(value, tx) end
        return value
      end,
      __newindex = function(e, field, value)
        if type(value) == 'table' and rawget(value, '__entity') then
          __write(rawget(e, 'id'), field, value.id, true)
        else
          __write(rawget(e, 'id'), field, value, false)
        end
      end,
      __tostring = function(e) return tostring(rawget(e, 'id')) end,
      -- `pairs(ada)` walks what is currently said about it. Lua 5.2's
      -- __pairs, which Luerl honours, so listing an entity's fields needs no
      -- vocabulary of its own.
      __pairs = function(e) return next, __fields(rawget(e, 'id'), tx), nil end,
      -- Two entity tables are the same entity when they name the same one at the
      -- same transaction, and the metatable IS the transaction — so comparing
      -- metatables is what keeps `ada == at(5).ada` false.
      --
      -- This used to be true by construction: every entity was cached and handed
      -- back, so `ada` was always literally the same table. That cache is what
      -- made a walk over a large world hold a table per entity alive to the end
      -- of the run. Saying what equality means directly costs one metamethod and
      -- lets every entity be collected the moment the loop moves on.
      __eq = function(a, b)
        return getmetatable(a) == getmetatable(b) and rawget(a, 'id') == rawget(b, 'id')
      end,
    }

    __metas[key] = m
    return m
  end

  function __entity(id, tx)
    return setmetatable({ id = id, __entity = true }, __meta(tx))
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

  -- A cursor, not a list. The ids stay in the host and arrive one at a time, so
  -- iterating a world costs what one entity costs rather than what the world
  -- does.
  function each(spec, tx)
    local cursor = __each(spec or {}, tx)
    return function()
      local id = __next(cursor)
      if id ~= nil then return __entity(id, tx) end
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
