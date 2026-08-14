defmodule Blazie.Model do
  @moduledoc """
  Calling a model, which is the one thing blazie could not do without help.

  Everything an agent needs was already here — memory is facts in a world,
  attention is a job's read set, waking is `Job.due?` staleness, hands are a
  sandbox, conscience is a requirement, and the record of what it did is `by` on
  every fact it wrote. What was missing was narrow and unglamorous: an HTTP
  request to somebody's inference endpoint.

  This was briefly its own library. It is not one — it reads snapshots, writes
  facts and leans on `Job`, `Symbol` and `Attribute`, so it could never be used
  without blazie, and a second name for something that ships in the same tree
  with the same tests and the same deploy is a name that buys nothing.

  ## Why there is no client dependency

  `req_llm` is the right shape and the wrong ownership. Twenty-one providers is
  twenty-one ways for somebody else's release to change what a job answers, and
  a model call is the one place in this tree where a silent behaviour change is
  indistinguishable from the model itself drifting. The tree already signs SigV4
  by hand and parses GitHub's OAuth by hand for the same reason — `:httpc` and
  `Jason`, no SDK — and the providers here are the same bet.

  What was copied is the shape: a model named `provider:name`, one call for
  text, one for a schema-shaped answer, one for an embedding, and a provider
  behaviour so a new endpoint is a module rather than a branch.

  ## An embedding is a job, not a formula

  `Symbol`'s prose says a symbol is "produced by a formula". It cannot be: an
  embedding is a network call, and a formula has no network by construction.
  What `Symbol.check/1` actually enforces is *provenance* — that something ran
  and named itself — which a job satisfies exactly. So the rule held and the
  wording was loose. See `Blazie.Embedding`.
  """

  alias Blazie.Model.{Provider, Reference}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc """
  The attributes a model call is written down with.

  Beside `Spend.seed/0` rather than inside it: what a call cost and what a call
  WAS are different statements, and one of them was already spoken for.
  """
  @spec seed() :: [tuple()]
  def seed do
    Blazie.Attribute.define("asked", answers: "any", cardinality: "many") ++
      Blazie.Attribute.define("answered", answers: "any", cardinality: "many") ++
      Blazie.Attribute.define("took_ms", answers: "integer", cardinality: "many")
  end

  @doc """
  Ask a model for text.

      Blazie.Model.generate("openai:gpt-4o-mini", "Say hello")
  """
  @spec generate(String.t(), String.t() | [map()], keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def generate(model, prompt, opts \\ []) do
    with {:ok, %Reference{} = model} <- Reference.from(model) do
      Provider.for(model).generate(model, messages(prompt), opts)
    end
  end

  @doc """
  Ask a model for an answer shaped like a declaration.

  The schema is the same keyword shape `Blazie.Attribute.define/2` speaks, so
  what a field is declared to answer is what the model is asked for. That is the
  whole of the "no prompts" idea: nobody writes the shape twice, so nobody can
  write it differently twice.
  """
  @spec object(String.t(), String.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def object(model, prompt, schema, opts \\ []) do
    with {:ok, %Reference{} = model} <- Reference.from(model) do
      Provider.for(model).object(model, messages(prompt), schema, opts)
    end
  end

  @doc """
  Turn text into a vector.

  Comes back as a bare list of floats — `Blazie.Symbol.new/2` is what makes it a
  symbol, because a symbol carries the space it belongs to and only the caller
  knows which space this model's output lives in.
  """
  @spec embed(String.t(), String.t() | [String.t()], keyword()) ::
          {:ok, [[float()]]} | {:error, refusal()}
  def embed(model, text, opts \\ []) do
    with {:ok, %Reference{} = model} <- Reference.from(model) do
      Provider.for(model).embed(model, List.wrap(text), opts)
    end
  end

  @doc """
  Ask, offering tools, and keep going until it answers or runs out of calls.

  `run_tool` is handed each call and returns what to tell the model. The loop
  lives here rather than in the caller because getting it wrong is expensive in
  a specific way — a model that calls, reads, and calls again has no natural end,
  and `calls` is the thing standing between that and a bill.

  Returns the answer and every call made, so a trace is something the caller can
  write down rather than reconstruct.

  ## An answer can be required to hold

  Given `answers:` and `snapshot:`, the answer is checked against the
  requirements on that attribute before it comes back — the same `unmet/2` a
  sampled job uses, so a requirement means one thing whether a loop or a job
  produced the value. Failing, the reasons go back to the model as a turn and it
  tries again, bounded by `tries:`.

      converse(model, prompt, tools, run,
        answers: "summary", snapshot: snapshot, tries: 3)

  Without them nothing is checked, which is the honest default for a loop whose
  answer is prose nobody declared a shape for. But an unchecked answer is the
  thing this tree says a generated value must never be, so a caller that means
  the output to land somewhere should say what it answers.
  """
  @spec converse(
          String.t(),
          String.t(),
          [map()],
          (map() -> {:ok, map()} | {:error, map()}),
          keyword()
        ) ::
          {:ok, String.t(), [map()]} | {:error, refusal()}
  def converse(model, prompt, tools, run_tool, opts \\ []) do
    with {:ok, %Reference{} = reference} <- Reference.from(model) do
      turn(
        reference,
        messages(prompt),
        tools,
        run_tool,
        opts,
        Keyword.get(opts, :calls, 4),
        Keyword.get(opts, :tries, 3),
        []
      )
    end
  end

  defp turn(_reference, _messages, _tools, _run, _opts, 0, _tries, made) do
    {:error,
     %{
       problem: :too_many_calls,
       repair:
         "This used all #{length(made)} of its allowed tool calls without answering. Raise " <>
           "`calls_allowed` if the work is honest; a loop that never answers never will."
     }}
  end

  defp turn(reference, messages, tools, run, opts, left, tries, made) do
    asked_at = System.monotonic_time(:millisecond)

    case speaking(reference, opts).(reference, messages, tools, opts) do
      {:error, refusal} ->
        {:error, refusal}

      {:ok, {:said, said}, spent} ->
        record(reference, opts, messages, said, spent, asked_at)
        answered(reference, messages, tools, run, opts, left, tries, made, said)

      {:ok, {:calls, calls}, spent} ->
        record(reference, opts, messages, calls, spent, asked_at)

        {results, made} =
          Enum.reduce(calls, {[], made}, fn call, {results, made} ->
            answered =
              case run.(call) do
                {:ok, result} -> result
                {:error, refusal} -> %{"error" => Map.get(refusal, :repair, "the tool failed")}
              end

            # `Tool.called/4` built exactly this fact and nothing ever called it,
            # so a trajectory recorded what the model SAID and not what it DID.
            # An agent's tool calls are the part worth learning from — the same
            # arguments and the same answer, over and over, is a function nobody
            # has written down yet.
            wrote(opts, call, answered)

            {[{call, answered} | results], [%{call: call, answered: answered} | made]}
          end)

        turn(
          reference,
          messages ++ replies(calls, Enum.reverse(results)),
          tools,
          run,
          opts,
          left - 1,
          tries,
          made
        )
    end
  end

  # Every model call, written down where it happened.
  #
  # Given `into:` and `by:`, a turn lands as facts: which model, what it was
  # asked, what came back, what it cost and how long it took. So "what did this
  # agent do, and what did it cost" is a query over a world rather than a
  # metrics system somebody has to keep in step — the position `Spend` already
  # took for tokens, extended to the call that spent them.
  #
  # `Spend` existed and nothing called it. A module tested in isolation and
  # wired to nothing is the same failure as a check that runs beside the thing
  # rather than on it, and this is the wire.
  #
  # Best effort: a trajectory that could not be written must not fail the work
  # it was describing. A silent gap in a trace is bad; a run that dies because
  # its diary was full is worse.
  defp record(reference, opts, messages, answer, spent, asked_at) do
    with world when not is_nil(world) <- Keyword.get(opts, :into),
         by when not is_nil(by) <- Keyword.get(opts, :by) do
      took = System.monotonic_time(:millisecond) - asked_at

      Blazie.World.append(
        world,
        [
          {by, "asked", asking(messages), by},
          {by, "answered", answering(answer), by},
          {by, "took_ms", took, by}
        ] ++ Blazie.Spend.of(by, spent, by, named(reference))
      )
    end

    # The same turn, said again in somebody else's language. Not conditional on
    # `into:` — a caller with nowhere to keep facts may still be watched by a
    # collector, and the two accounts answer different questions.
    Blazie.Otel.span("model.converse", Keyword.get(opts, :by, "anonymous"),
      took_ms: System.monotonic_time(:millisecond) - asked_at,
      attributes: [
        {"gen_ai.system", reference.provider},
        {"gen_ai.request.model", reference.name},
        {"gen_ai.usage.input_tokens", spent.in},
        {"gen_ai.usage.output_tokens", spent.out},
        {"blazie.answered", answering(answer) |> String.slice(0, 200)}
      ]
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp named(%Reference{provider: provider, name: name}), do: "#{provider}:#{name}"

  # One tool call, written where the turns are. Best effort, for the same reason
  # the turn is: a diary that cannot be written must not stop the work.
  defp wrote(opts, call, answered) do
    with world when not is_nil(world) <- Keyword.get(opts, :into),
         by when not is_nil(by) <- Keyword.get(opts, :by) do
      Blazie.World.append(world, [Blazie.Tool.called(by, call, answered, by)])
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # The last thing said to the model, not the whole conversation. A turn is
  # already a fact per call, so writing the accumulated messages every time
  # would store the same prefix once per turn — quadratic in a long run, and the
  # earlier turns are already there to be read in order.
  defp asking(messages) do
    case List.last(messages) do
      %{"content" => content} when is_binary(content) -> content
      other -> inspect(other)
    end
  end

  defp answering(said) when is_binary(said), do: said

  defp answering(calls) when is_list(calls),
    do: Enum.map_join(calls, ", ", fn call -> "#{call.name}(#{inspect(call.arguments)})" end)

  defp answering(other), do: inspect(other)

  # Who answers. `provider:` is a seam, and it earns its keep: the loop was
  # covered by a test that reimplemented it — a `FakeLoop` with its own copy of
  # the recursion — which proves a copy caps its calls and says nothing about
  # this function. A loop that decides when to stop spending money should be
  # tested, not paraphrased.
  defp speaking(reference, opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        module = Provider.for(reference)
        fn r, m, t, o -> module.converse(r, m, t, o) end

      speak when is_function(speak, 4) ->
        speak

      module when is_atom(module) ->
        fn r, m, t, o -> module.converse(r, m, t, o) end
    end
  end

  # The answer, checked if the caller said what it answers.
  #
  # The repairs go back as a turn rather than being returned, because a model
  # told WHY it was refused can fix it and a model told only "no" cannot — the
  # same reason `Attribute.judge/3` takes the trouble to return a reason at all.
  defp answered(reference, messages, tools, run, opts, left, tries, made, said) do
    attribute = Keyword.get(opts, :answers)
    snapshot = Keyword.get(opts, :snapshot)

    cond do
      is_nil(attribute) or is_nil(snapshot) ->
        {:ok, said, Enum.reverse(made)}

      true ->
        case Blazie.Attribute.unmet([{:answer, attribute, said}], snapshot) do
          [] ->
            {:ok, said, Enum.reverse(made)}

          unmet when tries <= 1 ->
            {:error,
             %{
               problem: :unmet,
               repair:
                 "This answered #{length(unmet)} time(s) without satisfying " <>
                   "#{inspect(attribute)}: " <> Enum.map_join(unmet, " ", & &1.repair)
             }}

          unmet ->
            turn(
              reference,
              messages ++ repair(said, unmet),
              tools,
              run,
              opts,
              left,
              tries - 1,
              made
            )
        end
    end
  end

  # What was said, and what was wrong with it. Both, because a model shown only
  # the complaint has to guess which of its sentences drew it.
  defp repair(said, unmet) do
    [
      %{"role" => "assistant", "content" => said},
      %{
        "role" => "user",
        "content" =>
          "That does not hold. " <>
            Enum.map_join(unmet, " ", & &1.repair) <> " Answer again, satisfying it."
      }
    ]
  end

  # The model's own turn has to go back too, or it asks for the same tool again
  # having no record of having asked.
  defp replies(calls, results) do
    [
      %{
        "role" => "assistant",
        "tool_calls" =>
          Enum.map(calls, fn call ->
            %{
              "id" => call.id,
              "type" => "function",
              "function" => %{"name" => call.name, "arguments" => Jason.encode!(call.arguments)}
            }
          end)
      }
      | Enum.map(results, fn {call, answered} ->
          %{"role" => "tool", "tool_call_id" => call.id, "content" => Jason.encode!(answered)}
        end)
    ]
  end

  defp messages(prompt) when is_binary(prompt), do: [%{"role" => "user", "content" => prompt}]
  defp messages(messages) when is_list(messages), do: messages
end
