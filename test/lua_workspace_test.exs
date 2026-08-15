defmodule Blazie.LuaWorkspaceTest do
  @moduledoc """
  The workspace grant — files for a Lua guest, with no filesystem anywhere.

  LT1 of the Lua runtime track (docs/storage-plan.md): the coding agent's run
  tool needs files, and guests deliberately have none. The answer is the
  tiny-lasers VFS shape reduced to its blazie minimum: the workspace is a
  key→bytes MAP — seeded from facts, mutated in the guest's own process,
  harvested back by the host. A guest path is never a host path; `../etc` is
  just a funny key; there is no filesystem to traverse out of because there
  is no filesystem.

  The posture is the python sandbox's, kept exactly: files and print, and
  NOTHING that reaches — no http, no blob, a frozen clock. The fence is the
  absence of everything else, same as it ever was.
  """
  use ExUnit.Case, async: true

  alias Blazie.Lua

  test "a guest reads the files it was handed" do
    {:ok, answer} =
      Lua.workspace(
        """
        return file.read("greeting.txt")
        """,
        %{"greeting.txt" => "hello"}
      )

    assert answer.value == "hello"
  end

  test "a write comes back to the host — and only as data" do
    {:ok, answer} =
      Lua.workspace(
        """
        file.write("out/result.txt", "computed: " .. (2 + 2))
        return file.list()
        """,
        %{"in.txt" => "x"}
      )

    assert answer.files["out/result.txt"] == "computed: 4"
    # The original is still there; list sees both.
    assert answer.files["in.txt"] == "x"
    assert "in.txt" in answer.value and "out/result.txt" in answer.value
  end

  test "print is captured, not printed" do
    {:ok, answer} =
      Lua.workspace(
        """
        print("first")
        print("second", 2)
        return true
        """,
        %{}
      )

    assert answer.printed == "first\nsecond\t2"
  end

  test "a traversal-shaped path is just a key" do
    {:ok, answer} =
      Lua.workspace(
        """
        file.write("../../etc/passwd", "nope")
        return file.read("../../etc/passwd")
        """,
        %{}
      )

    # It wrote a map entry with a funny name, and read it back. No host path
    # was ever involved.
    assert answer.value == "nope"
    assert answer.files["../../etc/passwd"] == "nope"
  end

  test "the workspace guest cannot reach — no http, no blob, frozen clock" do
    {:ok, answer} =
      Lua.workspace(
        """
        return {
          http_absent = (http == nil),
          blob_absent = (blob == nil),
          time_frozen = (os.time() == 0)
        }
        """,
        %{}
      )

    assert answer.value == %{
             "http_absent" => true,
             "blob_absent" => true,
             "time_frozen" => true
           }
  end

  test "a runaway guest is killed, not waited on" do
    assert {:error, refusal} =
             Lua.workspace("while true do end", %{}, deadline: 200)

    assert refusal.problem in [:deadline, :took_too_long, :timeout]
  end

  test "a missing file reads as nil, with the honest miss" do
    {:ok, answer} = Lua.workspace("return file.read(\"absent.txt\") == nil", %{})
    assert answer.value == true
  end

  describe "the stdlib repair" do
    test "string.gmatch works — the Luerl gap, shimmed in the grant" do
      # Luerl 1.5's own gmatch raises badarg (recorded in the LT2 verdict);
      # every workspace guest gets a find-based shim so authored code and
      # vendored libraries can speak ordinary Lua.
      {:ok, answer} =
        Lua.workspace(
          """
          local words = {}
          for w in string.gmatch("alpha beta gamma", "%a+") do
            table.insert(words, w)
          end
          local total = 0
          for n in string.gmatch("3 4 5", "%d+") do total = total + tonumber(n) end
          return { count = #words, last = words[3], total = total }
          """,
          %{}
        )

      assert answer.value == %{"count" => 3, "last" => "gamma", "total" => 12}
    end

    test "gmatch with a single capture yields the capture" do
      {:ok, answer} =
        Lua.workspace(
          """
          local keys = {}
          for k in string.gmatch("a=1, b=2", "(%a+)=%d") do
            table.insert(keys, k)
          end
          return table.concat(keys, ",")
          """,
          %{}
        )

      assert answer.value == "a,b"
    end
  end
end
