defmodule Blazie.Model.Provider.Anthropic do
  @moduledoc """
  Anthropic's messages API.

  Two differences from the OpenAI shape, both load-bearing: the system prompt is
  a top-level field rather than a message, and `max_tokens` is required rather
  than optional. A provider module exists so those live in one file instead of
  as conditionals in a shared one.
  """

  @behaviour Blazie.Model.Provider

  alias Blazie.Model.{Provider, Reference}

  @base "https://api.anthropic.com/v1"
  @version "2023-06-01"

  @impl true
  def generate(%Reference{} = model, messages, opts) do
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
  def object(%Reference{} = model, messages, schema, opts) do
    # Anthropic shapes an answer through a tool rather than a response format.
    # Asking for the tool and forcing its use is the same guarantee arrived at
    # differently, which is exactly what a provider module is for.
    tool = %{
      "name" => "answer",
      "description" => "Answer with this shape.",
      "input_schema" => Blazie.Model.Schema.json(schema)
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
  def converse(%Reference{} = model, messages, tools, opts) do
    {system, rest} = split_system(messages)

    body =
      %{
        "model" => model.name,
        "messages" => Enum.map(rest, &anthropic_message/1),
        "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
        "tools" =>
          Enum.map(tools, fn tool ->
            %{
              "name" => tool.name,
              "description" => tool.describe,
              "input_schema" => Blazie.Model.Schema.json(tool.takes)
            }
          end)
      }
      |> put_system(system)

    with {:ok, answered} <- Provider.post(url(opts, "/messages"), headers(opts), body) do
      case turn(answered) do
        {:ok, said} -> {:ok, said, Provider.spent(answered)}
        {:error, refusal} -> {:error, refusal}
      end
    end
  end

  # A tool result goes back as a user turn holding a `tool_result` block, not as
  # a role of its own. That difference is the reason this provider has its own
  # module rather than a flag in a shared one.
  defp anthropic_message(%{"role" => "tool"} = message) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => Map.get(message, "tool_call_id"),
          "content" => Map.get(message, "content", "")
        }
      ]
    }
  end

  defp anthropic_message(%{"role" => "assistant", "tool_calls" => calls}) do
    %{
      "role" => "assistant",
      "content" =>
        Enum.map(calls, fn call ->
          %{
            "type" => "tool_use",
            "id" => call["id"],
            "name" => get_in(call, ["function", "name"]),
            "input" => Jason.decode!(get_in(call, ["function", "arguments"]) || "{}")
          }
        end)
    }
  end

  defp anthropic_message(message), do: message

  defp turn(%{"content" => blocks}) when is_list(blocks) do
    case Enum.filter(blocks, &(Map.get(&1, "type") == "tool_use")) do
      [] ->
        {:ok, {:said, Enum.map_join(blocks, "", &Map.get(&1, "text", ""))}}

      uses ->
        {:ok,
         {:calls,
          Enum.map(uses, fn use ->
            %{
              id: Map.get(use, "id"),
              name: Map.get(use, "name"),
              arguments: Map.get(use, "input", %{})
            }
          end)}}
    end
  end

  defp turn(answered),
    do: {:error, %{problem: :no_answer, repair: inspect(answered) |> String.slice(0, 200)}}

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
