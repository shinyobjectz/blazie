defmodule LazyRiver.Formula.SandboxTest do
  @moduledoc """
  Doctrine 14, made a fence rather than a shape.

  Until now nothing stopped a formula reaching outside — the tiers were
  described and unenforced. Tenant code runs here holding no capability at all,
  and the isolation is structural: a module cannot call what the host never
  handed it, so there is no rule to enforce and none to forget.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Formula, Ledger, Snapshot, TestLedger}
  alias LazyRiver.Formula.Sandbox

  @doubling """
  (module
    (func (export "apply") (param i32) (result i32)
      local.get 0
      i32.const 2
      i32.mul))
  """

  # Code that wants something from outside. There is no such import, so this
  # cannot be instantiated — which is the whole point.
  @reaching_out """
  (module
    (import "env" "http_get" (func $http_get (param i32) (result i32)))
    (func (export "apply") (param i32) (result i32)
      local.get 0
      call $http_get))
  """

  setup do
    ledger = TestLedger.open()
    {:ok, _} = Ledger.append(ledger, Attribute.seed())
    {:ok, _} = Ledger.append(ledger, Attribute.define("height", answers: "integer"))
    {:ok, _} = Ledger.append(ledger, Attribute.define("doubled", answers: "integer"))
    {:ok, _} = Ledger.append(ledger, [{1, "height", 10}, {2, "height", 21}])
    %{ledger: ledger}
  end

  describe "tenant code produces facts like any other formula" do
    test "it answers", %{ledger: ledger} do
      {:ok, formula} =
        Sandbox.mapping("doubling", @doubling, over: [attribute: "height"], into: "doubled")

      {assertions, _reads} = Formula.run(formula, Snapshot.open([ledger]))

      assert Enum.sort(assertions) == [
               {1, "doubled", 20, "doubling"},
               {2, "doubled", 42, "doubling"}
             ]
    end

    test "what it produced names it, like anything else", %{ledger: ledger} do
      {:ok, formula} =
        Sandbox.mapping("doubling", @doubling, over: [attribute: "height"], into: "doubled")

      {:ok, tx, _} = Formula.materialize(formula, Snapshot.open([ledger]), ledger)

      assert [%{by: "doubling"} | _] =
               Ledger.facts_at(ledger, tx) |> Enum.filter(&(&1.tx == tx))
    end

    test "it is a formula, so the read set still bounds it", %{ledger: ledger} do
      {:ok, formula} =
        Sandbox.mapping("doubling", @doubling, over: [attribute: "height"], into: "doubled")

      {_assertions, reads} = Formula.run(formula, Snapshot.open([ledger]))

      assert reads == [[attribute: "height"]]

      refute Formula.stale?(reads, [%LazyRiver.Fact{id: 9, attribute: "colour", answer: 1, tx: 9}])
    end
  end

  describe "the fence is structural" do
    test "code that reaches outside cannot even be built" do
      assert {:error, why} =
               Sandbox.mapping("sneaky", @reaching_out, over: [attribute: "height"], into: "x")

      assert why.problem == :wanted_something_it_was_not_given
      assert why.repair =~ "no capability"
    end

    test "nothing was granted, so there is nothing to have forgotten" do
      # The host builds the guest's whole world out of what it hands in, and it
      # hands in nothing. Not a policy that could be misconfigured.
      assert Sandbox.imports() == %{}
    end
  end

  describe "a broken module is refused rather than raised" do
    test "nonsense is a refusal with its repair" do
      assert {:error, why} =
               Sandbox.mapping("broken", "(module (this is not wasm", over: [], into: "x")

      assert why.problem == :not_a_module
      assert why.repair != ""
    end

    test "a module missing the entry point is refused when it is built" do
      without_apply = "(module (func (export \"something_else\") (result i32) i32.const 1))"

      # Found now rather than halfway through answering.
      assert {:error, why} =
               Sandbox.mapping("wrong_export", without_apply,
                 over: [attribute: "height"],
                 into: "x"
               )

      assert why.problem == :no_entry_point
      assert why.repair =~ "apply"
    end
  end
end
