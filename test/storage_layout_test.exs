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

  test "a legacy world's facts live in a `.ledger` file" do
    # Legacy since P5, and pinned FOREVER: every disk that predates the flip
    # holds files under this suffix, and the migration door
    # (`World.open` → `Store.Migrate`) finds them by this exact name.
    assert String.ends_with?(Store.File.filename("anything"), ".ledger")
  end

  test "a SQLite world's facts live in a `.sqlite` file" do
    # The default layout since P5 — what the replicator's `pattern:` watches
    # and what `World.exists?` looks for first. Renaming it would not rename
    # anything; it would make every node look past its tenants at an empty
    # pattern and call itself healthy.
    assert String.ends_with?(Store.SQLite.filename("anything"), ".sqlite")
  end

  test "neither suffix depends on what a world is called" do
    for name <- ["main", "$vitals", {:tenant, 7}, 42] do
      assert String.ends_with?(Store.File.filename(name), ".ledger"),
             "#{inspect(name)} -> #{Store.File.filename(name)}"

      assert String.ends_with?(Store.SQLite.filename(name), ".sqlite"),
             "#{inspect(name)} -> #{Store.SQLite.filename(name)}"
    end
  end

  test "a backup copies segments under `ledgers/`" do
    # Every segment already in the bucket is under this prefix. Moving it would
    # not migrate a thing; it would orphan every backup anybody has taken.
    assert Backup.ledgers_prefix() == "ledgers/"
  end
end
