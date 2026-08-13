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

  defp messages(prompt) when is_binary(prompt), do: [%{"role" => "user", "content" => prompt}]
  defp messages(messages) when is_list(messages), do: messages
end
