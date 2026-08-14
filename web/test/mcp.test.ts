/**
 * The agent surface, tested where it decides.
 *
 * Two things are worth asserting here and they are different in kind.
 *
 * The remit is arithmetic on permissions, and every one of its refusals is a
 * thing that would otherwise be a bill or a lost fact log — so it is tested the
 * way the vendor boundary is: against what it would have allowed.
 *
 * The surface is tested for a property rather than a value: that there is ONE
 * list. `tools/list` being a projection of the array `tools/call` dispatches
 * through is what makes drift unrepresentable, and a test that walked a
 * hand-written manifest would be re-introducing the second copy it exists to
 * prevent.
 */

import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { TOOLS, listed, toolNamed } from "../lib/control/mcp.ts"
import {
  CEILING,
  type Remit,
  asRemit,
  live,
  mayName,
  mayOpen,
  mayRemove,
  modest,
} from "../lib/control/remit.ts"

const grant = (remit: Remit) => ({
  id: "g",
  name: "an agent",
  owner: "someone",
  fingerprint: "f",
  remit,
  made: new Date().toISOString(),
})

describe("what a grant may do", () => {
  it("defaults to worlds and nothing that spends", () => {
    const held = modest()

    // The default matters more than the ceiling. Somebody making a grant in a
    // hurry gets this one, and it must be the one that cannot cost anything.
    assert.equal(held.clusters, "none")
    assert.equal(held.most, 0)
    assert.equal(mayOpen(held, 0).ok, false)
    assert.equal(mayRemove(held).ok, false)
  })

  it("clamps what was asked for rather than trusting it", () => {
    const asked = asRemit({
      clusters: "open+remove",
      most: 9_999,
      worlds: ["main"],
      until: new Date(Date.now() + 10 * 365 * 86_400_000).toISOString(),
    })

    assert.equal(asked.most, CEILING.most)
    assert.ok(Date.parse(asked.until) <= Date.now() + CEILING.days * 86_400_000 + 1000)
  })

  it("gives no ceiling to a grant that may not open anything", () => {
    // Otherwise a remit could say "may open nothing, at most five", which is two
    // statements that disagree and one of them will eventually be read alone.
    assert.equal(asRemit({ clusters: "none", most: 5 }).most, 0)
  })

  it("counts what is running, not what was asked for", () => {
    const remit = asRemit({ clusters: "open", most: 2 })

    assert.equal(mayOpen(remit, 1).ok, true)
    assert.equal(mayOpen(remit, 2).ok, false)

    // A rate limit does not bound spend — one machine an hour for a week costs
    // the same as a hundred and sixty-eight at once. A ceiling does.
    const said = mayOpen(remit, 2)
    if (!said.ok) assert.match(said.repair, /already 2/)
  })

  it("does not let opening imply removing", () => {
    const remit = asRemit({ clusters: "open", most: 1 })

    // Opening costs money, which is recoverable. Removing destroys a fact log,
    // which is not. One switch for both would make the recoverable act carry
    // the unrecoverable one.
    assert.equal(mayOpen(remit, 0).ok, true)
    assert.equal(mayRemove(remit).ok, false)
    assert.equal(mayRemove(asRemit({ clusters: "open+remove", most: 1 })).ok, true)
  })

  it("narrows worlds when it was narrowed, and not otherwise", () => {
    assert.equal(mayName(asRemit({ worlds: ["main"] }), "main").ok, true)
    assert.equal(mayName(asRemit({ worlds: ["main"] }), "secrets").ok, false)
    assert.equal(mayName(asRemit({}), "anything").ok, true)
  })

  it("makes a Studio grant a tenant's, whatever was asked", () => {
    // The forcing matters more than the passthrough: a grant that could name a
    // tenant's Studio AND open machines would be two credentials in one, and
    // the dangerous half would ride in on the harmless one.
    const scoped = asRemit({ studio: "s-1", clusters: "open+remove", most: 5 })

    assert.equal(scoped.studio, "s-1")
    assert.equal(scoped.clusters, "none")
    assert.equal(scoped.most, 0)
    assert.equal(mayOpen(scoped, 0).ok, false)
    assert.equal(mayRemove(scoped).ok, false)
  })

  it("does not invent a Studio from noise", () => {
    assert.equal(asRemit({ studio: "  " }).studio, undefined)
    assert.equal(asRemit({}).studio, undefined)
    // Absent entirely, not an empty string a later read mistakes for one.
    assert.ok(!("studio" in asRemit({})))
  })

  it("stops being live when revoked or expired", () => {
    const past = new Date(Date.now() - 1000).toISOString()

    assert.equal(live(grant(asRemit({}))).ok, true)
    assert.equal(live({ ...grant(asRemit({})), revoked: past }).ok, false)
    assert.equal(live(grant({ ...modest(), until: past })).ok, false)
  })

  it("says how to comply, on every refusal", () => {
    // The house rule, asserted rather than assumed: a boundary that rejects
    // without saying how produces loops, and an agent is the caller least able
    // to guess.
    const refusals = [
      mayOpen(modest(), 0),
      mayRemove(modest()),
      mayName(asRemit({ worlds: ["main"] }), "other"),
      live({ ...grant(asRemit({})), revoked: new Date().toISOString() }),
    ]

    for (const said of refusals) {
      assert.equal(said.ok, false)
      if (!said.ok) {
        assert.ok(said.repair.length > 30, `a repair that short is not a repair: ${said.repair}`)
      }
    }
  })
})

