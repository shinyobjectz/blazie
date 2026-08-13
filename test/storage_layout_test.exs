defmodule Blazie.StorageLayoutTest do
  @moduledoc """
  The names on disk, pinned.

  Every other test in this suite creates a fresh world and reads it back with
  the code that wrote it, so all of them pass whatever the filename happens to
  be. That is not a gap in any one of them — it is the shape of the whole
  suite, and it means renaming a suffix looks like a clean refactor right up
  until a deployed node opens an empty directory and calls itself healthy.

  That happened. `ledger` became `world`, `".ledger"` went with it, and a node
  came up green beside 791KB of facts it could no longer see. Nothing failed.

  So these assert the literal strings, and they are deliberately the sort of
  test that looks redundant. A value here is a promise to data that already
  exists, and the only way to break it is to change it on purpose.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Backup, Store}

  test "a world's facts live in a `.ledger` file" do
    assert String.ends_with?(Store.File.filename("anything"), ".ledger")
  end

  test "the suffix does not depend on what a world is called" do
    for name <- ["main", "$vitals", {:tenant, 7}, 42] do
      assert String.ends_with?(Store.File.filename(name), ".ledger"),
             "#{inspect(name)} -> #{Store.File.filename(name)}"
    end
  end

  test "a backup copies segments under `ledgers/`" do
    # Every segment already in the bucket is under this prefix. Moving it would
    # not migrate a thing; it would orphan every backup anybody has taken.
    assert Backup.ledgers_prefix() == "ledgers/"
  end
end
