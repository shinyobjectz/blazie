defmodule Blazie.LuaAskTest do
  @moduledoc """
  C1 — ask(): a single model turn as a guest capability.

  The one thing a Lua agent loop needs that no other capability gives: to
  ask a model. `ask(messages, tools)` runs ONE turn — the host resolves the
  model, passes the account-wide Limit, calls the provider, and hands back
  either { said = text } or { calls = {...} }. The guest runs the LOOP; this
  is the single turn inside it. Governed like every reach; the provider is
  injectable (scripted here, the configured model in production). Absent
  unless a model is granted, like sql() and require().
  """
  use ExUnit.Case, async: false

  alias Blazie.Lua

  # A scripted provider: answers in sequence, records the messages it saw.
  defp scripted(turns) do
    at = :counters.new(1, [])
    me = self()

    fn _ref, messages, _tools, _opts ->
      i = :counters.get(at, 1)
      :counters.add(at, 1, 1)
      send(me, {:saw_messages, messages})

      case Enum.at(turns, i) do
        {:said, text} -> {:ok, {:said, text}, %{in: 1, out: 1}}
        {:calls, calls} -> {:ok, {:calls, calls}, %{in: 1, out: 1}}
        nil -> {:ok, {:said, "done"}, %{in: 1, out: 1}}
      end
    end
  end

  defp model(turns), do: [model: "openai:x", provider: scripted(turns)]

  test "ask returns a said turn as a table" do
    {:ok, answer} =
      Lua.workspace(
        """
        local r = ask({ { role = "user", content = "hi" } }, {})
        return { said = r.said, has_calls = (r.calls ~= nil) }
        """,
        %{},
        model([{:said, "hello there"}])
      )

    assert answer.value["said"] == "hello there"
    assert answer.value["has_calls"] == false
  end

  test "ask returns tool calls as a list the guest can dispatch" do
    calls = [%{id: "c1", name: "write", arguments: %{"path" => "a.txt", "content" => "x"}}]

    {:ok, answer} =
      Lua.workspace(
        """
        local r = ask({ { role = "user", content = "make a file" } }, {})
        return { n = #r.calls, name = r.calls[1].name, path = r.calls[1].arguments.path }
        """,
        %{},
        model([{:calls, calls}])
      )

    assert answer.value["n"] == 1
    assert answer.value["name"] == "write"
    assert answer.value["path"] == "a.txt"
  end

  test "the guest can run a multi-turn loop: ask, act, ask again" do
    calls = [%{id: "c1", name: "note", arguments: %{"text" => "first"}}]

    {:ok, answer} =
      Lua.workspace(
        """
        local msgs = { { role = "user", content = "go" } }
        local r1 = ask(msgs, {})
        -- act on the call, feed the result back
        table.insert(msgs, { role = "tool", content = "did " .. r1.calls[1].arguments.text })
        local r2 = ask(msgs, {})
        return r2.said
        """,
        %{},
        model([{:calls, calls}, {:said, "finished"}])
      )

    assert answer.value == "finished"
    # The second turn saw the tool result the guest fed back.
    assert_received {:saw_messages, _first}
    assert_received {:saw_messages, second}
    assert Enum.any?(second, fn m -> is_map(m) and Map.get(m, "content", "") =~ "did first" end)
  end

  test "without a model grant, ask is absent" do
    {:ok, answer} = Lua.workspace("return ask == nil", %{})
    assert answer.value == true
  end

  test "ask passes the account-wide Limit before the provider" do
    denied = fn _vendor -> {:error, %{problem: :rate_limited, repair: "wait"}} end

    {:ok, answer} =
      Lua.workspace(
        """
        local r = ask({}, {})
        return { said = r.said, err = r.error }
        """,
        %{},
        model([{:said, "unused"}]) ++ [limit: denied]
      )

    # A refused turn comes back as data — the loop can back off, not crash.
    assert answer.value["said"] == nil
    assert answer.value["err"] == "wait"
  end
end
