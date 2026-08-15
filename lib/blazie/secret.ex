defmodule Blazie.Secret do
  @moduledoc """
  The secret plane — a credential is held as a REFERENCE, never as a fact.

  A platform token (or any credential) enters here and is wrapped by the
  `Keyring` — envelope-encrypted, tenant-scoped, erasable — and only the wrapped
  material is written to a per-holder secret world, beside its handle. The
  plaintext is never a fact value: the most any caller can hold is a handle like
  `"secret:org-7/bluesky"`, and the real value is recovered only at the outbound
  boundary, through `resolve/3` or `through/3`, which the dossier fence (a
  `:formula`) may not cross.

  This joins two halves blazie already had — `Keyring` (encrypted material,
  erasable per subject) and the Authority pattern (the world holds references,
  not secrets) — and adds the one new thing a credential proxy needs: a scrub at
  egress, so a value that was used cannot ride back out in a fact, a log, or a
  dossier. Because a sandboxed guest physically cannot originate an
  authenticated call (a `:formula` has no network; a `:job`'s only network
  primitive carries no headers), doing the swap-and-scrub at this Elixir
  boundary is airtight — there is no path around it.
  """

  alias Blazie.{Attribute, Keyring, Snapshot, World}

  @redacted "[redacted]"

  @seed Attribute.define("holder", answers: "name", cardinality: "many") ++
          Attribute.define("secret_name", answers: "name", cardinality: "many") ++
          Attribute.define("material", answers: "any", cardinality: "many")

  @type refusal :: %{problem: atom(), repair: String.t()}

  @doc "The per-holder secret world. A tenant name, so one holder's secrets are another's absence."
  @spec world(term()) :: World.name()
  def world(holder), do: {:"$secret", to_string(holder)}

  @doc "The handle a caller holds in place of the value."
  @spec handle(term(), term()) :: String.t()
  def handle(holder, name), do: "secret:#{holder}/#{name}"

  @doc """
  Stow a credential — wrapped by the Keyring, only the wrapped material written.

  Returns the handle. The plaintext is never appended; what lands is the
  envelope-encrypted blob, safe to persist because it is noise without the
  subject's key.
  """
  @spec stow(term(), term(), binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def stow(holder, name, value, opts \\ []) when is_binary(value) do
    keyring = Keyword.get(opts, :keyring, Keyring)

    with {:ok, w} <- open(holder),
         {:ok, wrapped} <- keyring.wrap(value, subject(holder)) do
      h = handle(holder, name)

      {:ok, _} =
        World.append(w, [
          {h, "is", "secret"},
          {h, "holder", to_string(holder)},
          {h, "secret_name", to_string(name)},
          {h, "material", Base.encode64(wrapped)}
        ])

      {:ok, h}
    end
  end

  @doc """
  Recover a stowed value — at the network boundary, and only from a `:job`.

  The dossier fence is a `:formula`: no network, and no secrets. Passing
  `:formula` is refused with the repair, so the two-fence posture is structural
  here, not a convention a caller must remember.
  """
  @spec resolve(String.t(), :job | :formula, keyword()) :: {:ok, binary()} | {:error, refusal()}
  def resolve(handle, posture \\ :job, opts \\ [])

  def resolve(_handle, :formula, _opts) do
    {:error,
     %{
       problem: :fenced,
       repair:
         "A :formula runs under the fabrication fence — no network, and therefore no secrets. " <>
           "Resolve a credential only from a :job, the network-allowed posture."
     }}
  end

  def resolve(handle, :job, opts) do
    keyring = Keyword.get(opts, :keyring, Keyring)
    {holder, _name} = parse(handle)

    with {:ok, w} <- open(holder),
         b64 when is_binary(b64) <- Snapshot.value(Snapshot.open([w]), handle, "material") do
      case keyring.unwrap(Base.decode64!(b64), subject(holder)) do
        {:ok, value} -> {:ok, value}
        :forgotten -> {:error, %{problem: :forgotten, repair: "#{handle}'s subject was erased."}}
      end
    else
      nil -> {:error, %{problem: :no_such_secret, repair: "Nothing is stowed at #{handle}."}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Use a secret without letting it out: resolve it, run `fun` with the value, and
  scrub the value from whatever `fun` returns.

  This is the credential proxy in one call — the real token lives only inside
  `fun` (where the outbound request is made) and is redacted from the result
  before it can become a fact or a log line.
  """
  @spec through(String.t(), (binary() -> term()), keyword()) ::
          {:ok, term()} | {:error, refusal()}
  def through(handle, fun, opts \\ []) when is_function(fun, 1) do
    with {:ok, value} <- resolve(handle, Keyword.get(opts, :posture, :job), opts) do
      {:ok, scrub(fun.(value), [value])}
    end
  end

  @doc "Redact known secret values from any term — strings, maps, lists, tuples, nested."
  @spec scrub(term(), [binary()]) :: term()
  def scrub(term, secrets) do
    case Enum.filter(secrets, &(is_binary(&1) and &1 != "")) do
      [] -> term
      real -> do_scrub(term, real)
    end
  end

  defp do_scrub(s, secrets) when is_binary(s) do
    Enum.reduce(secrets, s, fn secret, acc -> String.replace(acc, secret, @redacted) end)
  end

  defp do_scrub(m, secrets) when is_map(m) do
    Map.new(m, fn {k, v} -> {do_scrub(k, secrets), do_scrub(v, secrets)} end)
  end

  defp do_scrub(l, secrets) when is_list(l), do: Enum.map(l, &do_scrub(&1, secrets))

  defp do_scrub(t, secrets) when is_tuple(t) do
    t |> Tuple.to_list() |> do_scrub(secrets) |> List.to_tuple()
  end

  defp do_scrub(other, _secrets), do: other

  # ── internals ────────────────────────────────────────────────────────────────

  defp open(holder) do
    with {:ok, w} <- World.open(world(holder)) do
      if World.tx(w) == 0, do: {:ok, _} = World.append(w, Attribute.seed() ++ @seed)
      {:ok, w}
    end
  end

  defp subject(holder), do: "secret:#{holder}"

  defp parse("secret:" <> rest) do
    [holder, name] = String.split(rest, "/", parts: 2)
    {holder, name}
  end
end
