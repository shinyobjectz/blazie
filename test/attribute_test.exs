defmodule LazyRiver.AttributeTest do
  @moduledoc """
  The doctrine, executable — schema as facts, and every write checked with a
  refusal that carries its repair.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.{Attribute, Ledger, Snapshot}

  setup do
    name = :"ledger_#{System.unique_integer([:positive])}"
    start_supervised!({Ledger, name: name})
    {:ok, _} = Ledger.append(name, Attribute.seed())
    %{ledger: name}
  end

  defp known(ledger), do: Attribute.known(Snapshot.open([ledger]))
  defp checking(ledger), do: [check: &Attribute.check(&1, known(ledger))]

  describe "schema is facts" do
    test "an attribute is defined by writing facts about it", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define(:height, answers: :integer))
      snapshot = Snapshot.open([ledger])

      assert Attribute.defined?(snapshot, :height)
      assert Snapshot.answer(snapshot, :height, :is) == :attribute
      assert Snapshot.answer(snapshot, :height, :answers) == :integer
    end

    test "definitions are ordinary facts in the same row shape", %{ledger: ledger} do
      {:ok, tx} = Ledger.append(ledger, Attribute.define(:height, answers: :integer))

      Ledger.facts_at(ledger, tx)
      |> Enum.filter(&(&1.tx == tx))
      |> Enum.each(fn fact -> assert fact.id == :height end)
    end

    test "the vocabulary bootstraps itself", %{ledger: ledger} do
      snapshot = Snapshot.open([ledger])

      for name <- Attribute.root() do
        assert Attribute.defined?(snapshot, name)
      end
    end
  end

  describe "if an attribute can say it, the engine does not grow" do
    test "cardinality is a fact about the attribute", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define(:tags, cardinality: :many))
      snapshot = Snapshot.open([ledger])

      assert Attribute.cardinality(snapshot, :tags) == :many
      assert Attribute.cardinality(snapshot, :is) == :one
    end

    test "an undeclared attribute answers with the default", %{ledger: ledger} do
      snapshot = Snapshot.open([ledger])

      assert Attribute.cardinality(snapshot, :never_defined) == :one
      assert Attribute.answers(snapshot, :never_defined) == :any
    end
  end

  describe "every write is checked, and a refusal carries its repair" do
    test "a defined attribute is accepted", %{ledger: ledger} do
      {:ok, _} = Ledger.append(ledger, Attribute.define(:height, answers: :integer))

      assert {:ok, _tx} = Ledger.append(ledger, [{42, :height, 180}], checking(ledger))
    end

    test "an undefined attribute is refused", %{ledger: ledger} do
      assert {:error, [refusal]} =
               Ledger.append(ledger, [{42, :heigth, 180}], checking(ledger))

      assert refusal.attribute == :heigth
      assert refusal.problem == :undefined
    end

    test "the refusal says how to comply", %{ledger: ledger} do
      {:error, [refusal]} = Ledger.append(ledger, [{42, :heigth, 180}], checking(ledger))

      assert refusal.repair =~ "Attribute.define(:heigth"
    end

    test "a refused write leaves the ledger where it was", %{ledger: ledger} do
      before = Ledger.tx(ledger)
      {:error, _} = Ledger.append(ledger, [{42, :heigth, 180}], checking(ledger))

      assert Ledger.tx(ledger) == before
    end

    test "every undefined attribute is reported, not just the first", %{ledger: ledger} do
      {:error, refusals} =
        Ledger.append(ledger, [{42, :one, 1}, {43, :two, 2}], checking(ledger))

      assert Enum.map(refusals, & &1.attribute) |> Enum.sort() == [:one, :two]
    end

    test "checking is opt-in, so the vocabulary can be seeded", %{ledger: ledger} do
      assert {:ok, _tx} = Ledger.append(ledger, [{42, :undefined_anywhere, 1}])
    end
  end

  describe "everything extends, nothing redefines" do
    test "a vocabulary composed from another ledger is visible", %{ledger: tenant} do
      shared = :"shared_#{System.unique_integer([:positive])}"
      start_supervised!({Ledger, name: shared})
      {:ok, _} = Ledger.append(shared, Attribute.define(:height, answers: :integer))

      refute Attribute.defined?(Snapshot.open([tenant]), :height)
      assert Attribute.defined?(Snapshot.open([tenant, shared]), :height)
    end
  end
end
