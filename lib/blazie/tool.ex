defmodule Blazie.Tool do
  @moduledoc """
  Something a model may ask to have run, which is a job.

  Not a new word and not a new kind of thing. A tool reaches outside — that is
  what makes it useful — and a job is already the only thing handed the outside
  world. So a tool is a declared job with two extra attributes: what it is for,
  and what it takes.

      {"lookup", "is", "job"}
      {"lookup", "describe", "Look up a customer's plan by their id."}
      {"lookup", "takes", %{"customer" => %{"answers" => "name"}}}
      {"lookup", "source", "answer.plan = customers[args.customer].plan"}

  ## The fence puts it where it goes without anybody deciding

  A formula cannot hold a tool, because a formula has no network and a tool that
  could not reach would not be one. That is not a rule enforced here; it is that
  there is nothing in a formula's world to reach with. So "which of these may
  call out" was answered before tools existed.

  ## What a run is allowed to spend

  A model that calls a tool, reads the result, and calls it again is a loop with
  no natural end. `calls_allowed` caps it, sitting beside `fuel` and
  `memory_bytes` — a limit declared as a fact, refusable, and readable
  afterwards.

  ## Every call is a fact

  A call and its result are written, so a trace is a query rather than a log
  somebody remembered to keep. That is the same reason `satisfied` is a fact:
  the question "what did this agent actually do" should be answerable in the
  language the data is already in.
  """

  alias Blazie.{Job, Snapshot}

  @type t :: %{name: String.t(), describe: String.t(), takes: keyword()}

  @calls_allowed 4

  @doc "The attributes a tool is declared with."
  @spec seed() :: [tuple()]
  def seed do
    Blazie.Attribute.define("describe", answers: "any") ++
      Blazie.Attribute.define("takes", answers: "any") ++
      Blazie.Attribute.define("may_use", answers: "name", cardinality: "many") ++
      Blazie.Attribute.define("calls_allowed", answers: "integer") ++
      Blazie.Attribute.define("called", answers: "any", cardinality: "many")
  end

  @doc """
  Declare a tool.

      declare("lookup", describe: "Look up a customer's plan.",
        takes: [customer: [answers: "name"]],
        source: "answer.plan = 'pro'")
  """
  @spec declare(String.t(), keyword()) :: [tuple()]
  def declare(id, opts) do
    [
      {id, "is", "job"},
      {id, "describe", Keyword.fetch!(opts, :describe)},
      {id, "takes", encode_takes(Keyword.get(opts, :takes, []))},
      {id, "source", Keyword.fetch!(opts, :source)}
    ]
  end

  @doc "The tools one field may use, as a model needs to see them."
  @spec available(Snapshot.t(), String.t()) :: [t()]
  def available(%Snapshot{} = snapshot, field) do
    snapshot
    |> Snapshot.find(id: field, attribute: "may_use")
    |> Enum.map(& &1.value)
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case Snapshot.value(snapshot, name, "describe") do
        nil ->
          []

        describe ->
          [%{name: to_string(name), describe: describe, takes: decode_takes(snapshot, name)}]
      end
    end)
  end

  @doc "How many calls one run may make."
  @spec calls_allowed(Snapshot.t(), String.t()) :: pos_integer()
  def calls_allowed(%Snapshot{} = snapshot, field) do
    case Snapshot.value(snapshot, field, "calls_allowed") do
      n when is_integer(n) and n > 0 -> n
      _ -> @calls_allowed
    end
  end

  @doc """
  Run one call, and hand back what it answered.

  The tool's Lua runs in the job world with its arguments bound to `args` and a
  table called `answer` to fill in. Whatever it puts there is what the model is
  told — the guest never writes to the world directly from here, because a tool
  that could would be writing before anybody had decided the answer was good.
  """
  @spec run(Snapshot.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(%Snapshot{} = snapshot, call, opts \\ []) do
    case Snapshot.value(snapshot, call.name, "source") do
      nil ->
        {:error, %{problem: :no_such_tool, repair: "#{call.name} is declared with no source."}}

      source ->
        prelude = "args = " <> lua(call.arguments) <> "\nanswer = {}\n"

        case Blazie.Lua.Binding.run(prelude <> source <> "\nreturn answer", snapshot,
               as: :job,
               at: System.system_time(:second),
               deadline: Keyword.get(opts, :deadline, 15_000)
             ) do
          {:ok, answered, _staged} when is_map(answered) -> {:ok, answered}
          {:ok, answered, _staged} -> {:ok, %{"answer" => answered}}
          {:error, refusal} -> {:error, refusal}
        end
    end
  end

  @doc "The fact recording that a call happened and what it said."
  @spec called(term(), map(), term(), term()) :: tuple()
  def called(id, call, result, by) do
    {id, "called", %{"tool" => call.name, "arguments" => call.arguments, "answered" => result}, by}
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp encode_takes(takes) do
    Map.new(takes, fn {name, spec} ->
      {to_string(name), Map.new(spec, fn {k, v} -> {to_string(k), v} end)}
    end)
  end

  defp decode_takes(snapshot, name) do
    case Snapshot.value(snapshot, name, "takes") do
      takes when is_map(takes) ->
        for {field, spec} <- takes do
          {String.to_atom(field), [answers: Map.get(spec, "answers", "any")]}
        end

      _ ->
        []
    end
  end

  # Arguments come from a model, so they are encoded rather than interpolated.
  # A tool whose argument could close a string literal and append Lua would be
  # the whole fence undone by a quote mark.
  defp lua(value) when is_map(value) do
    "{" <>
      Enum.map_join(value, ", ", fn {k, v} -> "[#{lua(to_string(k))}] = #{lua(v)}" end) <> "}"
  end

  defp lua(value) when is_list(value), do: "{" <> Enum.map_join(value, ", ", &lua/1) <> "}"
  defp lua(value) when is_number(value), do: to_string(value)
  defp lua(value) when is_boolean(value), do: to_string(value)
  defp lua(nil), do: "nil"

  defp lua(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")
      |> String.replace("\n", "\\n")

    "'" <> escaped <> "'"
  end

  defp lua(value), do: lua(inspect(value))

  @doc false
  def default_calls_allowed, do: @calls_allowed

  @doc false
  def job_ids(%Snapshot{} = snapshot) do
    snapshot |> Snapshot.find(attribute: "is", value: "job") |> Enum.map(& &1.id) |> Enum.uniq()
  end

  @doc false
  def declared?(%Snapshot{} = snapshot, name), do: name in Enum.map(job_ids(snapshot), &to_string/1)

  @doc false
  def as_job(%Snapshot{} = snapshot, name) do
    case Snapshot.value(snapshot, name, "source") do
      source when is_binary(source) -> {:ok, Job.of_source(name, source)}
      _ -> :error
    end
  end
end
