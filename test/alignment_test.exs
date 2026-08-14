defmodule Blazie.AlignmentTest do
  @moduledoc """
  The two ontologies stay paired AND separate, and the pairing is data.

  The blazie word list is pinned here from the ontology database's own
  answer — so renaming a word breaks this test instead of silently
  orphaning an alignment row, which is the drift this file exists to catch.
  Socialite's codes are validated by shape (their own board resolves them);
  and no vendor may appear anywhere in the table, because vendors are not
  vocabulary on either side.
  """
  use ExUnit.Case, async: true

  @table Path.expand("../docs/alignment.toml", __DIR__)

  # `just monty onto list`, 2026-08-14. Update deliberately, with the
  # ontology — that is the point.
  @blazie_words ~w(attribute fact snapshot ask blob cluster directive formula
                   job open refinement run studio symbol watch world write) ++
                  ["control plane", "generative programming"]

  @vendors ~w(turbopuffer upcloud cloudflare modal openai anthropic fly exa
              parallel brave pinecone)

  defp rows do
    # A minimal TOML reading for exactly this file's shape — a dependency
    # for a config parser would be the heavier choice.
    @table
    |> File.read!()
    |> String.split("[[pair]]", trim: true)
    |> Enum.drop(1 - 1)
    |> Enum.filter(&String.contains?(&1, "blazie ="))
    |> Enum.map(fn block ->
      for line <- String.split(block, "\n"),
          [key, value] <- [String.split(line, "=", parts: 2)],
          into: %{} do
        {String.trim(key), String.trim(value) |> String.trim("\"")}
      end
    end)
  end

  test "every blazie word in the table is a word blazie's ontology adopted" do
    for row <- rows(), Map.has_key?(row, "blazie") do
      assert row["blazie"] in @blazie_words,
             "#{inspect(row["blazie"])} is not a blazie word — renamed, or invented?"
    end
  end

  test "every socialite code is code-shaped, and every row carries its seam" do
    for row <- rows(), Map.has_key?(row, "socialite") do
      assert row["socialite"] =~ ~r/^[a-z]{3}(\.[a-z]+)?$/,
             "#{inspect(row["socialite"])} is not a socialite code"

      assert String.length(row["seam"] || "") > 10, "a pairing without a seam is a guess"
      assert row["rules"] in ["blazie", "socialite"], "somebody's word rules at every seam"
      assert String.length(row["never_cross"] || "") > 10
    end
  end

  test "no vendor is vocabulary, in the table least of all" do
    text = File.read!(@table) |> String.downcase()

    for vendor <- @vendors do
      # Word-bounded, learned immediately: "exa" lives inside "exactly".
      refute text =~ ~r/\b#{vendor}\b/, "#{vendor} appears in the alignment table"
    end
  end

  test "the remit decision is recorded, dated, and ticketed" do
    text = File.read!(@table)
    assert text =~ ~s(name = "remit")
    assert text =~ "control-plane vocabulary only"
    assert text =~ "bla-8a8s"
  end
end
