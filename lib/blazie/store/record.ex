defmodule Blazie.Store.Record do
  @moduledoc """
  The one place the log's byte format lives.

  Two stores read and write the same files — `Store.File` holds everything
  resident, `Store.Paged` seeks — and the backup already learned what a
  second copy of a scan costs: it went stale the day the format grew a
  header and silently found nothing readable at all. So the format is here,
  once: the BLZ2 header, the offset-and-generation CRC, the size-zero
  refusal, the `:safe` decode and the fact-shape gate. A store composes
  these; it does not restate them.
  """

  alias Blazie.Fact

  @magic "BLZ2"
  @header_bytes 12

  @type mode :: {:v2, generation :: non_neg_integer()} | :legacy | :new

  @doc "The number of bytes a v2 header occupies."
  @spec header_bytes() :: pos_integer()
  def header_bytes, do: @header_bytes

  @doc "A fresh v2 header with a random generation."
  @spec header() :: {binary(), non_neg_integer()}
  def header do
    generation = :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()
    {<<@magic, generation::64>>, generation}
  end

  @doc "Which rules a file is read and written under, from its first bytes."
  @spec mode_of(binary()) :: mode()
  def mode_of(<<>>), do: :new
  def mode_of(<<@magic, generation::64, _::binary>>), do: {:v2, generation}
  def mode_of(_existing), do: :legacy

  @doc "Where records begin: after the header on v2, at zero before it."
  @spec base_of(mode()) :: non_neg_integer()
  def base_of({:v2, _generation}), do: @header_bytes
  def base_of(_mode), do: 0

  @doc "One record's bytes, CRC'd for its mode and its own offset."
  @spec encode(mode(), non_neg_integer(), binary()) :: binary()
  def encode(mode, offset, payload) do
    <<byte_size(payload)::32, crc(mode, offset, payload)::32, payload::binary>>
  end

  @doc "The record CRC: generation + own offset + payload under v2, payload alone before it."
  @spec crc(mode(), non_neg_integer(), binary()) :: non_neg_integer()
  def crc({:v2, generation}, offset, payload),
    do: :erlang.crc32([<<generation::64, offset::64>>, payload])

  def crc(_legacy, _offset, payload), do: :erlang.crc32(payload)

  @doc """
  Walk the records in `binary` starting at absolute offset `start`.

  Calls `fun.(transaction_facts, offset, record_bytes, acc)` for each valid
  record and answers `{acc, ended}` where `ended` is the absolute offset the
  log validly ends at — a torn, zero-sized, misplaced or malformed record is
  where reading stops, whatever lies past it.
  """
  @spec walk(binary(), non_neg_integer(), mode(), acc, ([Fact.t()],
                                                        non_neg_integer(),
                                                        pos_integer(),
                                                        acc ->
                                                          acc)) ::
          {acc, non_neg_integer()}
        when acc: term()
  def walk(binary, start, mode, acc, fun) when byte_size(binary) >= start do
    slice = binary_part(binary, start, byte_size(binary) - start)
    step(slice, mode, start, acc, fun)
  end

  def walk(_binary, start, _mode, acc, _fun), do: {acc, start}

  defp step(<<size::32, crc::32, payload::binary-size(size), rest::binary>>, mode, at, acc, fun)
       when size > 0 do
    with true <- crc(mode, at, payload) == crc,
         {:ok, transaction} <- decode(payload) do
      step(rest, mode, at + 8 + size, fun.(transaction, at, 8 + size, acc), fun)
    else
      _ -> {acc, at}
    end
  end

  defp step(_incomplete_tail, _mode, at, acc, _fun), do: {acc, at}

  @doc """
  A payload becomes one transaction — a list of facts in a shape some version
  of this code wrote — or `:torn`.

  `:safe` so bytes from a bucket cannot mint atoms, then conformance because
  `:safe` still decodes function terms: a payload that is not a list of facts
  whose terms are data is damage, and damage is where reading stops (C7).
  """
  @spec decode(binary()) :: {:ok, [Fact.t()]} | :torn
  def decode(payload) do
    rows = :erlang.binary_to_term(payload, [:safe])

    with true <- is_list(rows),
         facts = Enum.map(rows, &Fact.from_stored/1),
         true <- Enum.all?(facts, &stored_fact?/1) do
      {:ok, facts}
    else
      _ -> :torn
    end
  rescue
    _error -> :torn
  end

  @doc "Is this a fact as some version of this code stored one, holding only data?"
  @spec stored_fact?(term()) :: boolean()
  def stored_fact?(%Fact{} = fact) do
    is_binary(fact.attribute) and is_integer(fact.tx) and
      harmless?(fact.id) and harmless?(fact.value) and harmless?(fact.by)
  end

  def stored_fact?(_other), do: false

  @doc "Data, all the way down: no funs, pids, ports or references anywhere in the term."
  @spec harmless?(term()) :: boolean()
  def harmless?(term)
      when is_function(term) or is_pid(term) or is_port(term) or is_reference(term),
      do: false

  def harmless?([head | tail]), do: harmless?(head) and harmless?(tail)
  def harmless?([]), do: true

  def harmless?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.all?(&harmless?/1)

  def harmless?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> harmless?(key) and harmless?(value) end)
  end

  def harmless?(_term), do: true
end
