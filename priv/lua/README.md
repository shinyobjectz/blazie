# The guest library shelf

Vendored pure-Lua single files, loaded into workspace guests by name through
`Lua.workspace(..., prelude: [:name])`. Every file here must pass the smoke
tests in `test/lua_prelude_test.exs` — the tripwire for Luerl gaps (e.g.
`string.gmatch`, which Luerl 1.5 lacks) — before anything trusts it.

| file | from | license | vendored |
|---|---|---|---|
| json.lua | github.com/rxi/json.lua (v0.1.2) | MIT | 2026-08-15 |
| lust.lua | github.com/bjornbytes/lust | MIT | 2026-08-15 |

Vendored whole and unmodified — the `learn` treatment: a dead-simple copy we
own, not a dependency we track. Update by re-fetching and re-running the
smoke tests.
