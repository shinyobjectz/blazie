defmodule Blazie.Erasure do
  @moduledoc """
  The one destructive operation (doctrine 16).

  Everything else here is additive — add an attribute, write a later fact, name
  a new formula. Erasure is the exception, and the law requires it. Immutability
  cannot give it, so the answer is not to remove anything: a fact's answer is
  written encrypted under a key belonging to whoever it is about, and erasing
  destroys the key. The bytes stay and become noise. No segment is rewritten,
  and backups need no special handling because the key was never in them.

  ## Why the subject belongs to the entity

  Doctrine 16 says erasure must reach whatever was *computed* from the erased
  facts — an embedding of a deleted message may still encode it. The obvious
  implementation is a walk over provenance, and it is fragile: miss one edge
  and content survives that should not.

  So the subject is a property of the **entity**, declared once:

      {42, "subject", "person-7"}

  Every later fact about 42 is encrypted under person-7's key, whoever wrote it
  and whether it came from outside or from a formula. A derived fact about
  someone's entity is protected by the same key as the fact it came from, so
  one destroyed key takes both. Nothing walks anything.

  ## What cannot be erased, said plainly

  A fact written before its subject was declared is not covered, because
  nothing knew whose it was when it was written. The subject is decided at
  write time or not at all, and `erasable?/2` answers whether it was.
  """

  alias Blazie.{Attribute, Fact, Keyring, Ledger, Snapshot}

  @subject "subject"
  @erased_at "erased_at"
  @ledger "$erasures"

  @doc "The attribute an entity declares its owner with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed, do: Attribute.define(@subject, answers: "name")

  @doc "The ledger tombstones are written to."
  @spec ledger() :: String.t()
  def ledger, do: @ledger

  @doc "The attribute name itself, for anyone who needs to write one."
  @spec attribute() :: String.t()
  def attribute, do: @subject

  @doc """
  Destroy a subject's key, and with it everything written about their entities.

  Idempotent and irreversible.
  """
  @spec erase(term()) :: :ok
  def erase(subject) do
    # The tombstone first. If the key is destroyed and the record of it is not,
    # a restored key store resurrects somebody with nothing left to say it
    # should not have. The other order is recoverable; this one is not.
    unless erased?(subject), do: record(subject)
    Keyring.destroy(subject)
  end

  @doc "Has this subject been erased? Answered from the tombstones, not the keys."
  @spec erased?(term()) :: boolean()
  def erased?(subject), do: subject in erased()

  @doc """
  Everyone who has been erased.

  This is what a keyring reconciles against when it opens, so a key store
  restored from before an erasure is corrected rather than trusted.
  """
  @spec erased() :: [term()]
  def erased do
    {:ok, ledger} = Ledger.open(@ledger)

    Snapshot.open([ledger])
    |> Snapshot.find(attribute: @erased_at)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp record(subject) do
    {:ok, ledger} = Ledger.open(@ledger)

    if Ledger.tx(ledger) == 0 do
      Ledger.append(ledger, Attribute.seed() ++ Attribute.define(@erased_at, answers: "integer"))
    end

    Ledger.append(ledger, [{subject, @erased_at, System.system_time(:second)}])
  end

  @doc "Could facts about this entity be erased? True only if a subject was declared."
  @spec erasable?(Snapshot.t(), term()) :: boolean()
  def erasable?(%Snapshot{} = snapshot, id),
    do: Snapshot.value(snapshot, id, @subject) != nil

  # ── what the ledger uses ───────────────────────────────────────────────────

  @doc false
  # Called on the write path with whatever the ledger already knows about this
  # entity's owner. Nothing is encrypted unless a subject was declared first.
  def protect(answer, nil), do: answer

  def protect(answer, subject) do
    # A fresh data key per fact, wrapped by the subject's key. The wrapped key
    # travels in the fact: it is noise without the KEK, so it needs no store of
    # its own and nothing durable is held in memory.
    dek = :crypto.strong_rand_bytes(32)
    {:ok, wrapped} = Keyring.wrap(dek, subject)

    iv = :crypto.strong_rand_bytes(12)
    plain = :erlang.term_to_binary(answer)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plain, <<>>, true)

    {:sealed, subject, wrapped, iv, tag, cipher}
  end

  @doc false
  def reveal({:sealed, subject, wrapped, iv, tag, cipher}) do
    case Keyring.unwrap(wrapped, subject) do
      {:ok, dek} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, cipher, <<>>, tag, false) do
          :error -> :erased
          plain -> :erlang.binary_to_term(plain)
        end

      :forgotten ->
        :erased
    end
  end

  def reveal(answer), do: answer

  @doc false
  def reveal_fact(%Fact{value: {:sealed, _, _, _, _, _}} = fact),
    do: %{fact | value: reveal(fact.value)}

  def reveal_fact(%Fact{} = fact), do: fact
end
