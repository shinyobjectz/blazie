defmodule LazyRiver.WireTest do
  @moduledoc """
  Translating between what travels and what the engine holds.

  Two things are load-bearing here. A caller must not be able to grow the atom
  table, and a caller must not be able to claim a fact was derived — a client
  is the outside world by definition, so everything it writes names no formula.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Fact, Symbol, Wire}

  describe "a caller cannot grow the atom table" do
    test "no attribute name a caller sends ever becomes an atom" do
      # The invariant is structural rather than checked: attributes are binaries
      # all the way down, so there is no path from a request to the atom table.
      for n <- 1..100 do
        name = "attribute_from_a_request_#{n}"

        assert {:ok, [attribute: ^name]} = Wire.pattern(%{"attribute" => name})
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end

    test "an attribute that is not a name is refused" do
      for not_a_name <- [42, "", %{}, nil, ["height"]] do
        assert {:error, refusal} = Wire.pattern(%{"attribute" => not_a_name})
        assert refusal.problem == :unknown_attribute
      end
    end

    test "whether it is defined is the ledger\'s question, not this one" do
      # Wire says it is a name. The vocabulary check on write says whether it
      # means anything, and that check reads a snapshot rather than the VM.
      assert {:ok, [attribute: "never_defined_anywhere"]} =
               Wire.pattern(%{"attribute" => "never_defined_anywhere"})
    end
  end

  describe "a caller cannot claim a fact was derived" do
    test "an assertion is always three wide, whatever was sent" do
      assert {:ok, {42, "height", 180}} =
               Wire.assertion(%{"id" => 42, "attribute" => "height", "answer" => 180})
    end

    test "a by field is refused rather than ignored" do
      sent = %{"id" => 42, "attribute" => "height", "answer" => 180, "by" => "potion"}

      assert {:error, refusal} = Wire.assertion(sent)
      assert refusal.problem == :cannot_claim_derivation
    end
  end

  describe "a snapshot name travels" do
    test "it round-trips through the wire and back" do
      name = %{"tenant-7" => 3, "shared" => 12}

      assert {:ok, decoded} = Wire.snapshot_name(name)
      assert Wire.encode_snapshot_name(decoded) == name
    end

    test "a transaction that is not a number is refused" do
      assert {:error, refusal} = Wire.snapshot_name(%{"tenant-7" => "three"})
      assert refusal.problem == :bad_transaction
    end
  end

  describe "a fact travels" do
    test "its attribute goes out as a string" do
      fact = %Fact{id: 42, attribute: "height", answer: 180, tx: 3}

      assert Wire.fact(fact) == %{
               "id" => 42,
               "attribute" => "height",
               "answer" => 180,
               "tx" => 3,
               "by" => nil
             }
    end

    test "what produced it goes out named" do
      fact = %Fact{id: 42, attribute: "height", answer: 180, tx: 3, by: :doubled}
      assert Wire.fact(fact)["by"] == "doubled"
    end

    test "a symbol answer is tagged, so it cannot be mistaken for a map" do
      fact = %Fact{
        id: 42,
        attribute: "height",
        answer: Symbol.new("potion_256", [0.1, 0.2]),
        tx: 3,
        by: :potion
      }

      assert %{"$symbol" => %{"space" => "potion_256", "values" => [0.1, 0.2]}} =
               Wire.fact(fact)["answer"]
    end
  end

  describe "ids travel as they are" do
    test "numbers and strings both survive" do
      for id <- [42, "a-string-id", -1] do
        assert {:ok, {^id, "height", 1}} =
                 Wire.assertion(%{"id" => id, "attribute" => "height", "answer" => 1})
      end
    end

    test "an id that is not a number or a string is refused" do
      assert {:error, refusal} =
               Wire.assertion(%{"id" => %{"nested" => 1}, "attribute" => "height", "answer" => 1})

      assert refusal.problem == :bad_id
    end
  end
end
