defmodule LazyRiver.LuaTest do
  @moduledoc """
  The host that runs tenant code, and the world it hands them.

  Lua is the authoring language because it is already everybody's — twenty-two
  keywords, and no vocabulary of ours to learn on top of the seven words. What
  had to be proved before committing to it is here as tests rather than as a
  claim: that the world can be emptied, that tenant text cannot exhaust the
  atom table, that a runaway loop and a memory bomb both end, and that the same
  source gives the same answer every time.

  The last one is load-bearing. A formula's answer is cached under a snapshot
  name forever, so a formula that answered differently on a second run would
  not be a slow bug, it would be a wrong answer with no expiry.
  """
  use ExUnit.Case, async: true

  alias LazyRiver.Lua

  describe "the world a formula is handed" do
    test "has no way out" do
      for name <- ~w(io package require load loadstring dofile loadfile) do
        assert {:ok, nil} = Lua.run("return #{name}", as: :formula),
               "#{name} is reachable from a formula"
      end

      for name <- ~w(execute exit getenv remove rename tmpname date) do
        assert {:ok, nil} = Lua.run("return os.#{name}", as: :formula),
               "os.#{name} is reachable from a formula"
      end
    end

    # Doctrine 19. What a formula may not have is a value that differs run to
    # run — not a name it expects to find. Deleting `os` made ordinary Lua
    # crash on its way to being deterministic; freezing it makes the same code
    # answer, and answer the same forever.
    test "has a clock, and it does not move" do
      assert {:ok, 1000} = Lua.run("return os.time()", as: :formula, at: 1000)
      assert {:ok, 1000} = Lua.run("return os.time()", as: :formula, at: 1000)
      assert {:ok, 7} = Lua.run("return os.time()", as: :formula, at: 7)
      assert {:ok, 0} = Lua.run("return os.clock()", as: :formula, at: 1000)
    end

    test "the clock does not move within one run either" do
      source = "local a = os.time() local b = os.time() return b - a"
      assert {:ok, 0} = Lua.run(source, as: :formula, at: 1000)
    end

    test "arithmetic on time is kept, because it computes nothing new" do
      assert {:ok, 60} = Lua.run("return os.difftime(160, 100)", as: :formula, at: 1000)
    end

    test "has randomness, and it is the same randomness every time" do
      source = "local t = {} for i = 1, 5 do t[i] = math.random(1, 1000) end
                return table.concat(t, ',')"

      runs = for _ <- 1..10, do: Lua.run(source, as: :formula, at: 1000)
      assert runs |> Enum.uniq() |> length() == 1

      # A different snapshot is a different sequence — deterministic, not fixed.
      assert Lua.run(source, as: :formula, at: 2000) != hd(runs)
    end

    test "a job gets the real ones, because its answer happened once" do
      assert {:ok, real} = Lua.run("return os.time()", as: :job, at: 1000)
      assert real > 1_700_000_000, "a job's clock should be the wall clock, got #{inspect(real)}"
    end

    test "still has the parts of Lua that compute" do
      assert {:ok, 4} = Lua.run("return 2 + 2", as: :formula)
      assert {:ok, "ADA"} = Lua.run("return ('ada'):upper()", as: :formula)
      assert {:ok, 3} = Lua.run("return math.floor(3.7)", as: :formula)
      assert {:ok, "a,b"} = Lua.run("return table.concat({'a','b'}, ',')", as: :formula)
      assert {:ok, 2} = Lua.run("return #({'x','y'})", as: :formula)
    end

    test "a job is the same world plus the outside, which is the whole difference" do
      assert {:ok, nil} = Lua.run("return http", as: :formula)
      assert {:ok, "function"} = Lua.run("return type(http.get)", as: :job)
    end
  end

  describe "what a guest cannot spend" do
    @tag :slow
    test "a loop that never ends is ended" do
      assert {:error, refusal} = Lua.run("while true do end", as: :formula, deadline: 300)

      assert refusal.problem == :took_too_long
      assert refusal.repair =~ "300"
    end

    test "a table that grows forever stops growing" do
      bomb = "local t = {} local i = 1 while true do t[i] = string.rep('x', 1000) i = i + 1 end"

      assert {:error, refusal} = Lua.run(bomb, as: :formula, deadline: 15_000, heap: 400_000)
      assert refusal.problem in [:took_too_much_memory, :took_too_long]
    end

    test "a guest that dies takes nothing with it" do
      me = self()
      assert {:error, _} = Lua.run("while true do end", as: :formula, deadline: 200)
      assert Process.alive?(me)
      assert {:ok, 2} = Lua.run("return 1 + 1", as: :formula)
    end
  end

  describe "refusals carry their repair" do
    test "source that is not Lua" do
      assert {:error, refusal} = Lua.run("this is not lua ((", as: :formula)
      assert refusal.problem == :not_lua
      assert refusal.repair != ""
    end

    test "a runtime error is data, not a crash" do
      assert {:error, refusal} = Lua.run("error('deliberate')", as: :formula)
      assert refusal.problem == :raised
      assert refusal.repair =~ "deliberate"
    end

    test "reaching for something that was not granted says so in Lua's own words" do
      # Not the clock — that is present and frozen, per doctrine 19. This is
      # something genuinely absent, and the author is told what any Lua runtime
      # would tell them.
      assert {:error, refusal} = Lua.run("return os.execute('rm -rf /')", as: :formula)

      assert refusal.problem == :raised
      assert refusal.repair =~ "nil"
    end

    test "a formula reaching for the outside is refused, clock or no clock" do
      for reach <- ["io.write('x')", "os.getenv('SECRET_KEY_BASE')", "http.get('http://x')"] do
        assert {:error, %{problem: :raised}} = Lua.run("return #{reach}", as: :formula),
               "#{reach} was not refused"
      end
    end
  end

  describe "the same source gives the same answer" do
    test "twenty-five times over" do
      source = """
      local t = {}
      for i = 1, 60 do t['k' .. ((i * 7919) % 97)] = i end
      local keys = {}
      for k in pairs(t) do keys[#keys+1] = k end
      table.sort(keys)
      return table.concat(keys, ',')
      """

      answers = for _ <- 1..25, do: Lua.run(source, as: :formula)

      assert answers |> Enum.uniq() |> length() == 1
      assert {:ok, _} = hd(answers)
    end

    test "and a guest cannot see the one before it" do
      assert {:ok, nil} = Lua.run("return leaked", as: :formula)
      assert {:ok, 1} = Lua.run("leaked = 1 return leaked", as: :formula)
      assert {:ok, nil} = Lua.run("return leaked", as: :formula)
    end
  end

  describe "tenant text is text" do
    # Asked of the atom table directly rather than by watching its size. The
    # count is VM-wide and every other async test moves it — an earlier version
    # of this test measured module loading elsewhere and failed about one run in
    # three. `binary_to_existing_atom` asks the only question that matters, and
    # asks it about exactly these strings.
    test "it never becomes an atom" do
      keys = for n <- 1..200, do: "tenant_key_#{n}_#{System.unique_integer([:positive])}_x"

      for key <- keys do
        assert {:ok, ^key} =
                 Lua.run("local t = {} t['#{key}'] = 1 return '#{key}'", as: :formula)
                 |> then(fn {:ok, v} -> {:ok, v} end)
      end

      for key <- keys do
        assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
      end
    end
  end

  describe "facts come back as facts" do
    test "an array of arrays becomes assertions" do
      source = "return {{'ada','height',180},{'grace','height',175}}"

      assert {:ok, value} = Lua.run(source, as: :formula)
      assert Lua.facts(value) == [{"ada", "height", 180}, {"grace", "height", 175}]
    end

    test "returning nothing is returning no facts" do
      assert {:ok, value} = Lua.run("return {}", as: :formula)
      assert Lua.facts(value) == []
    end

    test "a table that is not a list of triples is refused, not guessed at" do
      assert {:ok, value} = Lua.run("return {{'ada','height'}}", as: :formula)

      assert_raise ArgumentError, ~r/three/, fn -> Lua.facts(value) end
    end
  end
end
