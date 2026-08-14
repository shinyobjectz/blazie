/**
 * The rotation sequencer, against a wire speaking the cluster's proven
 * semantics.
 *
 * The TRUTH of share/drop lives in blazie's own suite against a real
 * cluster (test/rotation_test.exs); this fake implements exactly that
 * contract so what is tested here is the sequencing — the order of calls,
 * the record swapped only after the successor answers, and a failure
 * leaving everything as it was.
 */

import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { rotated, type Wire } from "../lib/control/rotate.ts"
import type { Held } from "../lib/control/model.ts"

function kv() {
  const held = new Map<string, string>()
  return {
    CONTROL: {
      get: async (key: string, kind?: string) => {
        const value = held.get(key) ?? null
        return kind === "json" && value ? JSON.parse(value) : value
      },
      put: async (key: string, value: string) => void held.set(key, value),
      delete: async (key: string) => void held.delete(key),
    },
  } as never
}

function cluster(): Held {
  return {
    id: "c-1",
    name: "demo",
    address: "https://demo.blazie.dev",
    token: "OLD-FOUNDING",
    state: "open",
    hello: "h",
    opened: "2026-08-14",
    studios: [{ id: "s-1", name: "tenant", token: "OLD-STUDIO", opened: "2026-08-14" }],
  }
}

async function seeded(env: never, held: Held) {
  await (env as { CONTROL: { put: (k: string, v: string) => Promise<void> } }).CONTROL.put(
    "clusters:me",
    JSON.stringify([held]),
  )
}

/** The cluster's contract, in miniature: grants by fingerprint, shares by holders. */
function fakeCluster(worlds: string[], initialToken: string) {
  const calls: string[] = []
  const holding = new Map<string, Set<string>>([[initialToken, new Set(worlds)]])
  const byPrint = new Map<string, string>()

  const wire: Wire = async (_cluster, token, path, body) => {
    calls.push(`${token.slice(0, 9)} ${path}`)
    const asked = (body ?? {}) as { world?: string; to?: string }
    const mine = holding.get(token) ?? holding.get(byPrint.get(await print(token)) ?? "") ?? null

    if (path === "/me") {
      const held = [...(holdingFor(token) ?? [])]
      return { ok: holdingFor(token) !== null, body: { worlds: held } }
    }

    if (path === "/grants") {
      if (!mine?.has(asked.world!)) return { ok: false, body: {} }
      const set = printHolding(asked.to!)
      set.add(asked.world!)
      return { ok: true, body: { shared: asked.world } }
    }

    if (path === "/grants/drop") {
      holdingFor(token)?.delete(asked.world!)
      return { ok: true, body: { dropped: asked.world } }
    }

    return { ok: false, body: {} }
  }

  function holdingFor(token: string): Set<string> | null {
    if (holding.has(token)) return holding.get(token)!
    // A fresh token holds what its fingerprint was granted.
    const printed = prints.get(token)
    if (printed && printHeld.has(printed)) return printHeld.get(printed)!
    return null
  }

  const prints = new Map<string, string>()
  const printHeld = new Map<string, Set<string>>()

  function printHolding(fingerprint: string): Set<string> {
    if (!printHeld.has(fingerprint)) printHeld.set(fingerprint, new Set())
    return printHeld.get(fingerprint)!
  }

  async function print(token: string): Promise<string> {
    if (!prints.has(token)) {
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))
      prints.set(
        token,
        [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join(""),
      )
    }
    return prints.get(token)!
  }

  // Every token's print is computable up front for the fake's bookkeeping.
  const ready = (token: string) => print(token)

  return { wire, calls, ready }
}

describe("rotation sequences the proven verbs, in the proven order", () => {
  it("swaps the founding token only after the successor answers", async () => {
    const env = kv()
    await seeded(env, cluster())
    const fake = fakeCluster(["main", "audit"], "OLD-FOUNDING")

    const outcome = await rotated(env, "me", "c-1", {}, fake.wire)

    assert.equal(outcome.ok, true)
    if (!outcome.ok) return

    // The successor is fresh, shown once, and the record now names it.
    assert.notEqual(outcome.rotated.token, "OLD-FOUNDING")
    assert.deepEqual(outcome.rotated.worlds.sort(), ["audit", "main"])

    const kept = (await (env as never as { CONTROL: { get: (k: string, kind: string) => Promise<Held[]> } }).CONTROL.get(
      "clusters:me",
      "json",
    ))![0]
    assert.equal(kept.token, outcome.rotated.token)

    // The order IS the safety: read, share everything, prove the successor,
    // only then drop the elder.
    const shape = fake.calls.map((c) => c.split(" ")[1])
    assert.deepEqual(shape, ["/me", "/grants", "/grants", "/me", "/grants/drop", "/grants/drop"])
  })

  it("a mute successor leaves both tokens live and the record unchanged", async () => {
    const env = kv()
    await seeded(env, cluster())

    // A wire whose shares succeed but whose successor never answers /me.
    const wire: Wire = async (_c, token, path) => {
      if (path === "/me" && token === "OLD-FOUNDING") return { ok: true, body: { worlds: ["main"] } }
      if (path === "/me") return { ok: false, body: {} }
      if (path === "/grants") return { ok: true, body: {} }
      throw new Error(`the elder was retired on hope: ${path}`)
    }

    const outcome = await rotated(env, "me", "c-1", {}, wire)
    assert.equal(outcome.ok, false)
    if (outcome.ok) return
    assert.equal(outcome.refusal.problem, "successor_mute")
    assert.match(outcome.refusal.repair, /Retry/)

    const kept = (await (env as never as { CONTROL: { get: (k: string, kind: string) => Promise<Held[]> } }).CONTROL.get(
      "clusters:me",
      "json",
    ))![0]
    assert.equal(kept.token, "OLD-FOUNDING")
  })

  it("rotating a Studio touches that Studio's token and nothing else", async () => {
    const env = kv()
    await seeded(env, cluster())
    const fake = fakeCluster(["tenant-world"], "OLD-STUDIO")

    const outcome = await rotated(env, "me", "c-1", { studio: "s-1" }, fake.wire)
    assert.equal(outcome.ok, true)
    if (!outcome.ok) return

    const kept = (await (env as never as { CONTROL: { get: (k: string, kind: string) => Promise<Held[]> } }).CONTROL.get(
      "clusters:me",
      "json",
    ))![0]
    assert.equal(kept.token, "OLD-FOUNDING")
    assert.equal(kept.studios![0].token, outcome.rotated.token)
  })

  it("a Studio that is not there is a refusal, never the founding token", async () => {
    const env = kv()
    await seeded(env, cluster())

    const outcome = await rotated(env, "me", "c-1", { studio: "s-typo" }, async () => {
      throw new Error("no wire call may happen for a missing studio")
    })

    assert.equal(outcome.ok, false)
    if (outcome.ok) return
    assert.equal(outcome.refusal.problem, "no_such_studio")
  })
})
