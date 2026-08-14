defmodule Blazie.Index do
  @moduledoc """
  Vector search, bought — the seam where an external index plugs in.

  Blazie does not build ANN. `Symbol.nearest/4` is an exact pass over a
  snapshot — correct, and measured at about a second per fifty thousand
  vectors, which is a reference implementation and not a search engine.
  Customer zero runs five embedding lanes over hundreds of thousands of
  items; the answer is a vendor, and this module is the shape of the plug:
  a provider behaviour the way `Model.Provider` is one, so a new engine is
  a module rather than a branch, and a vendor swap is a re-materialize.

  ## The index is derived, and disposable

  The symbols in the world remain the record. `job/3` is the maintaining
  job: it reads every symbol under an attribute and upserts what the index
  is missing — and because a job re-fires when what it read changes, a new
  symbol lands in the index the way a hint lands in a sweep, without
  anybody wiring a trigger. Kill the index, run the job, and the answers
  come back; nothing above this line ever treats the index as the truth.

  ## Roles, enforced at the seam

  Every space carries a role, declared once, because the Madem invariants
  are the ones socialite already paid to learn: a `query_only` space —
  measured at +0.039 over baseline — cannot tell two things apart, and
  letting it assert a similarity edge would invent a relationship. So
  `edge/4` refuses for a `query_only` space, a space with NO role refuses
  everything (unstated is not a role), and search itself is every role's
  right — querying is what `query_only` means.

  ## Vendors are not vocabulary

  A space is `potion_256`, never `turbopuffer_anything`. The vendor appears
  in exactly one place: the configured provider module and its options
  (`config :blazie, :index, {Blazie.Index.Turbopuffer, opts}`), and deleting
  that module touches no word, no attribute, and no space.
  """

  alias Blazie.{Attribute, Job, Snapshot, Symbol}

  @type refusal :: %{problem: atom(), repair: String.t()}
  @type hit :: {id :: term(), score :: float()}

  @doc "Put vectors into a space. Idempotent by id — an upsert, not an append."
  @callback upsert(opts :: keyword(), space :: String.t(), [{term(), [float()], map()}]) ::
              :ok | {:error, refusal()}

  @doc "The nearest `k` to a vector, optionally narrowed by metadata equality."
  @callback search(opts :: keyword(), space :: String.t(), [float()], pos_integer(), map()) ::
              {:ok, [hit()]} | {:error, refusal()}

  @doc "Destroy a space's index. The symbols in the world are untouched — that is the point."
  @callback drop(opts :: keyword(), space :: String.t()) :: :ok | {:error, refusal()}

  @doc "The attributes a space describes itself with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("role",
      answers: "name",
      one_of: ["retrieval", "similarity", "query_only"]
    )
  end

  @doc "The facts declaring a space and its role."
  @spec declare(String.t(), String.t()) :: [tuple()]
  def declare(space, role), do: [{space, "role", role}]

  @doc "A space's role, or nil — and nil refuses everything."
  @spec role(Snapshot.t(), String.t()) :: String.t() | nil
  def role(%Snapshot{} = snapshot, space), do: Snapshot.value(snapshot, space, "role")

  @doc """
  Search a space through the configured provider, role checked first.

  The filter is metadata equality — `%{"kind" => "video"}` — because that is
  the shape every real engine narrows by, and the maintaining job puts each
  symbol's declared metadata there.
  """
  @spec nearest(Snapshot.t(), String.t(), Symbol.t(), pos_integer(), map(), keyword()) ::
          {:ok, [hit()]} | {:error, refusal()}
  def nearest(%Snapshot{} = snapshot, space, %Symbol{} = query, k, filter \\ %{}, opts \\ []) do
    with :ok <- roled(snapshot, space),
         :ok <- same_space(space, query) do
      {module, provider_opts} = provider(opts)
      module.search(provider_opts, space, Symbol.numbers(query), k, filter)
    end
  end

  @doc """
  The facts asserting two things are alike — refused for a space whose role
  cannot say so.

  A `query_only` space answers "what might match this query" and nothing
  else; an edge written from it would be a relationship invented by a model
  that cannot tell two things apart. The refusal names the measured reason.
  """
  @spec edge(Snapshot.t(), String.t(), term(), term(), float()) ::
          {:ok, [tuple()]} | {:error, refusal()}
  def edge(%Snapshot{} = snapshot, space, a, b, score) do
    case role(snapshot, space) do
      "query_only" ->
        {:error,
         %{
           problem: :role_refuses,
           repair:
             "#{inspect(space)} is query_only: it can rank candidates for a query and cannot " <>
               "tell two things apart, so an edge from it would invent a relationship. " <>
               "Assert edges from a space whose role is `similarity`."
         }}

      nil ->
        {:error, unroled(space)}

      _role ->
        {:ok, [{a, "alike", %{"with" => b, "space" => space, "score" => score}}]}
    end
  end

  @doc """
  The maintaining job: everything under `attribute` upserted into its space.

  Reads the symbols through the snapshot — so the job's read set covers
  them, and a new symbol makes the job due the way a hint makes a sweep due.
  Metadata for filtering comes from `meta:` — attributes copied beside each
  vector.
  """
  @spec job(term(), String.t(), keyword()) :: Job.t()
  def job(id, attribute, opts \\ []) do
    meta = Keyword.get(opts, :meta, [])
    {module, provider_opts} = provider(opts)

    Job.new(id, fn snapshot ->
      rows =
        snapshot
        |> Snapshot.find(attribute: attribute)
        |> Enum.flat_map(fn fact ->
          case fact.value do
            %Symbol{} = symbol ->
              metadata =
                Map.new(meta, fn field -> {field, Snapshot.value(snapshot, fact.id, field)} end)

              [{fact.id, symbol, metadata}]

            _other ->
              []
          end
        end)

      case rows do
        [] ->
          []

        [{_id, %Symbol{space: space}, _meta} | _rest] = rows ->
          :ok =
            module.upsert(
              provider_opts,
              space,
              Enum.map(rows, fn {id, symbol, metadata} ->
                {id, Symbol.numbers(symbol), metadata}
              end)
            )

          [{id, "indexed", length(rows)}]
      end
    end)
  end

  @doc "The attributes the maintaining job reports with."
  @spec job_seed() :: [tuple()]
  def job_seed, do: Attribute.define("indexed", answers: "integer", cardinality: "many")

  defp provider(opts) do
    Keyword.get(opts, :provider) ||
      Application.get_env(:blazie, :index) ||
      raise "No index provider configured. Set `config :blazie, :index, {module, opts}` — " <>
              "Blazie.Index.Exact for a node-local index, or a vendor module."
  end

  defp roled(snapshot, space) do
    case role(snapshot, space) do
      nil -> {:error, unroled(space)}
      _role -> :ok
    end
  end

  defp same_space(space, %Symbol{space: space}), do: :ok

  defp same_space(space, %Symbol{space: other}) do
    {:error,
     %{
       problem: :not_comparable,
       repair:
         "The query lives in #{inspect(other)} and this index is #{inspect(space)}. Vectors " <>
           "from different spaces compare into plausible nonsense, so they do not compare."
     }}
  end

  defp unroled(space) do
    %{
      problem: :no_role,
      repair:
        "#{inspect(space)} declares no role. Every space says what its vectors may be used " <>
          "for — retrieval, similarity, or query_only — because a use nobody stated is a use " <>
          "nobody measured. Declare it: Index.declare(#{inspect(space)}, \"retrieval\")."
    }
  end
