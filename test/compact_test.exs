defmodule Blazie.CompactTest do
  @moduledoc """
  Compaction reclaims erased content and changes nothing else.

  The properties, each a thing a wrong compaction would break: every live
  answer is identical after; every erased answer is still `:erased`; every
  old snapshot name still resolves (the guarantee the store exists to keep);
  the file is smaller by the ciphertext; and the compacted file opens under
  the damage rules like any other, because it is just a fresh generation.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Compact, Erasure, Keyring, Snapshot, Store, World}

  setup do
    dir = Path.join(System.tmp_dir!(), "compact-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "erased ciphertext becomes a tombstone; live answers are untouched", %{dir: dir} do
    name = {:compact, System.unique_integer([:positive])}
    subject = "person-#{System.unique_integer([:positive])}"
    on_exit(fn -> Keyring.destroy(subject) end)

    {:ok, world} = World.open(name, store: {Store.File, dir: dir})
    {:ok, _} = World.append(world, Attribute.seed() ++ Erasure.seed())
    {:ok, _} = World.append(world, Attribute.define("secret", answers: "any"))
    {:ok, _} = World.append(world, Attribute.define("public", answers: "integer"))

    # An erased subject holding a big sealed value, and an unrelated public one.
    {:ok, _} = World.append(world, [{42, "subject", subject}])
    {:ok, _} = World.append(world, [{42, "secret", String.duplicate("x", 4_000)}])
    {:ok, name_before} = capture(world)
    {:ok, _} = World.append(world, [{99, "public", 180}])

    :ok = Erasure.erase(subject)
    :ok = World.close(name)

    size_before = File.stat!(Path.join(dir, Store.File.filename(name))).size

    assert {:ok, %{tombstoned: 1, reclaimed: reclaimed}} =
             Compact.erased(name, dir: dir, erased: %{subject => true})

    # It reclaimed most of a 4KB ciphertext.
    assert reclaimed > 3_000
    assert File.stat!(Path.join(dir, Store.File.filename(name))).size < size_before - 3_000

    # Reopen: the public answer is exactly what it was, the erased one is
    # still :erased, and the id still exists (the row was kept).
    {:ok, world} = World.open(name, store: {Store.File, dir: dir})
    on_exit(fn -> World.close(name) end)
    now = Snapshot.open([world])

    assert Snapshot.value(now, 99, "public") == 180
    assert Snapshot.value(now, 42, "secret") == :erased
    assert [_] = Snapshot.find(now, id: 42, attribute: "secret")

    # And an OLD snapshot name — taken before the erasure — still resolves,
    # and still answers :erased (the key is gone; that is the bounded break,
    # not a different answer). The guarantee held.
    {:ok, then} = Blazie.Snapshot.reopen(name_before)
    assert Snapshot.value(then, 42, "secret") == :erased
  end

  test "the compacted file opens whole and survives a zero-filled tail", %{dir: dir} do
    name = {:compact, System.unique_integer([:positive])}
    subject = "person-#{System.unique_integer([:positive])}"
    on_exit(fn -> Keyring.destroy(subject) end)

    {:ok, world} = World.open(name, store: {Store.File, dir: dir})
    {:ok, _} = World.append(world, Attribute.seed() ++ Erasure.seed())
    {:ok, _} = World.append(world, Attribute.define("v", answers: "integer"))
    {:ok, _} = World.append(world, [{1, "subject", subject}])
    {:ok, _} = World.append(world, [{1, "v", 7}])
    {:ok, _} = World.append(world, [{2, "v", 8}])
    :ok = Erasure.erase(subject)
    :ok = World.close(name)

    {:ok, _} = Compact.erased(name, dir: dir, erased: %{subject => true})

    # The compacted file is a fresh generation, so the damage rules apply to
    # it unchanged: a zero-filled tail is cut and the world opens whole.
    path = Path.join(dir, Store.File.filename(name))
    File.write!(path, File.read!(path) <> :binary.copy(<<0>>, 64))

    {:ok, world} = World.open(name, store: {Store.File, dir: dir})
    on_exit(fn -> World.close(name) end)
    assert Snapshot.value(Snapshot.open([world]), 2, "v") == 8
  end

  defp capture(world) do
    {:ok, Snapshot.name(Snapshot.open([world]))}
  end
end
