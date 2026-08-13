defmodule Blazie.Formula.GeneratedTest do
  @moduledoc """
  Verification, which is the half of Phase 2 that must never be skipped.

  Generation is the easy part and it is stubbed here — what these check is the
  gate: a candidate that fails an example, refuses to run, reaches outside, or
  writes something the attribute forbids must not be adopted. If any of these
  ever pass for the wrong reason, a model's mistake becomes a program running on
  real data, and a correction after that is not a correction, it is an apology.
  """
  use ExUnit.Case, async: false

  alias Blazie.{Attribute, Snapshot, World}
  alias Blazie.Formula.Generated

  setup do
    name = "gen-#{System.unique_integer([:positive])}"
    {:ok, world} = World.open(name)
    on_exit(fn -> World.close(name) end)

    {:ok, _} =
      World.append(world, Attribute.seed() ++ Attribute.requires_seed() ++ Generated.seed())

    {:ok, _} = World.append(world, Attribute.define("age", answers: "integer"))
    {:ok, _} = World.append(world, Attribute.define("adult", answers: "boolean"))

    {:ok, _} =
      World.append(
        world,
        Generated.declare("adults",
          produces: "adult",
          given: ["age"],
          examples: [
            %{"given" => %{"age" => 41}, "expect" => true},
            %{"given" => %{"age" => 9}, "expect" => false},
            %{"given" => %{"age" => 18}, "expect" => true}
          ]
        )
      )

    %{world: world}
  end

  defp snapshot(world), do: Snapshot.open([world])

  @correct "for p in each { age = true } do p.adult = p.age >= 18 end"

  describe "the work list" do
    test "a declaration with no source is wanted", %{world: world} do
      assert Generated.wanted(snapshot(world)) == ["adults"]
    end

    test "one that has a source is not", %{world: world} do
      {:ok, _} = World.append(world, [{"adults", "source", @correct}])
      assert Generated.wanted(snapshot(world)) == []
    end

    test "but a new example makes it want one again", %{world: world} do
      {:ok, _} = World.append(world, [{"adults", "source", @correct}])
      assert Generated.wanted(snapshot(world)) == []

      # This is what makes a generated program maintained rather than generated
      # once. Correct an example and the program that no longer satisfies it is
      # stale, exactly as a derived value is stale when its input moves.
      {:ok, _} =
        World.append(world, [
          {"adults", "example", %{"given" => %{"age" => 17}, "expect" => false}}
        ])

      assert Generated.wanted(snapshot(world)) == ["adults"]
    end

    test "and a newer source settles it again", %{world: world} do
      {:ok, _} = World.append(world, [{"adults", "source", @correct}])

      {:ok, _} =
        World.append(world, [
          {"adults", "example", %{"given" => %{"age" => 17}, "expect" => false}}
        ])

      {:ok, _} = World.append(world, [{"adults", "source", @correct}])

      assert Generated.wanted(snapshot(world)) == []
    end
  end

  describe "the brief" do
    test "is assembled from the declaration, examples and all", %{world: world} do
      brief = Generated.brief(snapshot(world), "adults")

      assert brief =~ "adult"
      assert brief =~ "age"
      assert brief =~ "41"
      assert brief =~ "no clock, no network"
    end
  end

  describe "verification" do
    test "a correct candidate passes", %{world: world} do
      assert :ok = Generated.verify(snapshot(world), "adults", @correct)
    end

    test "an off-by-one is caught by the boundary example", %{world: world} do
      # `> 18` instead of `>= 18`. Two of three examples still pass, which is
      # exactly the kind of wrong a model produces and a thin check misses.
      assert {:error, failures} =
               Generated.verify(
                 snapshot(world),
                 "adults",
                 "for p in each { age = true } do p.adult = p.age > 18 end"
               )

      assert [%{problem: :wrong_answer}] = failures
      assert hd(failures).repair =~ "18"
    end

    test "one that answers nothing is caught", %{world: world} do
      # Every example fails, not just the first — a verifier that stopped at
      # one would report less than it knows.
      assert {:error, failures} = Generated.verify(snapshot(world), "adults", "local x = 1")
      assert length(failures) == 3
      assert Enum.all?(failures, &(&1.problem == :answered_nothing))
    end

    test "one that will not parse is caught", %{world: world} do
      assert {:error, [%{problem: :did_not_run} | _]} =
               Generated.verify(snapshot(world), "adults", "this is not lua ((")
    end

    test "one that never finishes is stopped, not waited for", %{world: world} do
      assert {:error, [%{problem: :did_not_run} | _]} =
               Generated.verify(snapshot(world), "adults", "while true do end")
    end

    test "examples cannot see each other", %{world: world} do
      # Each example runs in its own world. A candidate that wrote a fact one
      # example needed and the next one read would pass for the order it ran in.
      assert {:error, _} =
               Generated.verify(snapshot(world), "adults", """
               for p in each { age = true } do
                 if leftover.seen then p.adult = true else p.adult = false end
                 leftover.seen = true
               end
               """)
    end
  end

  describe "the adversarial case" do
    test "a candidate that reaches outside cannot run at all", %{world: world} do
      # THE test for this phase. A model wrote this and it will execute — the
      # only reason that is acceptable is that it executes as a FORMULA, whose
      # world contains nothing to reach with. If this ever passes, the phase is
      # unsafe.
      reaching = "for p in each { age = true } do p.adult = (http.get('http://x') ~= nil) end"

      assert {:error, failures} = Generated.verify(snapshot(world), "adults", reaching)
      assert [%{problem: :did_not_run} | _] = failures
    end

    test "every stripped global is still stripped in a generated formula", %{world: world} do
      for name <- Blazie.Lua.removed() do
        candidate = "for p in each { age = true } do p.adult = (#{name} ~= nil) end"

        # Reaching for a stripped global gives nil, so this answers `false` for
        # every example — and the 41 case expects true, so it is rejected. What
        # matters is that it is never `true`: that would mean the global was
        # there.
        assert {:error, _} = Generated.verify(snapshot(world), "adults", candidate),
               "#{name} was reachable from a generated formula"
      end
    end
  end

  describe "requirements are checked too, not just examples" do
    test "a candidate satisfying every example can still be refused", %{world: world} do
      {:ok, _} =
        World.append(world, [
          {"adult", "requires", "never"},
          {"never", "is", "formula"},
          {"never", "source", "return false"}
        ])

      # It answers all three examples correctly and is still not adopted,
      # because the attribute forbids what it writes.
      assert {:error, failures} = Generated.verify(snapshot(world), "adults", @correct)
      assert Enum.any?(failures, &(&1.problem == :unmet))
    end
  end

  describe "what gets written" do
    test "adoption names the job that generated it", %{world: _world} do
      assert [{"adults", "source", @correct, "author"}] =
               Generated.adopt("adults", @correct, "author")
    end

    test "a rejection is evidence, with the candidate and why", %{world: _world} do
      [{"adults", "rejected", recorded, "author"}] =
        Generated.reject("adults", "bad", [%{repair: "it answered 9"}], "author")

      assert recorded["source"] == "bad"
      assert recorded["why"] == ["it answered 9"]
    end
  end
end
