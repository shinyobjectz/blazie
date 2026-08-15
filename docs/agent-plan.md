# The agent, in Lua — the loop as a fenced guest program

*Built 2026-08-15. The capstone of the microkernel: the last Elixir-in-the-loop
removed. The whole coding agent is now a Lua program that runs in a Luerl
guest, so the full agent runs in-process — and is embeddable anywhere a Luerl
with these grants runs.*

## The inversion

Before: `Blazie.Coding` ran the read-edit-check loop in ELIXIR, with tools
authored in Lua. After: the LOOP itself is Lua (`priv/lua/agent.lua`), and
Elixir owns exactly one thing — a single model turn. The guest owns the loop;
the host owns the turn. Everything else the agent needs is a capability it
already had.

## The one new capability: ask()

`Model.turn/4` is the single-turn primitive (where `converse/5` runs the whole
loop): messages + tools in, `{:said, text}` or `{:calls, calls}` out, the
account-wide `Limit` passed first. `ask(messages, tools)` is the guest grant
over it — decodes the Lua tables, runs the turn, hands back `{ said }` or
`{ calls }` (or `{ error }` for a refused turn, so the loop backs off instead
of crashing). Absent unless a model is granted, exactly like sql() and
require(). Provider injectable (scripted in tests, the configured model in
production, egress-governed).

## The pi agent (priv/lua/agent.lua)

Four verbs — read, write, run, done — the pi set. The loop: assemble a prompt
from what is TRUE now (the task and the files present, never authored), ask
with the tool schema, perform each call over the workspace (file.read/write,
sh()), feed the observation back, repeat until done or the step budget. ~110
lines of Lua, no Elixir. Every tool is a capability the guest already holds,
so the agent reaches nothing the fence forbids.

## Proven end to end

A scripted model drives the real loop (`test/lua_agent_test.exs`): it writes a
file, runs a shell line to verify it (the file's own bytes come back through
run), and finishes — the write lands in the workspace, the model's later turns
see the observations, and the whole thing runs in one guest process. The
budget stops an endless loop; and the fence holds throughout — a tool call
trying `curl` hits the shell's shelf and the agent keeps going, all inside the
guest. 4 e2e + 5 ask tests; suite 1069 green.

## Why this is the shape

The agent is now a value that travels: a Lua string plus the grants it needs.
That is what "embeddable harness anywhere" means — the same agent runs under
the coding loop today, and could run under any Luerl host tomorrow, with the
capabilities that host chooses to grant. And because it runs in the fenced
guest, the whole agent inherits every guarantee the microkernel already
proved: no host reach, deterministic, capped, credential-safe. The agent is
not a privileged orchestrator above the sandbox — it is a program inside it.
