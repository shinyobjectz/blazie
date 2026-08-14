defmodule Blazie.StoreDamageTest do
  @moduledoc """
  The log opens whole, whatever the tail looks like.

  The recovery contract used to be tested against one damage shape — a clean
  truncation at a write boundary, which is the one shape a killed PROCESS
  leaves, because the page cache survives it. A killed MACHINE leaves the
  others: a zero-filled tail (ext4's delayed allocation is famous for it, and
  crc32 of empty is 0 so eight zero bytes parsed as a valid record and the
  decode raised — C12), a garbage tail, a tail that repeats earlier bytes
  (which is what an overlapping restore produces — C8), and a checkpoint
  describing a log longer than the one on disk (C3, a crash-loop).

  So this walks EVERY prefix length crossed with every damage shape —
  exhaustive, not sampled, the ALICE idea reduced to one file — and asserts
  the same claim each time: `open/2` succeeds and replays exactly the
  transactions wholly contained in the valid prefix.

  And because these bytes can arrive from a backup bucket, the payloads are
  hostile too: a record that would mint an atom is damage (C7), a record
  carrying a function term is damage, and neither is allowed to cost more
  than the tail it arrived in.
  """
  # Serial, not async: the atom test reads a VM-global counter, and a
  # concurrent module minting an atom of its own is indistinguishable from
  # the payload doing it.
  use ExUnit.Case, async: false

  alias Blazie.{Fact, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "damage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A store with `n` transactions, one fact each, checkpointing eagerly so the
  # sidecar exists and participates. Answers the path, the checkpoint path,
  # and each transaction's {end_offset, facts}.
  defp grown(dir, n) do
    name = {:damage, System.unique_integer([:positive])}
    {:ok, state} = Store.File.open(name, dir: dir, checkpoint_every: 1)

    {state, spans} =
      Enum.reduce(1..n, {state, []}, fn i, {state, spans} ->
        facts = [%Fact{id: i, attribute: "n", value: i * 10, tx: i}]
        {:ok, state} = Store.File.append(state, facts)
        {state, [{state.bytes, facts} | spans]}
      end)

    :ok = Store.File.close(state)
    path = Path.join(dir, Store.File.filename(name))
    {path, path <> ".checkpoint", Enum.reverse(spans)}
  end

  # What a correct open must replay from the first `p` bytes: every
  # transaction that landed wholly inside them.
  defp expected(spans, p) do
    spans |> Enum.filter(fn {ended, _facts} -> ended <= p end) |> Enum.flat_map(&elem(&1, 1))
  end

  defp reopened(dir, path, checkpoint, bytes) do
    copy = Path.join(dir, "copy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(copy)
    File.write!(Path.join(copy, Path.basename(path)), bytes)

    if File.exists?(checkpoint),
      do: File.cp!(checkpoint, Path.join(copy, Path.basename(checkpoint)))

    # The same name re-derived from the filename is not available, so open by
    # the copied file's own name: filename/1 is injective, so opening with the
    # original name against the copy directory finds the copied file.
    name =
      path
      |> Path.basename(".ledger")
      |> Base.url_decode64!(padding: false)
      |> :erlang.binary_to_term()

    {:ok, state} = Store.File.open(name, dir: copy)
    replay = Store.File.replay(state)
    :ok = Store.File.close(state)
    replay
  end

  describe "every prefix, every damage shape" do
    test "truncated, zero-filled, garbage-filled and repeated tails all open", %{dir: dir} do
      {path, checkpoint, spans} = grown(dir, 6)
      whole = File.read!(path)
      {first_end, _} = hd(spans)
      first_record = binary_part(whole, 12, first_end - 12)

      damages = [
        {:truncated, fn prefix -> prefix end},
        {:zeros, fn prefix -> prefix <> :binary.copy(<<0>>, 64) end},
        {:garbage, fn prefix -> prefix <> :crypto.strong_rand_bytes(64) end},
        {:repeat, fn prefix -> prefix <> first_record end}
      ]

      for p <- 0..byte_size(whole), {shape, damage} <- damages do
        # Repeating the first record at its own original offset recreates the
        # true prefix — there the repeat IS valid bytes, and the claim moves
        # with it.
        wanted =
          if shape == :repeat and p == 12,
            do: expected(spans, first_end),
            else: expected(spans, p)

        replay = reopened(dir, path, checkpoint, damage.(binary_part(whole, 0, p)))

        assert Enum.map(replay, &{&1.id, &1.value}) == Enum.map(wanted, &{&1.id, &1.value}),
               "prefix #{p} with #{shape} tail replayed wrong"
      end
    end

    test "a checkpoint describing a longer log is dropped, not believed", %{dir: dir} do
      # C3's reproduction: the log truncated shorter than the checkpoint's
      # offset. This used to raise from inside init — a crash-loop only an
      # operator could end — because the careful fallback had already
      # returned by the time the offset reached past the end.
      {path, checkpoint, spans} = grown(dir, 6)
      whole = File.read!(path)
      {third_end, _} = Enum.at(spans, 2)

      replay = reopened(dir, path, checkpoint, binary_part(whole, 0, third_end))
      assert length(replay) == 3
    end
  end

  describe "a hostile payload is damage, not a guest" do
    test "a record that would mint an atom does not, and does not open the door", %{dir: dir} do
      {path, checkpoint, _spans} = grown(dir, 2)
      whole = File.read!(path)
      <<"BLZ2", generation::64, _::binary>> = whole

      # An atom that does not exist in this VM, encoded by hand — the name
      # only ever lives here as a binary, so the test cannot vacuously pass
      # by having created it (the first version of this check elsewhere
      # reported zero atoms created for exactly that reason).
      name = "c7_never_#{System.unique_integer([:positive])}"
      payload = <<131, 119, byte_size(name), name::binary>>

      crc = :erlang.crc32([<<generation::64, byte_size(whole)::64>>, payload])
      crafted = whole <> <<byte_size(payload)::32, crc::32, payload::binary>>

      # Once to warm: the first open on a fresh VM loads modules, and loading
      # mints atoms that have nothing to do with the payload. The measured
      # open is the second.
      _ = reopened(dir, path, checkpoint, crafted)

      before = :erlang.system_info(:atom_count)
      replay = reopened(dir, path, checkpoint, crafted)

      assert :erlang.system_info(:atom_count) == before,
             "opening a ledger minted atoms from its payload"

      assert length(replay) == 2
    end

    test "a record carrying a function term is refused by shape, not executed", %{dir: dir} do
      {path, checkpoint, spans} = grown(dir, 2)
      whole = File.read!(path)
      <<"BLZ2", generation::64, _::binary>> = whole

      # `:safe` does not block function terms — measured, and surprising
      # enough to check — so the shape gate is what stands between a restored
      # bucket and a callable value in somebody's world.
      payload =
        :erlang.term_to_binary([
          %Fact{id: 3, attribute: "n", value: fn -> :boom end, tx: 3}
        ])

      crc = :erlang.crc32([<<generation::64, byte_size(whole)::64>>, payload])
      crafted = whole <> <<byte_size(payload)::32, crc::32, payload::binary>>

      replay = reopened(dir, path, checkpoint, crafted)
      assert length(replay) == 2
      refute Enum.any?(replay, &is_function(&1.value))
      assert length(spans) == 2
    end
  end

  describe "what was already written stays readable" do
    test "a legacy file — payload-only CRC, no header — opens, appends, and survives a zero tail",
         %{dir: dir} do
      name = {:legacy, System.unique_integer([:positive])}
      path = Path.join(dir, Store.File.filename(name))

      # Written byte for byte as the previous code wrote it, never through
      # today's writer — the old-shapes lesson applied to the file format.
      legacy_record = fn facts ->
        payload = :erlang.term_to_binary(facts)
        <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
      end

      File.write!(
        path,
        legacy_record.([%Fact{id: 1, attribute: "n", value: 10, tx: 1}]) <>
          legacy_record.([%Fact{id: 2, attribute: "n", value: 20, tx: 2}])
      )

      {:ok, state} = Store.File.open(name, dir: dir)
      assert length(Store.File.replay(state)) == 2

      # New appends to a legacy file stay legacy — one file, one rule.
      {:ok, state} = Store.File.append(state, [%Fact{id: 3, attribute: "n", value: 30, tx: 3}])
      :ok = Store.File.close(state)

      # The ext4 crash shape, on the legacy file: still opens, still whole.
      File.write!(path, File.read!(path) <> :binary.copy(<<0>>, 64))

      {:ok, state} = Store.File.open(name, dir: dir)
      assert Enum.map(Store.File.replay(state), & &1.value) == [10, 20, 30]
      :ok = Store.File.close(state)
    end
  end
end
