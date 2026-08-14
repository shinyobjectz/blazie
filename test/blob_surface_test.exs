defmodule Blazie.BlobSurfaceTest do
  @moduledoc """
  Storing bytes, and who is allowed to.

  `Blob` could name bytes and read them back and never store any — `fetch/3`
  took a target and nothing supplied one, so a blob was a word the database
  could not honour. That was true on the hand-built node too, checked rather
  than assumed, so this is new rather than restored.

  What matters most here is not that it works but who it works for: storing
  reaches the network, so it belongs to a job. A formula that could store would
  be a formula that reaches, and the whole fence is that a formula's world holds
  nothing to reach with.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Blob, Lua}

  setup do
    dir = Path.join(System.tmp_dir!(), "blob-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    held = Application.get_env(:blazie, :blob_target)
    Application.put_env(:blazie, :blob_target, {Blazie.Backup.Target.Directory, root: dir})

    on_exit(fn ->
      if held,
        do: Application.put_env(:blazie, :blob_target, held),
        else: Application.delete_env(:blazie, :blob_target)

      File.rm_rf(dir)
    end)

    %{dir: dir, target: Blazie.Backup.Target.Directory, opts: [root: dir]}
  end

  describe "a job may store bytes" do
    test "and gets back what to write down, never the bytes", %{dir: _dir} do
      {:ok, said} = Lua.run("local ref = blob('hello bytes')\nreturn ref", as: :job)

      assert %{"key" => key, "hash" => "sha256:" <> _, "bytes" => 11} = said
      assert String.starts_with?(key, Blob.prefix())

      # The reference is what becomes a fact. Five megabytes in the log forever
      # is the thing a blob exists to prevent.
      refute Map.has_key?(said, "content")
    end

    test "the same bytes twice are stored once", %{target: target, opts: opts} do
      {:ok, first} = Blob.store("identical", target, opts)
      {:ok, again} = Blob.store("identical", target, opts)

      # Content-addressed: the key comes from the hash, so an object already
      # under it IS the same object. This is why a blob read at an old
      # transaction cannot have changed underneath it.
      assert first.key == again.key
      assert first.hash == again.hash
    end

    test "and reading them back checks they are what was claimed", %{target: target, opts: opts} do
      {:ok, blob} = Blob.store("the real bytes", target, opts)

      assert {:ok, "the real bytes"} = Blob.fetch(blob, target, opts)
    end

    test "a media type travels with the reference", %{} do
      {:ok, said} = Lua.run("return blob('gif87a...', 'image/gif')", as: :job)

      assert said["media_type"] == "image/gif"
    end
  end

  describe "a formula may not" do
    test "because there is nothing there to call", %{} do
      # Not refused — absent. The fence is that a formula's world holds nothing
      # that reaches, so this is a nil index rather than a policy saying no.
      assert {:error, %{problem: problem}} = Lua.run("return blob('anything')", as: :formula)
      assert problem in [:raised, :not_lua]
    end

    test "and the name is not quietly an entity either", %{} do
      # `_G` turns unknown names into entities, which would make `blob` an empty
      # table rather than an absence. It is only bound for a job, so a formula
      # sees nothing — and a formula that could store would be one that reaches.
      assert {:ok, nil} =
               Lua.run("return type(blob) == 'function' and 'yes' or nil", as: :formula)
    end
  end

  describe "a cluster with nowhere to put bytes" do
    test "says so, with what to set", %{} do
      held = Application.get_env(:blazie, :blob_target)
      Application.delete_env(:blazie, :blob_target)

      on_exit(fn -> if held, do: Application.put_env(:blazie, :blob_target, held) end)

      {:ok, said} = Lua.run("local ref, why = blob('bytes')\nreturn why", as: :job)

      # A refusal that carries how to comply, like every other boundary here.
      assert said =~ "BLOB_BUCKET"
    end
  end
end
