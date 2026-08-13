defmodule Blazie.SymbolShimTest do
  @moduledoc """
  A symbol stored under the older shape still answers.

  `values` was a list of floats with no `norm`. It is a binary now, and nothing
  in a world is ever rewritten — so the old shape is still on disk anywhere a
  symbol was ever written, and every path that compares one has to go through
  the shim first.

  This tree has lost data three times to exactly this: `answer` became `value`
  and every production ledger stopped being readable, a sed ate `by_answer:`,
  and a filename suffix moved and hid 791KB. The suite was green for all three,
  because tests write with the same code they read. So this test does the one
  thing that catches it — it builds the OLD shape by hand.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Symbol, Wire}

  # What `Symbol.new/2` used to produce: a list, and no norm field.
  defp old_shape(space, values) do
    struct(Symbol, %{space: space, values: values, norm: nil})
  end

  test "an old-shape symbol reports its dimension" do
    assert Symbol.dimension(old_shape("s", [1.0, 2.0, 3.0])) == 3
  end

  test "an old-shape symbol can still be compared" do
    a = old_shape("s", [1.0, 0.0])
    b = old_shape("s", [1.0, 0.0])

    assert {:ok, score} = Symbol.near(a, b)
    assert_in_delta score, 1.0, 0.000001
  end

  test "old and new shapes compare against each other" do
    old = old_shape("s", [3.0, 4.0])
    new = Symbol.new("s", [3.0, 4.0])

    assert {:ok, score} = Symbol.near(old, new)
    assert_in_delta score, 1.0, 0.000001
  end

  test "an old-shape symbol still crosses the wire as the same json" do
    fact = %Blazie.Fact{
      id: "ada",
      attribute: "embedding",
      value: old_shape("potion_256", [1.5, -2.5]),
      tx: 1,
      by: "f"
    }

    assert %{"value" => %{"$symbol" => %{"values" => [1.5, -2.5], "space" => "potion_256"}}} =
             Wire.fact(fact)
  end

  test "the new shape is what gets written from now on" do
    assert is_binary(Symbol.new("s", [1.0, 2.0]).values)
    assert is_float(Symbol.new("s", [1.0, 2.0]).norm)
  end

  test "cosine still means cosine" do
    # Orthogonal is 0, opposite is -1, same is 1. The representation changed;
    # the arithmetic must not have.
    assert {:ok, s1} = Symbol.near(Symbol.new("s", [1.0, 0.0]), Symbol.new("s", [0.0, 1.0]))
    assert_in_delta s1, 0.0, 0.000001

    assert {:ok, s2} = Symbol.near(Symbol.new("s", [1.0, 0.0]), Symbol.new("s", [-1.0, 0.0]))
    assert_in_delta s2, -1.0, 0.000001

    assert {:ok, s3} = Symbol.near(Symbol.new("s", [2.0, 3.0]), Symbol.new("s", [4.0, 6.0]))
    assert_in_delta s3, 1.0, 0.000001
  end

  test "a zero symbol is near nothing rather than dividing by zero" do
    assert {:ok, 0.0} = Symbol.near(Symbol.new("s", [0.0, 0.0]), Symbol.new("s", [1.0, 1.0]))
  end
end
