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

  alias Blazie.{Attribute, Fact, Keyring, World, Snapshot}

  @subject "subject"
  @erased_at "erased_at"
  @world "$erasures"

  @doc "The attribute an entity declares its owner with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed, do: Attribute.define(@subject, answers: "name")

  @doc "The world tombstones are written to."
  @spec world() :: String.t()
  def world, do: @world

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
    {:ok, world} = World.open(@world)

    Snapshot.open([world])
    |> Snapshot.find(attribute: @erased_at)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp record(subject) do
    {:ok, world} = World.open(@world)

    if World.tx(world) == 0 do
      World.append(world, Attribute.seed() ++ Attribute.define(@erased_at, answers: "integer"))
    end

    World.append(world, [{subject, @erased_at, System.system_time(:second)}])
  end

  @doc "Could facts about this entity be erased? True only if a subject was declared."
  @spec erasable?(Snapshot.t(), term()) :: boolean()
  def erasable?(%Snapshot{} = snapshot, id),
    do: Snapshot.value(snapshot, id, @subject) != nil

  # ── what the world uses ───────────────────────────────────────────────────

  @doc false
  # Called on the write path with whatever the world already knows about this
  # entity's owner. Nothing is encrypted unless a subject was declared first.
  #
  # `bound` is {world, id, attribute, tx} — WHERE this sealed answer belongs,
  # authenticated into the ciphertext as AAD. Without it any sealed answer of
  # a subject was a valid sealed answer for any other fact of that subject: a
  # writer who could reach the bytes could splice one fact's answer onto
  # another and it decrypted cleanly (C6, reproduced). A tuple, never a map,
  # because the AAD must be the same bytes at reveal and EEP-18 lets a map's
  # pair order change between OTP releases.
  def protect(answer, nil, _bound), do: answer

  def protect(answer, subject, {_world, _id, _attribute, _tx} = bound) do
    # A fresh data key per fact, wrapped by the subject's key. The wrapped key
    # travels in the fact: it is noise without the KEK, so it needs no store of
    # its own and nothing durable is held in memory.
    dek = :crypto.strong_rand_bytes(32)
    {:ok, wrapped} = Keyring.wrap(dek, subject)

    iv = :crypto.strong_rand_bytes(12)
    plain = :erlang.term_to_binary(answer)
    aad = :erlang.term_to_binary(bound)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plain, aad, true)

    {:sealed, subject, wrapped, iv, tag, cipher, :bound}
  end

  @doc false
  # A failed reveal answers `:erased` IF AND ONLY IF a tombstone says the
  # subject was erased. Every other failure — a flipped bit, a truncated blob,
  # a key store restored under the wrong master, a wrapped key that opened but
  # did not authenticate — is `:unreadable`, because reporting corruption as a
  # completed lawful deletion is the one confusion this module exists to never
  # make (C5, reproduced with a single flipped bit).
  def reveal({:sealed, subject, wrapped, iv, tag, cipher, :bound}, bound) do
    case Keyring.unwrap(wrapped, subject) do
      {:ok, dek} ->
        aad = :erlang.term_to_binary(bound)

        case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, cipher, aad, tag, false) do
          :error -> failed(subject)
          plain -> decoded(plain)
        end

      :forgotten ->
        failed(subject)
    end
  end

  # The shape written before answers were bound to their fact. Revealed with
  # the empty AAD it was sealed under — a fact is immutable, so what was
  # written unbound stays unbound; only what is written from now on carries
  # the binding. The C6 property therefore holds for every fact this code
  # writes, and the legacy shape is readable rather than silently reachable
  # by new writes.
  def reveal({:sealed, subject, wrapped, iv, tag, cipher}, _bound) do
    case Keyring.unwrap(wrapped, subject) do
      {:ok, dek} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, cipher, <<>>, tag, false) do
          :error -> failed(subject)
          plain -> decoded(plain)
        end

      :forgotten ->
        failed(subject)
    end
  end

  # The plaintext authenticated, so these bytes were sealed by somebody who
  # held the key — but a restored key store can be the attacker's, and then
  # the plaintext is theirs too. `:safe` so it cannot mint atoms (C7); a
  # decode that fails is corruption, and corruption already has a name here.
  defp decoded(plain) do
    :erlang.binary_to_term(plain, [:safe])
  rescue
    _error -> :unreadable
  end

  def reveal(answer, _bound), do: answer

  # Erased only on the tombstone's say-so. `erased?/1` reads the `$erasures`
  # world, which is safe from every world except `$erasures` itself — where a
  # read would be a call back into the process doing the revealing. Nothing
  # sealed can exist there once it is unnameable, so that world answers
  # `:unreadable` without asking.
  defp failed(subject) do
    if erased?(subject), do: :erased, else: :unreadable
  end

  @doc false
  def reveal_fact(fact, world \\ nil)

  def reveal_fact(%Fact{value: {:sealed, _, _, _, _, _}} = fact, _world),
    do: %{fact | value: reveal(fact.value, nil)}

  def reveal_fact(%Fact{value: {:sealed, _, _, _, _, _, :bound}} = fact, world) do
    if world == @world do
      %{fact | value: :unreadable}
    else
      %{fact | value: reveal(fact.value, {world, fact.id, fact.attribute, fact.tx})}
    end
  end

  def reveal_fact(%Fact{} = fact, _world), do: fact
end
