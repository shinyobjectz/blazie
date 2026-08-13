defmodule Blazie.Keyring.GCP do
  @moduledoc """
  Per-subject keys in a local store, protected by one key in Cloud KMS.

  ## Why one KMS key and not one per subject

  A KMS key version costs about six cents a month. That is nothing for ten keys
  and six hundred dollars a month for ten thousand, so a key per subject prices
  itself out at exactly the scale erasure starts to matter. Google's own
  guidance is one key per meaningful security boundary rather than one per
  object, with envelope encryption underneath.

  So there are three tiers, not two:

    * **One KMS key** per deployment or tenant class. Rotatable, auditable, and
      the only thing that ever leaves this machine.
    * **A per-subject key** in a local store, kept encrypted under a master that
      the KMS key wraps. This is where erasure happens: destroy the entry and
      every data key it wrapped is unopenable.
    * **A per-fact data key**, wrapped by the subject key, travelling in the
      fact itself.

  KMS is touched once at boot to unwrap the master, and never again on a read
  or a write. The bill is a few cents and the latency is irrelevant, which is
  what makes it fine for the KMS to be at a different provider from the compute.

  ## A restore cannot resurrect anybody

  Erasure deletes an entry from a local store, and a store can be restored from
  a backup. What closes that is the tombstone `Blazie.Erasure` writes: an
  append-only fact, safe to back up, saying this subject is gone. The keyring
  reconciles against those every time it opens, so a key store rolled back to
  before an erasure is corrected on the next boot rather than trusted.

  The thing that says somebody is gone belongs in the ledger. The thing that
  must actually go does not.

  ## Being somebody

  A service account key, an access token from the environment, or `gcloud` on a
  workstation — in that order. The service-account flow is a signed claim
  exchanged for a token and cached until it nearly expires, so a server needs
  no SDK and no `gcloud`, and should have neither.
  """

  @behaviour Blazie.Keyring

  alias Blazie.Keyring.Local

  @endpoint "https://cloudkms.googleapis.com/v1"

  @impl true
  def open(opts) do
    with {:ok, master} <- master(opts) do
      Local.open(Keyword.put(opts, :master, master))
    end
  end

  @impl true
  defdelegate wrap(ring, dek, subject), to: Local

  @impl true
  defdelegate unwrap(ring, wrapped, subject), to: Local

  @impl true
  defdelegate destroy(ring, subject), to: Local

  # ── the master, and the one KMS call ───────────────────────────────────────

  defp master(opts) do
    dir = Keyword.get(opts, :dir, "priv/keys")
    File.mkdir_p!(dir)
    path = Path.join(dir, "master.wrapped")

    case File.read(path) do
      {:ok, wrapped} -> decrypt(opts, wrapped)
      {:error, :enoent} -> make_master(opts, path)
    end
  end

  defp make_master(opts, path) do
    master = :crypto.strong_rand_bytes(32)

    with {:ok, wrapped} <- encrypt(opts, master) do
      File.write!(path, wrapped)
      {:ok, master}
    end
  end

  defp encrypt(opts, plaintext) do
    with {:ok, %{"ciphertext" => cipher}} <-
           post(opts, ":encrypt", %{"plaintext" => Base.encode64(plaintext)}) do
      Base.decode64(cipher)
    end
  end

  defp decrypt(opts, wrapped) do
    with {:ok, %{"plaintext" => plain}} <-
           post(opts, ":decrypt", %{"ciphertext" => Base.encode64(wrapped)}) do
      Base.decode64(plain)
    end
  end

  defp post(opts, verb, body) do
    url = String.to_charlist(@endpoint <> "/" <> key_name(opts) <> verb)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token(opts))}]
    request = {url, headers, ~c"application/json", Jason.encode!(body)}

    case :httpc.request(:post, request, [{:timeout, 15_000}], []) do
      {:ok, {{_, 200, _}, _headers, response}} ->
        {:ok, response |> to_string() |> Jason.decode!()}

      {:ok, {{_, status, _}, _headers, response}} ->
        {:error, %{problem: :kms_refused, status: status, body: to_string(response)}}

      {:error, why} ->
        {:error, %{problem: :kms_unreachable, why: why}}
    end
  end

  defp key_name(opts) do
    Keyword.get(opts, :key) ||
      Application.get_env(:blazie, :kms_key) ||
      raise "No KMS key configured. Set :kms_key to projects/…/cryptoKeys/…"
  end

  # Three ways to be somebody, in the order a deployment should prefer them: a
  # service account it was given, a token handed in by the environment, or
  # gcloud on a workstation. A server has no gcloud and should not have one.
  defp token(opts) do
    Keyword.get(opts, :token) ||
      System.get_env("GOOGLE_ACCESS_TOKEN") ||
      service_account_token() ||
      gcloud_token()
  end

  defp gcloud_token do
    case System.cmd("gcloud", ["auth", "print-access-token"], stderr_to_stdout: true) do
      {token, 0} -> String.trim(token)
      {out, _} -> raise "No Google access token available: #{out}"
    end
  rescue
    ErlangError -> raise "No Google access token available and no gcloud to ask."
  end

  # ── being a service account ────────────────────────────────────────────────
  #
  # Sign a claim that we are who the key says, exchange it for an access token,
  # and keep the token until shortly before it expires. No SDK and no gcloud —
  # the whole flow is a signature and one POST.

  defp service_account_token do
    with path when is_binary(path) <- Application.get_env(:blazie, :gcp_credentials),
         {:ok, raw} <- File.read(path),
         {:ok, account} <- Jason.decode(raw) do
      cached_token(account)
    else
      _ -> nil
    end
  end

  defp cached_token(account) do
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, :token}, nil) do
      {token, expires} when expires > now + 60 -> token
      _ -> mint_token(account, now)
    end
  end

  defp mint_token(account, now) do
    claims = %{
      "iss" => account["client_email"],
      "scope" => "https://www.googleapis.com/auth/cloud-platform",
      "aud" => "https://oauth2.googleapis.com/token",
      "iat" => now,
      "exp" => now + 3600
    }

    jwt = sign(%{"alg" => "RS256", "typ" => "JWT"}, claims, account["private_key"])

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    request =
      {~c"https://oauth2.googleapis.com/token", [], ~c"application/x-www-form-urlencoded", body}

    case :httpc.request(:post, request, [{:timeout, 15_000}], []) do
      {:ok, {{_, 200, _}, _, response}} ->
        %{"access_token" => token, "expires_in" => ttl} =
          response |> to_string() |> Jason.decode!()

        :persistent_term.put({__MODULE__, :token}, {token, now + ttl})
        token

      {:ok, {{_, status, _}, _, response}} ->
        raise "Google refused the service account (#{status}): #{to_string(response)}"

      {:error, why} ->
        raise "Could not reach Google to exchange the service account: #{inspect(why)}"
    end
  end

  defp sign(header, claims, pem) do
    signing_input =
      Base.url_encode64(Jason.encode!(header), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    [entry] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)
    signature = :public_key.sign(signing_input, :sha256, key)

    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end
end