end

defmodule Blazie.Index.Exact do
  @moduledoc """
  The node-local index: exact cosine over whatever was upserted.

  The reference implementation and the honest default — every score it
  answers is the true score, so it is also what a vendor's recall is
  measured AGAINST. Rows live in an ETS table per space, owned by a small
  holder process rather than by whoever upserts — the first version let the
  upserter own it, and the maintaining job upserts from a task that ends,
  so every index died the moment it was built. Derived and disposable still
  holds: `drop/2` deletes the table, and nothing above ever treats it as
  the record.
  """

  @behaviour Blazie.Index

  alias Blazie.Symbol

  @impl true
  def upsert(opts, space, rows) do
    table = table(opts, space)

    for {id, vector, meta} <- rows do
      :ets.insert(table, {id, Symbol.new(space, vector), meta})
    end

    :ok
  end

  @impl true
  def search(opts, space, vector, k, filter) do
    query = Symbol.new(space, vector)

    hits =
      table(opts, space)
      |> :ets.tab2list()
      |> Enum.filter(fn {_id, _symbol, meta} -> matches?(meta, filter) end)
      |> Enum.map(fn {id, symbol, _meta} ->
        {:ok, score} = Symbol.near(query, symbol)
        {id, score}
      end)
      |> Enum.sort_by(fn {_id, score} -> -score end)
      |> Enum.take(k)

    {:ok, hits}
  end

  @impl true
  def drop(opts, space) do
    case :ets.whereis(name(opts, space)) do
      :undefined -> :ok
      table -> :ets.delete(table) && :ok
    end
  end

  defp matches?(meta, filter) do
    Enum.all?(filter, fn {key, value} -> Map.get(meta, key) == value end)
  end

  defp table(opts, space) do
    name = name(opts, space)

    case :ets.whereis(name) do
      :undefined -> Agent.get(holder(), fn _ -> :ets.new(name, [:named_table, :set, :public]) end)
      table -> table
    end
  end

  # The tables' owner: one unlinked process for the node, alive until the
  # node is not. Created inside the Agent so the AGENT owns them, whoever
  # asked first.
  defp holder do
    case Process.whereis(__MODULE__.Holder) do
      nil ->
        case Agent.start(fn -> :ok end, name: __MODULE__.Holder) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  defp name(opts, space) do
    :"blazie_index_#{Keyword.get(opts, :prefix, "")}#{space}"
  end
end
