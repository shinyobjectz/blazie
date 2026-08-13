defmodule Blazie.BlobTest do
  @moduledoc """
  Bytes too big to be a value.

  The split this exists to enforce: the fact holds a reference, object storage
  holds the bytes. A five-megabyte value would be five megabytes in an
  append-only log forever and five megabytes resident in every node that opened
  the world, so the size of what a fact can hold is a real boundary rather than
  a preference.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Blob, Lua, Snapshot, Wire, World}

  setup do
    name = "blob-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)
    %{world: world, name: name, snapshot: Snapshot.open([world])}
  end

  describe "naming bytes" do
    test "the same bytes get the same key, so they are stored once" do
      a = Blob.describing("hello")
      b = Blob.describing("hello")

      assert a.key == b.key
      assert a.hash == b.hash
      assert a.bytes == 5
    end

    test "different bytes get different keys" do
      refute Blob.describing("hello").key == Blob.describing("goodbye").key
    end

    test "the key is sharded, so a listing is pageable" do
      %{key: key, hash: "sha256:" <> digest} = Blob.describing("hello")

      <<a::binary-size(2), b::binary-size(2), _::binary>> = digest
      assert key == "blobs/#{a}/#{b}/#{digest}"
    end

    test "naming bytes stores nothing" do
      # Pure on purpose: a caller can know the key before deciding whether it
      # already holds the object.
      assert %Blob{} = Blob.describing(:crypto.strong_rand_bytes(64))
    end
  end

  describe "what may cross the wire" do
    test "a caller may write a blob, unlike a symbol" do
      sent = %{
        "id" => "ada",
        "attribute" => "avatar",
        "value" => %{
          "$blob" => %{
            "key" =>
              "blobs/2c/f2/2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            "hash" => "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            "bytes" => 5,
            "media_type" => "image/png"
          }
        }
      }

      assert {:ok, {"ada", "avatar", %Blob{bytes: 5, media_type: "image/png"}}} =
               Wire.assertion(sent)
    end

    test "a reference that is not one is refused with a repair" do
      for bad <- [
            %{"key" => "k", "hash" => "not-a-hash", "bytes" => 5},
            %{"key" => "k", "hash" => "sha256:tooshort", "bytes" => 5},
            %{"key" => "k", "hash" => "sha256:" <> String.duplicate("Z", 64), "bytes" => 5}
          ] do
        assert {:error, refusal} =
                 Wire.assertion(%{"id" => 1, "attribute" => "x", "value" => %{"$blob" => bad}})

        assert refusal.repair != ""
      end
    end

    test "a blob goes back out as a blob" do
      blob = Blob.describing("hello", media_type: "text/plain")
      fact = %Blazie.Fact{id: "ada", attribute: "avatar", value: blob, tx: 1, by: nil}

      assert %{"value" => %{"$blob" => out}} = Wire.fact(fact)
      assert out["hash"] == blob.hash
      assert out["bytes"] == 5
    end
  end

  describe "in a world" do
    test "a reference is a small fact, whatever the bytes are", ctx do
      big = Blob.describing(:crypto.strong_rand_bytes(5_000_000))

      {:ok, _tx} =
        World.append(ctx.world, Blazie.Attribute.define("avatar") ++ [{"ada", "avatar", big}])

      snapshot = Snapshot.open([ctx.world])
      assert %Blob{bytes: 5_000_000} = Snapshot.value(snapshot, "ada", "avatar")

      # The point: five megabytes named, and the value stored is a reference.
      stored = :erlang.term_to_binary(Snapshot.value(snapshot, "ada", "avatar"))
      assert byte_size(stored) < 500
    end

    test "every blob a snapshot references can be listed", ctx do
      one = Blob.describing("one")
      two = Blob.describing("two")

      {:ok, _tx} =
        World.append(
          ctx.world,
          Blazie.Attribute.define("avatar") ++
            [{"ada", "avatar", one}, {"grace", "avatar", two}, {"alan", "avatar", one}]
        )

      referenced = Blob.referenced(Snapshot.open([ctx.world]))

      # Deduplicated: alan and ada share bytes, so there is one object.
      assert length(referenced) == 2
    end
  end

  describe "from Lua" do
    test "a blob reads as an ordinary table", ctx do
      blob = Blob.describing("hello", media_type: "image/png")

      {:ok, _tx} =
        World.append(ctx.world, Blazie.Attribute.define("avatar") ++ [{"ada", "avatar", blob}])

      snapshot = Snapshot.open([ctx.world])

      assert {:ok, 5, _} = Lua.Binding.run("return ada.avatar.bytes", snapshot)
      assert {:ok, "image/png", _} = Lua.Binding.run("return ada.avatar.media_type", snapshot)
      assert {:ok, hash, _} = Lua.Binding.run("return ada.avatar.hash", snapshot)
      assert hash == blob.hash
    end

    test "a formula cannot fetch the bytes", ctx do
      # There is nothing to fetch WITH — a formula has no network by
      # construction, so this is the fence rather than a rule about blobs.
      assert {:ok, nil, _} = Lua.Binding.run("return http", ctx.snapshot)
    end
  end
end
