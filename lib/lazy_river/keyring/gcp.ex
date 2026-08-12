defmodule LazyRiver.Keyring.GCP do
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

  ## The residual risk, stated

  Erasure deletes an entry from a local store, and a store can be restored from
  a backup. What closes that is a tombstone: erasure also writes a fact, and a
  restore is only correct once those facts have been replayed against it.
  Append-only tombstones are safe to back up, which is the point — the thing
  that says "this person is gone" belongs in the ledger, and the thing that
  must actually go does not.

  That reconciliation is not built. Until it is, a restore of the key store can
  resurrect a subject, and that is the honest limit of this module.
  """

  @behaviour LazyRiver.Keyring

  alias LazyRiver.Keyring.Local

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
      Application.get_env(:lazy_river, :kms_key) ||
      raise "No KMS key configured. Set :kms_key to projects/…/cryptoKeys/…"
  end

  # A token from the environment in production, from gcloud on a workstation.
  # The metadata server is the third form and belongs here when there is a
  # service account to read it from.
  defp token(opts) do
    Keyword.get(opts, :token) ||
      System.get_env("GOOGLE_ACCESS_TOKEN") ||
      case System.cmd("gcloud", ["auth", "print-access-token"], stderr_to_stdout: true) do
        {token, 0} -> String.trim(token)
        {out, _} -> raise "No Google access token available: #{out}"
      end
  end
end
