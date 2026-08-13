defmodule Blazie.Model.Provider.OpenRouter do
  @moduledoc """
  OpenRouter, which is the OpenAI shape pointed somewhere else.

  Every method here delegates, and that is the point rather than a shortcut:
  the chat-completions and embeddings shapes are the closest thing this space
  has to a lingua franca, so a provider that speaks them needs a base url and a
  key and nothing more. Groq, Together, vLLM, Ollama and LM Studio are all the
  same three lines.

  It earns its own module for one honest reason: `OPENROUTER_API_KEY` is a
  different environment variable, and a provider that quietly read the wrong
  key would fail with somebody else's 401.
  """

  @behaviour Blazie.Model.Provider

  alias Blazie.Model.Provider.OpenAI

  @base "https://openrouter.ai/api/v1"

  @impl true
  def generate(model, messages, opts), do: OpenAI.generate(model, messages, ours(opts))

  @impl true
  def object(model, messages, schema, opts), do: OpenAI.object(model, messages, schema, ours(opts))

  @impl true
  def embed(model, texts, opts), do: OpenAI.embed(model, texts, ours(opts))

  defp ours(opts) do
    opts
    |> Keyword.put_new(:base_url, @base)
    |> Keyword.put_new_lazy(:api_key, fn -> System.get_env("OPENROUTER_API_KEY") end)
  end
end
