defmodule Logi.Provider.Anthropic do
  @moduledoc """
  Anthropic's messages API.

  Two differences from the OpenAI shape, both load-bearing: the system prompt is
  a top-level field rather than a message, and `max_tokens` is required rather
  than optional. A provider module exists so those live in one file instead of
  as conditionals in a shared one.
  """

  @behaviour Logi.Provider

  alias Logi.{Model, Provider}

  @base "https://api.anthropic.com/v1"
  @version "2023-06-01"

  @impl true
  def generate(%Model{} = model, messages, opts) do
    {system, rest} = split_system(messages)

    body =
      %{
        "model" => model.name,
        "messages" => rest,
        "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
        "temperature" => Keyword.get(opts, :temperature, 0.0)
      }
      |> put_system(system)

    with {:ok, answered} <- Provider.post(url(opts, "/messages"), headers(opts), body) do
      text(answered)
    end
  end

  @impl true
  def object(%Model{} = model, messages, schema, opts) do
    # Anthropic shapes an answer through a tool rather than a response format.
    # Asking for the tool and forcing its use is the same guarantee arrived at
    # differently, which is exactly what a provider module is for.
    tool = %{
      "name" => "answer",
      "description" => "Answer with this shape.",
      "input_schema" => Logi.Schema.json(schema)
    }

    {system, rest} = split_system(messages)

    body =
      %{
        "model" => model.name,
        "messages" => rest,
        "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
        "tools" => [tool],
        "tool_choice" => %{"type" => "tool", "name" => "answer"}
      }
      |> put_system(system)

    with {:ok, answered} <- Provider.post(url(opts, "/messages"), headers(opts), body) do
      tool_input(answered)
    end
  end

  @impl true
  def embed(_model, _texts, _opts), do: Provider.cannot("embeddings", "Anthropic")

  defp text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
    |> case do
      "" -> {:error, %{problem: :no_answer, repair: "The model answered with no text."}}
      said -> {:ok, said}
    end
  end

  defp text(answered),
    do: {:error, %{problem: :no_answer, repair: inspect(answered) |> String.slice(0, 200)}}

  defp tool_input(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.find(&(Map.get(&1, "type") == "tool_use"))
    |> case do
      %{"input" => input} when is_map(input) ->
        {:ok, input}

      _ ->
        {:error,
         %{
           problem: :not_the_shape_asked_for,
           repair: "The model was asked for a shaped answer and did not use the tool."
         }}
    end
  end

  defp tool_input(answered),
    do: {:error, %{problem: :no_answer, repair: inspect(answered) |> String.slice(0, 200)}}

  defp split_system(messages) do
    {system, rest} = Enum.split_with(messages, &(Map.get(&1, "role") == "system"))
    {Enum.map_join(system, "\n", &Map.get(&1, "content", "")), rest}
  end

  defp put_system(body, ""), do: body
  defp put_system(body, system), do: Map.put(body, "system", system)

  defp url(opts, path), do: Keyword.get(opts, :base_url, @base) <> path

  defp headers(opts) do
    key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY") || ""
    [{"x-api-key", key}, {"anthropic-version", @version}]
  end
end
