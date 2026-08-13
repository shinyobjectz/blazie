defmodule Blazie.Blob do
  @moduledoc """
  Bytes that are too big to be a value, standing where a value goes (`blb`).

  An image, a video, a file, a checkout. The fact holds a *reference* — a key, a
  hash, a size — and the bytes live in object storage. That split is forced
  rather than chosen: a value goes into the append-only log, nothing in the log
  is ever rewritten, and every fact is held resident in memory. A five-megabyte
  value would be five megabytes in the log forever and five megabytes resident
  in every node that opened the world.

      ada.avatar = blob            -- the reference is the value
      print(ada.avatar.bytes)      -- 40310
      print(ada.avatar.hash)       -- "sha256:6f4b…"

  ## Content-addressed, so the same bytes are stored once

  The key is derived from the hash, so writing the same bytes twice writes one
  object and two facts. That also makes a blob immutable in the way everything
  else here is: the bytes a hash names cannot change, so a reference read at an
  old snapshot fetches what it fetched then.

  ## Which side of the fence

  A formula gets the reference and cannot fetch it — reaching object storage is
  reaching outside, and a formula has no network by construction. A job can. So
  "resize every avatar" is a job, "how many avatars are there" is a formula, and
  the line is the one everything else obeys rather than a new one.

  ## Erasure still reaches it

  Bytes are sealed under the subject's key, the same envelope that seals a
  fact's value. Erasing a subject destroys that key, and the object becomes
  noise without anybody rewriting or deleting it — which is what lets a backup
  taken before an erasure stay valid afterwards.
  """

  alias Blazie.Snapshot

  @enforce_keys [:key, :hash, :bytes]
  defstruct [:key, :hash, :bytes, :media_type]

  @type t :: %__MODULE__{
          key: String.t(),
          hash: String.t(),
          bytes: non_neg_integer(),
          media_type: String.t() | nil
        }

  @type refusal :: %{problem: atom(), repair: String.t()}

  @prefix "blobs/"

  @doc "Where blobs live in the bucket. Pinned by a test: objects exist under it."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  The reference for a run of bytes.

  Does not store anything — this is the naming half, and it is pure so that a
  caller can know the key before deciding whether it already has it.
  """
  @spec describing(binary(), keyword()) :: t()
  def describing(bytes, opts \\ []) when is_binary(bytes) do
    hash = "sha256:" <> (bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))

    %__MODULE__{
      key: key_for(hash),
      hash: hash,
      bytes: byte_size(bytes),
      media_type: Keyword.get(opts, :media_type)
    }
  end

  @doc """
  Check a reference a caller sent.

  A caller may write one — unlike a symbol, which only a formula may produce —
  because the bytes came from outside and nothing derived them. What it may not
  do is lie about them, so the hash has to look like a hash and the size like a
  size. Whether the object is actually there is not checked here: that is a
  question for whoever fetches it, and answering it at write time would mean a
  network call inside an append.
  """
  @spec check(t()) :: :ok | {:error, refusal()}
  def check(%__MODULE__{hash: "sha256:" <> digest, bytes: bytes, key: key})
      when is_integer(bytes) and bytes >= 0 and is_binary(key) do
    if String.length(digest) == 64 and String.match?(digest, ~r/^[0-9a-f]+$/) do
      :ok
    else
      {:error,
       %{
         problem: :not_a_hash,
         repair: "A blob's hash is `sha256:` and sixty-four lowercase hex characters."
       }}
    end
  end

  def check(%__MODULE__{}),
    do:
      {:error,
       %{
         problem: :not_a_blob,
         repair:
           "A blob is a key, a `sha256:` hash and a byte count. Store the bytes first and " <>
             "write what you got back."
       }}

  @doc """
  Fetch the bytes this names, and refuse them if they are not what it claimed.

  Reaching outside, so this belongs to a job — and the hash is checked on the
  way back rather than trusted. A reference is content-addressed, so bytes that
  do not hash to their key are not "the wrong version", they are somebody
  else's bytes under this name, and running them would be running whatever the
  bucket happened to hold.

  That check is the difference between a sandbox running the image a job
  declared and a sandbox running whatever answered.
  """
  @spec fetch(t(), module(), keyword()) :: {:ok, binary()} | {:error, refusal()}
  def fetch(%__MODULE__{} = blob, target, opts) do
    case target.get(opts, blob.key) do
      {:ok, bytes} -> verify(blob, bytes)
      {:error, :missing} -> {:error, missing(blob)}
      {:error, why} -> {:error, %{problem: :unreachable, repair: inspect(why)}}
    end
  end

  defp verify(%__MODULE__{} = blob, bytes) do
    actual = describing(bytes)

    cond do
      actual.hash != blob.hash ->
        {:error,
         %{
           problem: :not_those_bytes,
           repair:
             "#{blob.key} holds bytes hashing to #{actual.hash}, not #{blob.hash}. A blob is " <>
               "content-addressed, so this is not a stale version — it is different content " <>
               "under the same name."
         }}

      actual.bytes != blob.bytes ->
        {:error,
         %{
           problem: :wrong_size,
           repair: "#{blob.key} is #{actual.bytes} bytes, not #{blob.bytes}."
         }}

      true ->
        {:ok, bytes}
    end
  end

  defp missing(%__MODULE__{} = blob) do
    %{
      problem: :no_such_blob,
      repair:
        "Nothing is stored at #{blob.key}. The fact naming it is still true — it says what " <>
          "the bytes were — but the object is gone."
    }
  end

  @doc """
  Does the object this names still exist, and is it the size it claims?

  Reaching outside, so this belongs to a job. It is the audit a formula cannot
  do and should not: a reference whose object has gone is a dangling fact, and
  the only honest way to find one is to look.
  """
  @spec present?(t(), module(), keyword()) :: boolean()
  def present?(%__MODULE__{} = blob, target, opts) do
    case target.get(opts, blob.key) do
      {:ok, bytes} -> byte_size(bytes) == blob.bytes
      _ -> false
    end
  end

  @doc "Every blob referenced anywhere in a snapshot, deduplicated by key."
  @spec referenced(Snapshot.t()) :: [t()]
  def referenced(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.find([])
    |> Enum.flat_map(fn
      %{value: %__MODULE__{} = blob} -> [blob]
      _ -> []
    end)
    |> Enum.uniq_by(& &1.key)
  end

  # Sharded two characters deep, because a bucket listing with a million keys
  # under one prefix is a bucket listing nobody can page through usefully.
  defp key_for("sha256:" <> digest) do
    <<a::binary-size(2), b::binary-size(2), _rest::binary>> = digest
    "#{@prefix}#{a}/#{b}/#{digest}"
  end
end
