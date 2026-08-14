defmodule Blazie.Run do
  @moduledoc """
  One execution of the loop, and the trajectory it leaves behind (run).

  `Model.converse/5` already writes every turn under an id when given `into:`
  and `by:`. This is that id treated as a thing: something that can be resumed,
  forked and asked questions of, rather than a diary nobody reads back.

  ## Resuming is reading, not restoring

  There is no session store, no serialised context and nothing to rehydrate. A
  run's turns are facts in a world, ordered by the transaction that wrote them,
  so continuing one is a query — `messages/2` reads them back into exactly the
  shape `converse/5` takes as a prompt. A cluster that restarts mid-run loses
  the process and not the run, because the process was never where the run was.

  That is the whole of "a run survives a deploy", and it is why it needs no
  machinery: this repo already knows how to not lose facts.

  With one condition worth saying out loud, because measuring it is what turned
  it up: the world has to be one that survives. `World.default_store/0` answers
  `Store.Memory` unless `:ledger_dir` is set, and a run in a memory world dies
  with the node exactly as everything else in it does. Run twice in two VMs
  without it and nothing comes back — which is not a defect in a run, and is
  indistinguishable from one if nobody says so first.

  ## Forking is free, and both branches stay true

  A fork opens the parent's snapshot at a transaction and continues under a new
  id. Nothing is copied and nothing is overwritten, so the parent still answers
  what it always answered — the two branches are not two versions of one run,
  they are two runs that share a beginning.

  Prime Intellect's harness does this by moving a leaf pointer in an append-only
  JSONL file, which is the same idea reached by building a file format. Here the
  database already is one.

  ## Long horizon: the context is assembled, never accumulated

  Mellea's position, which this tree arrived at from the other direction: the
  context is per call, built fresh, and the durable thing is the record rather
  than a buffer. Our own harness puts it plainly — "a call expressed as a frozen
  spec plus a fresh context has almost nothing to persist, so a run that dies
  mid-flight loses one call, not a conversation."

  `messages/3` is that assembly, and it takes a policy. Which is the whole of
  long-horizon context management here: what to include is a decision made
  fresh each time against facts that are all still there, not a buffer somebody
  has to prune before it overflows.

  So a run has no length limit. What it has is an assembly that stays the size
  the policy says, however long the run gets.

  ## Recency is not relevance, so the assembly also retrieves

  A window on the end is the wrong shape for the one thing long runs are for:
  a fact established in turn three is exactly what the model needs again in
  turn forty, and by then it lives only in a summary's lossy account. Every
  real harness has an answer to this — retrieval, not a bigger window — and
  `recalled/4` is this one's: the turns outside the window, scored against
  what the run is doing now, the best of them brought back whole.

  The scoring is lexical, and deliberately so. This node has no embedding
  index — vectors are a thing bought, not built, the same judgement as every
  other vendor — and the seam a better scorer would plug into is exactly that
  one function: same question in, same shape out. What matters is not the
  scorer but the property the fact log already paid for: retrieval is a QUERY
  over originals that were never thrown away, not a memory store somebody had
  to maintain beside the run.

  ## Compaction adds, it does not replace

  A long run's early turns get summarised so the context stays affordable. The
  summary is a NEW fact; the turns it summarises are untouched and still
  readable. Compaction that deleted what it summarised would be the one
  irreversible operation in a database whose whole claim is that corrections are
  later facts — and the summary is generated, so it is exactly the kind of thing
  somebody will later want to check against the original.
  """

  alias Blazie.{Attribute, Snapshot, World}

  @is "is"

  @doc "The attributes a run is written with."
  @spec seed() :: [tuple()]
  def seed do
    Attribute.define("began", answers: "integer") ++
      Attribute.define("ended", answers: "integer") ++
      Attribute.define("forked_from", answers: "name") ++
      Attribute.define("forked_at", answers: "any") ++
      Attribute.define("summary", answers: "any", cardinality: "many") ++
      Attribute.define("summarised_to", answers: "integer")
  end

  @doc """
  Start a run.

  Nothing else has to happen for turns to land under it — `converse/5` writes
  them wherever it is told. This records that the run BEGAN, which is what makes
  "a run that never got anywhere" distinguishable from "a run that never was".
  """
  @spec begin(World.ref(), term(), integer()) :: {:ok, pos_integer()} | {:error, term()}
  def begin(world, id, now \\ System.system_time(:second)) do
    World.append(world, [{id, @is, "run", id}, {id, "began", now, id}])
  end

  @doc "Mark a run finished. A run with no `ended` is one that stopped rather than ended."
  @spec finish(World.ref(), term(), integer()) :: {:ok, pos_integer()} | {:error, term()}
  def finish(world, id, now \\ System.system_time(:second)) do
    World.append(world, [{id, "ended", now, id}])
  end

  @doc """
  The turns of a run, oldest first.

  Read from the facts rather than from anything held in memory, which is what
  makes this survive the process that wrote them.
  """
  @spec turns(Snapshot.t(), term()) :: [%{asked: String.t(), answered: String.t()}]
  def turns(%Snapshot{} = snapshot, id) do
    asked = ordered(snapshot, id, "asked")
    answered = ordered(snapshot, id, "answered")

    # Zipped by position: a turn is one ask and the answer that followed it, and
    # they are written in the same transaction, so the nth of each belong
    # together. A turn whose answer is missing is one that failed mid-flight and
    # is dropped rather than paired with somebody else's answer.
    Enum.zip_with(asked, answered, fn one, two -> %{asked: one, answered: two} end)
  end

  defp ordered(snapshot, id, attribute) do
    snapshot
    |> Snapshot.find(id: id, attribute: attribute)
    |> Enum.map(& &1.value)
  end

  @doc """
  A run's turns as messages, ready to hand back to `converse/5`.

  `converse/5` takes either a prompt or a list of messages, so resuming is
  passing this where the prompt would go. Compacted turns come back as their
  summary instead, which is the whole point of having compacted them.

  `about:` is what the run is doing now. Given, the turns outside the window
  are searched and the most relevant come back whole, between the summaries
  and the verbatim end — `recall:` says how many (three unless told). Absent,
  the assembly is summaries and the window, which is right for a run short
  enough that nothing has fallen out of view yet.
  """
  @spec messages(Snapshot.t(), term(), keyword()) :: [map()]
  def messages(%Snapshot{} = snapshot, id, opts \\ []) do
    kept = Snapshot.value(snapshot, id, "summarised_to") || 0
    all = turns(snapshot, id)

    # A window on the end, after whatever was summarised. `keep:` is the policy:
    # the last N turns verbatim, everything before them represented by their
    # summaries. Absent, everything unsummarised comes back, which is right for
    # a short run and is what a long one grows out of.
    within =
      case Keyword.get(opts, :keep) do
        nil -> Enum.drop(all, kept)
        n -> all |> Enum.drop(kept) |> Enum.take(-n)
      end

    summaries =
      case ordered(snapshot, id, "summary") do
        [] -> []
        said -> [%{"role" => "user", "content" => "Earlier: " <> Enum.join(said, " ")}]
      end

    remembered =
      case Keyword.get(opts, :about) do
        nil ->
          []

        about ->
          snapshot
          |> recalled(id, about,
            recall: Keyword.get(opts, :recall, 3),
            outside: length(within)
          )
          |> Enum.map(fn one ->
            %{
              "role" => "user",
              "content" =>
                "Recalled from earlier in this run, because it is about what you are doing:\n" <>
                  "asked: #{clipped(one.asked)}\nanswered: #{clipped(one.answered)}"
            }
          end)
      end

    summaries ++
      remembered ++
      Enum.flat_map(within, fn turn ->
        [
          %{"role" => "user", "content" => to_string(turn.asked)},
          %{"role" => "assistant", "content" => to_string(turn.answered)}
        ]
      end)
  end

  @doc """
  The turns most about something, from anywhere in the run.

  Scored by the words they share with `about`, best first — then answered in
  the order they happened, because a model reads them as history. Turns the
  caller is already sending verbatim are excluded with `outside:` (how many at
  the end are spoken for), so recall reaches exactly the part of the run that
  is otherwise a summary or nothing.

  Lexical, and honestly so: a turn that says the thing in different words will
  be missed. That is the known cost of not owning an embedding index, and the
  repair when it matters is a better scorer behind the same function — not a
  memory store beside the run.
  """
  @spec recalled(Snapshot.t(), term(), String.t(), keyword()) ::
          [%{turn: pos_integer(), asked: term(), answered: term()}]
  def recalled(%Snapshot{} = snapshot, id, about, opts \\ []) do
    count = Keyword.get(opts, :recall, 3)
    outside = Keyword.get(opts, :outside, 0)

    all = turns(snapshot, id)
    pool = if outside > 0, do: Enum.drop(all, -outside), else: all
    wanted = terms(about)

    if count <= 0 or MapSet.size(wanted) == 0 do
      []
    else
      pool
      |> Enum.with_index(1)
      |> Enum.map(fn {turn, at} ->
        {turn, at, MapSet.size(MapSet.intersection(wanted, terms("#{turn.asked} #{turn.answered}")))}
      end)
      |> Enum.filter(fn {_turn, _at, score} -> score > 0 end)
      # Best first to choose, later-first to break ties — of two equally
      # relevant turns the newer is likelier still true.
      |> Enum.sort_by(fn {_turn, at, score} -> {-score, -at} end)
      |> Enum.take(count)
      |> Enum.sort_by(fn {_turn, at, _score} -> at end)
      |> Enum.map(fn {turn, at, _score} -> %{turn: at, asked: turn.asked, answered: turn.answered} end)
    end
  end

  defp terms(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(byte_size(&1) < 3))
    |> MapSet.new()
  end

  # A recalled turn comes back whole unless whole is enormous — an answer that
  # carries a file would otherwise spend the window the recall exists to save.
  defp clipped(text) do
    text = to_string(text)
    if String.length(text) > 2_000, do: String.slice(text, 0, 2_000) <> " …", else: text
  end

  @doc """
  How many turns are not yet summarised.

  What a caller checks to decide whether to compact — the thing that grows, as
  against the thing that was already dealt with.
  """
  @spec outstanding(Snapshot.t(), term()) :: non_neg_integer()
  def outstanding(%Snapshot{} = snapshot, id) do
    length(turns(snapshot, id)) - (Snapshot.value(snapshot, id, "summarised_to") || 0)
  end

  @doc """
  Summarise everything but the last `keep:` turns, using a model.

  The summary is generated, so it is written as a fact like any other generated
  thing and the turns it covers stay exactly where they were. What this buys is
  an assembly that stops growing; what it costs is that a summary is a lossy
  account, which is why the originals are still readable and why nothing here
  deletes them.

  Answers `{:ok, count}` with how many turns are now covered, or `:enough` when
  there is nothing worth compacting yet.
  """
  @spec compact_with(World.ref(), term(), Snapshot.t(), keyword()) ::
          {:ok, non_neg_integer()} | :enough | {:error, term()}
  def compact_with(world, id, %Snapshot{} = snapshot, opts) do
    keep = Keyword.get(opts, :keep, 6)
    model = Keyword.fetch!(opts, :asks)
    all = turns(snapshot, id)
    already = Snapshot.value(snapshot, id, "summarised_to") || 0
    upto = length(all) - keep

    if upto <= already do
      :enough
    else
      folding = all |> Enum.drop(already) |> Enum.take(upto - already)

      asked = """
      Summarise what happened in these steps of a working session, for somebody
      who will carry on from where they left off. Say what was done, what was
      learned, and anything still outstanding. Be brief and concrete.

      #{Enum.map_join(folding, "\n", fn t -> "- asked: #{t.asked}\n  answered: #{t.answered}" end)}
      """

      # Through `converse/5` with no tools rather than `generate/3`, because
      # that is the path with a seam a test can drive — and a summary is just an
      # answer with nothing to call.
      case Blazie.Model.converse(
             model,
             asked,
             [],
             fn _ -> {:ok, %{}} end,
             Keyword.take(opts, [:provider, :timeout])
           ) do
        {:ok, said, _made} ->
          {:ok, _tx} = compact(world, id, upto, said)
          {:ok, upto}

        {:error, refusal} ->
          {:error, refusal}
      end
    end
  end

  @doc """
  Continue a run under a new id, from where it had got to.

  The child records what it came from and at which name, so "where did this
  branch diverge" is a query rather than something somebody has to remember.
  Nothing is copied: the child reads the parent's turns through the snapshot it
  was forked at, and the parent goes on answering what it always answered.
  """
  @spec fork(World.ref(), term(), term(), Snapshot.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def fork(world, child, parent, %Snapshot{} = snapshot) do
    World.append(world, [
      {child, @is, "run", child},
      {child, "began", System.system_time(:second), child},
      {child, "forked_from", to_string(parent), child},
      {child, "forked_at", Snapshot.name(snapshot), child}
    ])
  end

  @doc """
  Summarise the first `count` turns of a run, keeping them.

  The summary is written and the turns are not touched. `messages/2` then skips
  what was summarised and leads with the summary instead, so the context shrinks
  and the record does not.
  """
  @spec compact(World.ref(), term(), non_neg_integer(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def compact(world, id, count, summary) do
    World.append(world, [
      {id, "summary", summary, id},
      {id, "summarised_to", count, id}
    ])
  end

  @doc "Every run in this snapshot, by id."
  @spec all(Snapshot.t()) :: [term()]
  def all(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find(attribute: @is, value: "run")
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end
end
