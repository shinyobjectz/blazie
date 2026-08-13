defmodule Logi.EmbeddingTest do
  @moduledoc """
  Text into a symbol.

  This is where `Symbol`'s claim finally becomes true. Its moduledoc says a
  symbol is "always produced by a formula, never taken from outside" — and until
  now NOTHING in the tree could produce one, because producing one is a network
  call and a formula has no network. The claim was safe by being unreachable.

  It is a job, which is what the fence said all along: `Symbol.check/1` enforces
  provenance, not formula-ness, and a job has provenance.
  """
  use ExUnit.Case, async: true

  alias Blazie.{Attribute, Snapshot, Symbol, World}
  alias Logi.Embedding

  setup do
    name = "embed-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} = World.append(world, Attribute.seed() ++ Embedding.seed())
    {:ok, _} = World.append(world, Attribute.define("body", answers: "name"))

    {:ok, _} =
      World.append(
        world,
        Embedding.declare("embedding",
          embeds: "body",
          into: "text-3-small",
          asks: "openai:text-embedding-3-small"
        )
      )

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  describe "what needs embedding" do
    test "anything with the source text and no symbol", %{world: world} do
      {:ok, _} = World.append(world, [{"a", "body", "hello"}, {"b", "body", "goodbye"}])

      assert Embedding.pending(snapshot(world), "embedding", "body") == [
               {"a", "hello"},
               {"b", "goodbye"}
             ]
    end

    test "not what has already been embedded", %{world: world} do
      {:ok, _} = World.append(world, [{"a", "body", "hello"}])
      {:ok, _} = World.append(world, [{"a", "embedding", Symbol.new("text-3-small", [1.0]), "embedding"}])

      assert Embedding.pending(snapshot(world), "embedding", "body") == []
    end

    test "but yes when the text changed afterwards", %{world: world} do
      {:ok, _} = World.append(world, [{"a", "body", "hello"}])
      {:ok, _} = World.append(world, [{"a", "embedding", Symbol.new("text-3-small", [1.0]), "embedding"}])
      {:ok, _} = World.append(world, [{"a", "body", "something else"}])

      # A correction upstream makes the vector stale, and nothing had to be
      # invalidated for that to be true — the transaction is the clock.
      assert Embedding.pending(snapshot(world), "embedding", "body") == [{"a", "something else"}]
    end
  end

  describe "a symbol that lands" do
    test "carries its space, so it can never be compared across models", %{world: world} do
      {:ok, _} = World.append(world, [{"a", "body", "hello"}])

      symbol = Symbol.new("text-3-small", [1.0, 0.0])
      {:ok, _} = World.append(world, [{"a", "embedding", symbol, "embedding"}])

      held = Snapshot.value(snapshot(world), "a", "embedding")
      assert held.space == "text-3-small"

      other = Symbol.new("some-other-model", [1.0, 0.0])
      assert {:error, %{problem: :different_spaces}} = Symbol.near(held, other)
    end

    test "names the job that produced it, which is what Symbol.check demands", %{world: world} do
      symbol = Symbol.new("text-3-small", [1.0])

      # Three-wide names nothing and is refused; four-wide names the job.
      assert {:error, [%{problem: :symbol_from_outside} | _]} =
               Symbol.check([{"a", "embedding", symbol}])

      assert :ok = Symbol.check([{"a", "embedding", symbol, "embedding"}])
      _ = world
    end
  end

  describe "a declaration that is incomplete" do
    test "says so rather than running with a missing space", %{world: world} do
      {:ok, _} = World.append(world, Attribute.define("halfway", answers: "symbol"))
      {:ok, _} = World.append(world, [{"halfway", "embeds", "body"}])

      work = Embedding.work(snapshot(world), "halfway")

      assert_raise RuntimeError, ~r/embeds.*into.*asks/, fn ->
        work.(snapshot(world))
      end
    end
  end
end