describe("the tool surface", () => {
  it("advertises exactly what it dispatches", () => {
    // The property that makes drift unrepresentable. If these ever disagree it
    // is because somebody introduced a second list, which is the thing this
    // design exists to prevent.
    assert.deepEqual(
      listed().map((one) => one.name),
      TOOLS.map((one) => one.name),
    )

    for (const one of listed()) {
      assert.equal(toolNamed(one.name)?.name, one.name)
    }
  })

  it("gives every tool a schema an agent can fill in", () => {
    for (const tool of TOOLS) {
      assert.equal(tool.inputSchema.type, "object", `${tool.name} has no object schema`)

      for (const need of tool.inputSchema.required ?? []) {
        assert.ok(
          need in tool.inputSchema.properties,
          `${tool.name} requires ${need} and does not describe it`,
        )
      }

      for (const [name, shape] of Object.entries(tool.inputSchema.properties)) {
        assert.ok(
          (shape as { description?: string }).description,
          `${tool.name}.${name} has no description — an agent has only this to go on`,
        )
      }
    }
  })

  it("performs through the same functions the console does", async () => {
    // The property worth asserting is not what these return — that needs
    // vendors — but that the agent path and the person path are ONE path.
    // Two copies of the provisioning sequence would start correct and drift,
    // and the drift would show up as an agent able to make something a person
    // could not, or the reverse.
    const opening = await import("../lib/control/opening.ts")

    assert.equal(typeof opening.openFor, "function")
    assert.equal(typeof opening.removeFor, "function")

    const source = TOOLS.map((one) => one.run.toString()).join("\n")
    assert.match(source, /openFor/)
    assert.match(source, /removeFor/)
  })

  it("never presents the founding token directly", () => {
    // Every path to a cluster resolves its token through `tokenFor`, which is
    // where a Studio-scoped grant becomes the Studio's caller and a vanished
    // Studio becomes a refusal instead of a fallback to the token that owns
    // everything. A tool reaching for `cluster.token` would be a path around
    // that, and it would look correct in every test that used an unscoped
    // grant — so it is banned at the source.
    const source = TOOLS.map((one) => one.run.toString()).join("\n")

    assert.doesNotMatch(source, /cluster\.token/)
    assert.match(source, /tokenFor/)
  })

  it("names the destructive ones destructively", () => {
    // An agent reads these and nothing else before choosing. A tool that
    // destroys a fact log and describes itself neutrally is a trap.
    assert.match(toolNamed("remove_cluster")!.description, /CANNOT BE UNDONE/)
    assert.match(toolNamed("open_cluster")!.description, /SPENDS MONEY/)
  })

  it("quotes the ontology rather than paraphrasing it", () => {
    // `words.ts` is generated from `.monty/ontology.db` and `just check` fails
    // when it is stale, so a description built from it cannot describe a cluster
    // as something this repo stopped meaning.
    assert.match(toolNamed("clusters")!.description, /A running blazie/)
  })
})
