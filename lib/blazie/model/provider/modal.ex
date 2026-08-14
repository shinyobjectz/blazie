defmodule Blazie.Model.Provider.Modal do
  @moduledoc """
  A customer's own embedding suite, reached as a provider — the MadEmb door.

  The pattern socialite proved on a single T4: the customer runs their own
  models behind their own endpoints, bake-offs and all, and this door only
  carries the call. A model named `modal:madem-text` reaches the configured
  endpoint's `/embed` with the lane name; the suite answers vectors and what
  the GPU spent answering, and the spend is booked per Studio at the same
  cost seam as tokens.

  ## Fetch and embed are one pass, by construction

  Media arrives in the request — bytes, or a URL the suite fetches NOW —
  and this module holds no state between calls, so there is nowhere for a
  URL to wait while its signature expires. That design already failed once
  measured: signed CDN URLs died before a backfill ran, and an embed-later
  queue is structurally broken rather than merely slower. A caller that
  wants to re-embed keeps the content, not the address.

  ## The lane's role is the suite's to state

  The suite answers `role` beside the vectors, and the caller declares the
  space with exactly that role (`Index.declare/2`) — the seam enforces it
  from there. A suite that states no role gets a space that refuses
  everything, which is the Madem invariant with the enforcement moved to
  where the vectors land.
  """

  @behaviour Blazie.Model.Provider

  alias Blazie.Model.{Provider, Reference}

  @impl true
  def generate(_model, _messages, _opts) do
    {:error,
     %{
       problem: :not_a_language_model,
       repair: "A suite embeds. Ask a language provider for text; ask this for vectors."
     }}
  end

  @impl true
  def object(model, messages, _schema, opts), do: generate(model, messages, opts)

  @impl true
  def embed(%Reference{name: lane}, inputs, opts) do
    endpoint = Keyword.get(opts, :endpoint) || configured(:endpoint)
    token = Keyword.get(opts, :token) || configured(:token) || ""

    body = %{"lane" => lane, "input" => inputs}

    case Provider.post(
           endpoint <> "/embed",
           [{"authorization", "Bearer " <> token}],
           body,
           opts
         ) do
      {:ok, %{"vectors" => vectors} = answer} when is_list(vectors) ->
        # The 3-tuple shape: vectors plus what answering cost. `Model.embed`
        # books GPU seconds from it exactly as `converse` books tokens.
        {:ok, vectors, usage(answer)}

      {:ok, other} ->
        {:error,
         %{
           problem: :not_a_suite,
           repair:
             "The endpoint answered #{inspect(other) |> String.slice(0, 200)}, not " <>
               "{vectors, gpu_seconds, role}. Check it is a MadEmb-shaped suite."
         }}

      {:error, refusal} ->
        {:error, refusal}
    end
  end

  defp usage(answer) do
    %{
      gpu_seconds: Map.get(answer, "gpu_seconds", 0.0),
      role: Map.get(answer, "role")
    }
  end

  defp configured(key) do
    :blazie |> Application.get_env(:modal, []) |> Keyword.get(key)
  end
end
