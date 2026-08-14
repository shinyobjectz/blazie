defmodule Blazie.Keyring.Local do
  @moduledoc """
  Key-encryption keys in a file, under a master key from the environment.

  Right for development, and for an application with no real user data. Wrong
  in front of real users, for one reason worth being blunt about: **a file can
  come back from a restore.** Erasure has to be irreversible, and nothing here
  can promise that — a backup taken before the destroy will happily return the
  key. A KMS can promise it, which is what a KMS is for.

  So this exists to make the shape real and the tests honest, not to be the
  answer. Swapping it is one module, because `Blazie.Keyring` is a
  behaviour.

  ## What it does do properly

  Each subject gets a KEK, kept encrypted at rest under a master key that lives
  in the environment rather than beside the keys — so the file alone is not
  enough. Destroying removes the KEK from the file, and every data key it
  wrapped becomes unopenable without anything else being touched.
  """

  @behaviour Blazie.Keyring

  @master_env "BLAZIE_MASTER_KEY"

  # The name this used to have, still read. Nothing is deployed under it, but
  # this tree has lost data three times to a stored shape changing under a green
  # suite, and a key read from the wrong variable does not fail — it silently
  # encrypts under a different one and cannot open what came before.
  @master_was "LAZY_RIVER_MASTER_KEY"

  @impl true
  def open(opts) do
    dir = Keyword.get(opts, :dir, "priv/keys")
    File.mkdir_p!(dir)

    # A master may be supplied — `Blazie.Keyring.GCP` hands one down that a
    # KMS unwrapped, so the file mechanics here are shared rather than copied.
    {:ok, %{path: Path.join(dir, "keks"), master: Keyword.get(opts, :master) || master()}}
  end

  @impl true
  def wrap(ring, dek, subject) do
    kek = kek_for(ring, subject)
    iv = :crypto.strong_rand_bytes(12)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, dek, <<>>, true)

    {:ok, <<iv::binary-12, tag::binary-16, cipher::binary>>}
  end

  @impl true
  def unwrap(ring, <<iv::binary-12, tag::binary-16, cipher::binary>>, subject) do
    case existing_kek(ring, subject) do
      nil ->
        :forgotten

      kek ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, cipher, <<>>, tag, false) do
          :error -> :forgotten
          dek -> {:ok, dek}
        end
    end
  end

  def unwrap(_ring, _malformed, _subject), do: :forgotten

  @impl true
  def destroy(ring, subject) do
    write(ring, Map.delete(read(ring), subject))
    :ok
  end

  # ── the file ───────────────────────────────────────────────────────────────

  defp kek_for(ring, subject) do
    keks = read(ring)

    case Map.get(keks, subject) do
      nil ->
        kek = :crypto.strong_rand_bytes(32)
        write(ring, Map.put(keks, subject, kek))
        kek

      kek ->
        kek
    end
  end

  defp existing_kek(ring, subject), do: ring |> read() |> Map.get(subject)

  defp read(ring) do
    with {:ok, <<iv::binary-12, tag::binary-16, cipher::binary>>} <- File.read(ring.path),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, ring.master, iv, cipher, <<>>, tag, false) do
      :erlang.binary_to_term(plain)
    else
      # No file yet, or one this master key cannot open. Either way there are
      # no keys to be had, which reads the same as everything being erased —
      # another reason this is not the production answer.
      _ -> %{}
    end
  end

  defp write(ring, keks) do
    plain = :erlang.term_to_binary(keks)
    iv = :crypto.strong_rand_bytes(12)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, ring.master, iv, plain, <<>>, true)

    tmp = ring.path <> ".writing"
    File.write!(tmp, <<iv::binary-12, tag::binary-16, cipher::binary>>)
    File.rename!(tmp, ring.path)
  end

  # The master key is never written next to what it protects. In development it
  # is derived so tests need no setup; anywhere else it must be supplied, and a
  # derived one would be no protection at all.
  # The key everything else is encrypted under.
  #
  # The fallback is a constant in a public repository, which is worth saying
  # plainly: a cluster running on it has key-encryption keys that anybody can
  # decrypt, so sealing protects nothing. That is correct for a test and a
  # catastrophe in production, and it used to happen silently — a provisioned
  # cluster was given no master key at all and said nothing about it.
  #
  # `runtime.exs` warns at boot when it is missing in prod. Here it is only
  # named honestly.
  defp master do
    case System.get_env(@master_env) || System.get_env(@master_was) do
      nil -> :crypto.hash(:sha256, "blazie-development-master-key-not-a-secret")
      supplied -> :crypto.hash(:sha256, supplied)
    end
  end

  @doc false
  # Somewhere for a boot check to ask, rather than re-deriving the rule.
  def master_supplied? do
    (System.get_env(@master_env) || System.get_env(@master_was)) != nil
  end
end
