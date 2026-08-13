defmodule Blazie.Model.Schema do
  @moduledoc """
  A blazie declaration, as the shape a model is asked for.

  This is the whole of "no prompts", and it is smaller than it sounds. A field
  already says what it answers:

      Attribute.define("severity", answers: "name")

  and that is the same sentence a provider wants as a json schema. So nobody
  writes the shape twice, which means nobody can write it differently twice —
  the failure mode where a prompt says "reply with an integer" and the
  declaration says `answers: "name"` cannot occur, because there is one sentence.

  ## What a shape cannot say

  `answers: "any"` becomes a permissive schema rather than a refusal. A model
  asked for anything will answer with something, and the requirements are what
  decide whether it is acceptable — a schema constrains the SHAPE, a requirement
  constrains the VALUE, and pretending the first can do the second produces a
  schema nobody can satisfy.
  """

  @doc """
  A json schema for a keyword declaration.

      json(answers: "integer")              -> a bare integer, under "value"
      json(name: [answers: "name"], age: [answers: "integer"])
  """
  @spec json(keyword()) :: map()
  def json(declaration) do
    fields = fields(declaration)

    %{
      "type" => "object",
      "properties" => Map.new(fields, fn {name, shape} -> {to_string(name), shape} end),
      "required" => Enum.map(fields, fn {name, _shape} -> to_string(name) end),
      "additionalProperties" => false
    }
  end

  # A bare `answers:` describes one value, so it is wrapped rather than refused —
  # a provider's structured mode always wants an object at the top.
  defp fields(declaration) do
    if Keyword.keyword?(declaration) and Keyword.has_key?(declaration, :answers) do
      [{"value", shape(Keyword.get(declaration, :answers), declaration)}]
    else
      Enum.map(declaration, fn {name, spec} -> {name, shape(Keyword.get(spec, :answers), spec)} end)
    end
  end

  # The four shapes `Attribute.satisfies?/2` can actually decide. Anything else
  # is a name the engine cannot evaluate, and a value cannot contradict a shape
  # nobody can decide — so it is permissive here for the same reason it is
  # permissive there.
  defp shape("integer", spec), do: described(%{"type" => "integer"}, spec)
  defp shape("number", spec), do: described(%{"type" => "number"}, spec)
  defp shape("boolean", spec), do: described(%{"type" => "boolean"}, spec)
  defp shape("name", spec), do: described(%{"type" => "string"}, spec)
  defp shape(_other, spec), do: described(%{}, spec)

  defp described(shape, spec) do
    case Keyword.get(spec, :describe) do
      nil -> shape
      words -> Map.put(shape, "description", words)
    end
  end
end
