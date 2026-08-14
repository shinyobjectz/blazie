defmodule Blazie.Model.Reference do
  @moduledoc """
  Which model, at which provider — `"openai:gpt-4o-mini"`.

  One string, because a model reference travels: into a fact, through a wire,
  into a job's declaration. Two fields would be two things to keep in step, and
  the pair is meaningless apart — a name without a provider names nothing, and
  a provider without a name is not a model.
  """

  @enforce_keys [:provider, :name]
  defstruct [:provider, :name]

  @type t :: %__MODULE__{provider: atom(), name: String.t()}

  # Named here so `to_existing_atom` below can never be handed a name from a
  # request that would mint one. An atom is never collected, so a provider taken
  # from outside would be a way to exhaust the atom table from the wire.
  @known %{
    "openai" => Blazie.Model.Provider.OpenAI,
    "anthropic" => Blazie.Model.Provider.Anthropic,
    "openrouter" => Blazie.Model.Provider.OpenRouter,
    "cloudflare" => Blazie.Model.Provider.Cloudflare
  }
  @provider_atoms [:openai, :anthropic, :openrouter, :cloudflare]
  @doc false
  def known_atoms, do: @provider_atoms

  @doc "Parse a reference, or refuse it with what a reference looks like."
  @spec from(String.t() | t()) :: {:ok, t()} | {:error, map()}
  def from(%__MODULE__{} = model), do: {:ok, model}

  def from(reference) when is_binary(reference) do
    case String.split(reference, ":", parts: 2) do
      [provider, name] when name != "" ->
        if Map.has_key?(@known, provider) do
          {:ok, %__MODULE__{provider: String.to_existing_atom(provider), name: name}}
        else
          {:error,
           %{
             problem: :unknown_provider,
             repair:
               "#{inspect(provider)} is not a provider here. Known: " <>
                 "#{@known |> Map.keys() |> Enum.sort() |> Enum.join(", ")}."
           }}
        end

      _ ->
        {:error,
         %{
           problem: :not_a_model,
           repair: "A model is `provider:name`, like `openai:gpt-4o-mini`."
         }}
    end
  end

  @doc "The module that speaks to this model's provider."
  @spec module(t()) :: module()
  def module(%__MODULE__{provider: provider}), do: Map.fetch!(@known, to_string(provider))

  @doc "Every provider this node can reach."
  @spec providers() :: [String.t()]
  def providers, do: @known |> Map.keys() |> Enum.sort()
end
