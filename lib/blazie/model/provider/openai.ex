defmodule Blazie.Model.Provider.OpenAI do
  @moduledoc """
  OpenAI, and anything speaking its shape.

  The chat-completions and embeddings shapes are the closest thing this space
  has to a lingua franca — Groq, Together, OpenRouter, vLLM and Ollama all
  answer them — so `base_url:` makes this module reach most endpoints that
  exist without a second one being written.
  """

  @behaviour Blazie.Model.Provider

  alias Blazie.Model.{Provider, Reference}

  @base "https://api.openai.com/v1"

  @impl true
  def generate(%Reference{} = model, messages, opts) do
    with {:ok, answered} <-
           Provider.post(
             url(opts, "/chat/completions"),
             headers(opts),
             %{
               "model" => model.name,
               "messages" => messages,
               "temperature" => Keyword.get(opts, :temperature, 0.0)
             },
             opts
           ) do
      text(answered)
    end
  end

  @impl true
  def object(%Reference{} = model, messages, schema, opts) do
    # `json_schema` with `strict` is the provider enforcing the shape, rather
    # than us asking nicely and parsing hopefully. A model that cannot honour it
    # answers with a refusal instead of prose that looks like json.
    body = %{
      "model" => model.name,
      "messages" => messages,
      "temperature" => Keyword.get(opts, :temperature, 0.0),
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "answer",
          "strict" => true,
          "schema" => Blazie.Model.Schema.json(schema)
        }
      }
    }

    with {:ok, answered} <-
           Provider.post(url(opts, "/chat/completions"), headers(opts), body, opts),
         {:ok, raw} <- text(answered) do
      case Jason.decode(raw) do
        {:ok, decoded} when is_map(decoded) ->
          {:ok, decoded}

        _ ->
          {:error,
           %{
             problem: :not_the_shape_asked_for,
             repair: "The model answered #{String.slice(raw, 0, 200)}, which is not an object."
           }}
      end
    end
  end

  @impl true
  def converse(%Reference{} = model, messages, tools, opts) do
    body = %{
      "model" => model.name,
      "messages" => messages,
      "temperature" => Keyword.get(opts, :temperature, 0.0),
      "tools" => Enum.map(tools, &as_tool/1)
    }

    with {:ok, answered} <-
           Provider.post(url(opts, "/chat/completions"), headers(opts), body, opts) do
      case turn(answered) do
        {:ok, said} -> {:ok, said, Provider.spent(answered)}
        {:error, refusal} -> {:error, refusal}
      end
    end
  end

  defp as_tool(tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.describe,
        "parameters" => Blazie.Model.Schema.json(tool.takes)
      }
    }
  end

  # A model that wants a tool says so INSTEAD of answering, so the two are
  # checked in that order — a message with both is a model hedging, and running
  # the tool is the more useful reading.
  defp turn(%{"choices" => [%{"message" => message} | _]}) do
    case Map.get(message, "tool_calls") do
      calls when is_list(calls) and calls != [] ->
        {:ok,
         {:calls,
          Enum.map(calls, fn call ->
            %{
              id: Map.get(call, "id"),
              name: get_in(call, ["function", "name"]),
              arguments: decode_arguments(get_in(call, ["function", "arguments"]))
            }
          end)}}

      _ ->
        {:ok, {:said, Map.get(message, "content") || ""}}
    end
  end

  defp turn(answered),
    do: {:error, %{problem: :no_answer, repair: inspect(answered) |> String.slice(0, 200)}}

  # Arguments arrive as a json STRING rather than an object, which is a shape
  # nobody would choose and everybody has to handle.
  defp decode_arguments(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_arguments(_raw), do: %{}

  @impl true
  def embed(%Reference{} = model, texts, opts) do
    with {:ok, answered} <-
           Provider.post(
             url(opts, "/embeddings"),
             headers(opts),
             %{"model" => model.name, "input" => texts},
             opts
           ) do
      vectors(answered)
    end
  end

  defp text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content),
       do: {:ok, content}

  defp text(answered),
    do:
      {:error,
       %{
         problem: :no_answer,
         repair:
           "The provider answered without a message: #{inspect(answered) |> String.slice(0, 200)}"
       }}

  # Sorted by index, because the order embeddings come back in is not promised
  # and a caller zipping them against its inputs would silently mislabel every
  # vector if it ever changed.
  defp vectors(%{"data" => data}) when is_list(data) do
    {:ok,
     data
     |> Enum.sort_by(&Map.get(&1, "index", 0))
     |> Enum.map(&Map.fetch!(&1, "embedding"))}
  end

  defp vectors(answered),
    do:
      {:error,
       %{
         problem: :no_vectors,
         repair:
           "The provider answered without embeddings: #{inspect(answered) |> String.slice(0, 200)}"
       }}

  defp url(opts, path), do: Keyword.get(opts, :base_url, @base) <> path

  defp headers(opts) do
    key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY") || ""
    [{"authorization", "Bearer " <> key}]
  end
end
