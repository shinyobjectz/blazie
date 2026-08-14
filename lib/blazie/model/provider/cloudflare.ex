defmodule Blazie.Model.Provider.Cloudflare do
  @moduledoc """
  Workers AI, reached through an AI Gateway when there is one.

  The OpenAI shape pointed somewhere else again, like `OpenRouter` — and for the
  same reason it earns a module rather than a branch: a different account, a
  different key, and a base url assembled from both.

  ## Two addresses, and why the gateway is preferred

  Without a gateway this reaches Workers AI directly, at the account's own
  `/ai/v1`. With `CLOUDFLARE_AI_GATEWAY` set it goes through the gateway
  instead, which is what makes a model call observable: the gateway logs every
  request, caches on demand and can rate-limit, none of which the direct
  endpoint does. A model call that nothing recorded is a model call you cannot
  audit afterwards, and this tree already holds that a number with no origin is
  a claim rather than a fact.

  ## Model names carry slashes and an @

      cloudflare:@cf/zai-org/glm-4.7-flash
      cloudflare:@cf/google/gemma-4-26b-a4b-it

  `Reference` splits on the FIRST colon only, so everything after it is the
  name — which is what makes these addressable without escaping anything.

  ## What was measured before this was written

  Every one of these is a reasoning model: it spends tokens in
  `reasoning_content` before it writes any, and asked for `pong` with
  `max_tokens: 64` it answers `finish_reason: "length"` with content EMPTY —
  not an error, not a refusal, just nothing, which is the worst shape a failure
  can have. `generate/3` sends no `max_tokens` and the default is generous
  enough, so this is fine as it stands; it is written down because the next
  person to add a cap here will do it to save money and will get silence back.

  `json_schema` with `strict` is honoured — `{"value": "high"}` came back from
  glm-4.7-flash against an enum schema — so `object/4` works without asking
  nicely and parsing hopefully.
  """

  @behaviour Blazie.Model.Provider

  alias Blazie.Model.Provider.OpenAI

  @impl true
  def generate(model, messages, opts), do: OpenAI.generate(model, messages, ours(opts))

  @impl true
  def object(model, messages, schema, opts),
    do: OpenAI.object(model, messages, schema, ours(opts))

  @impl true
  def embed(model, texts, opts), do: OpenAI.embed(model, texts, ours(opts))

  @impl true
  def converse(model, messages, tools, opts),
    do: OpenAI.converse(model, messages, tools, ours(opts))

  @doc "Where this reaches, given what the environment says. Public so a test can assert it."
  @spec base(String.t() | nil, String.t() | nil) :: String.t()
  def base(account, gateway)

  def base(nil, _gateway), do: ""

  def base(account, nil),
    do: "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/v1"

  def base(account, gateway),
    do: "https://gateway.ai.cloudflare.com/v1/#{account}/#{gateway}/workers-ai/v1"

  defp ours(opts) do
    opts
    |> Keyword.put_new_lazy(:base_url, fn ->
      base(System.get_env("CLOUDFLARE_ACCOUNT_ID"), System.get_env("CLOUDFLARE_AI_GATEWAY"))
    end)
    |> Keyword.put_new_lazy(:api_key, fn ->
      # The account token works for Workers AI when it carries the permission, so
      # a deployment that already has one does not need a second. Named first
      # anyway, because a token scoped to inference is the one you want to hand
      # to a thing that only does inference.
      System.get_env("CLOUDFLARE_AI_TOKEN") || System.get_env("CLOUDFLARE_API_TOKEN")
    end)
  end
end
