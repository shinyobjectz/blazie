defmodule Blazie.PromiseLedgerTest do
  @moduledoc """
  The standing audit against the two patterns that recurred all build long:
  built-but-wired-to-nothing, and checks-that-do-not-run-the-thing.

  Every admission a moduledoc makes — "not yet true", "not the production
  answer", "neither of those is here yet" — must be on the board or be a
  recorded decision, because an admission nobody tracks is a promise nobody
  keeps. The ledger below IS the tracking: a new admission phrase in lib/
  fails this test until it carries a ticket here, and a closed ticket whose
  admission still stands in the prose fails the sweep the other way when
  the paragraph is deleted.
  """
  use ExUnit.Case, async: true

  # Every phrase the tree uses to admit something is not yet true. Specific
  # on purpose: the first draft included "has never run" and caught a
  # sentence about seed read sets — a phrase generic enough to match prose
  # measures the prose, not the promises.
  @admissions [
    "Not yet true",
    "not the production answer",
    "neither of those is here yet",
    "deliberately not implemented",
    "nothing enforces",
    "nobody watches"
  ]

  # The ledger: file => {phrase it admits, the ticket or decision that owns it}.
  @owned %{
    "lib/blazie/job.ex" => {"Not yet true", "bla-pwjm"},
    "lib/blazie/store.ex" => {"neither of those is here yet", "bla-pp24"},
    "lib/blazie/cluster.ex" =>
      {"deliberately not implemented",
       "DECISION: distribution is out of scope on purpose — worlds owned by one writer " <>
         "make consensus the wrong problem; dispatch (Blazie.Dispatch) is the answer"},
    "lib/blazie/keyring/local.ex" =>
      {"not the production answer", "DECISION: Keyring.GCP is the production answer and ships"}
  }

  test "every admission in lib/ is owned by a ticket or a recorded decision" do
    found =
      Path.wildcard(Path.expand("../lib/**/*.ex", __DIR__))
      |> Enum.flat_map(fn path ->
        text = File.read!(path)
        rel = Path.relative_to(path, Path.expand("..", __DIR__))

        for phrase <- @admissions, String.contains?(text, phrase), do: {rel, phrase}
      end)

    for {file, phrase} <- found do
      assert Map.has_key?(@owned, file),
             "#{file} admits #{inspect(phrase)} and the promise ledger does not own it. " <>
               "Mint a ticket or record the decision in @owned."

      {owned_phrase, owner} = @owned[file]

      assert owned_phrase == phrase,
             "#{file}'s admission changed: the ledger owns #{inspect(owned_phrase)}, " <>
               "the file says #{inspect(phrase)}"

      assert owner =~ ~r/^(bla-[a-z0-9]{4}|DECISION: .{20,})/,
             "#{file}'s owner is neither a ticket nor a reasoned decision"
    end
  end

  test "everything the ledger owns still exists — a kept promise deletes its row" do
    for {file, {phrase, _owner}} <- @owned do
      path = Path.expand("../" <> file, __DIR__)
      assert File.exists?(path), "#{file} is gone; drop its ledger row"

      assert File.read!(path) =~ phrase,
             "#{file} no longer admits #{inspect(phrase)} — the promise was kept " <>
               "(or reworded); update the ledger so it stays true"
    end
  end
end
