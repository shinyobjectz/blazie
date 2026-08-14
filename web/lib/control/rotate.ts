import { one, amend, mintToken, presenting } from "./clusters"
import { fingerprint } from "./remit"
import type { Control, Held } from "./model"

/**
 * Token rotation without a reprovision.
 *
 * The cluster does the real work — SHARE each held world with the
 * successor's fingerprint, verify the successor answers, DROP the elder —
 * and those semantics are proven against a real cluster in blazie's own
 * suite (test/rotation_test.exs). This module only sequences the calls and
 * swaps the record, which is why every step here mirrors a step there:
 * this file is the sequencer, that file is the truth.
 *
 * The successor's secret is minted here and never shown to the cluster —
 * only its hash travels — and the swap happens strictly AFTER the successor
 * has answered /me with every world the elder held. A rotation that failed
 * partway leaves both tokens live (the grace window, wider than intended)
 * and the record still naming the elder: safe to retry, never stranded.
 */

export type Rotated = {
  /** Shown once, like every minted credential. */
  token: string
  worlds: string[]
}

export type Refusal = { problem: string; repair: string }

/** The wire, injectable so the sequencing is testable without a vendor. */
export type Wire = (
  cluster: Held,
  token: string,
  path: string,
  body: unknown | null,
) => Promise<{ ok: boolean; body: Record<string, unknown> }>

const overWire: Wire = async (cluster, token, path, body) => {
  const said = await fetch(`${cluster.address}${path}`, {
    method: body === null ? "GET" : "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: body === null ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  }).catch(() => null)

  if (!said) return { ok: false, body: {} }
  return { ok: said.ok, body: (await said.json().catch(() => ({}))) as Record<string, unknown> }
}

export async function rotated(
  env: Control,
  login: string,
  id: string,
  opts: { studio?: string } = {},
  wire: Wire = overWire,
): Promise<{ ok: true; rotated: Rotated } | { ok: false; refusal: Refusal }> {
  const cluster = await one(env, login, id)
  if (!cluster) {
    return refusal("no_such_cluster", "You hold no cluster with that id.")
  }

  const elder = presenting(cluster, opts.studio)
  if (!elder) {
    // Never the founding token by accident — the same no-fallback rule as
    // every other Studio resolution.
    return refusal(
      "no_such_studio",
      "That Studio is not on this cluster, so there is nothing to rotate.",
    )
  }

  const me = await wire(cluster, elder, "/me", null)
  const worlds = (me.body.worlds as string[]) ?? []
  if (!me.ok) {
    return refusal(
      "unreachable",
      "The cluster did not answer /me for the retiring token, so nothing was rotated.",
    )
  }

  const successor = mintToken()
  const print = await fingerprint(successor)

  for (const world of worlds) {
    const shared = await wire(cluster, elder, "/grants", { world, to: print })
    if (!shared.ok) {
      return refusal(
        "share_refused",
        `Sharing ${JSON.stringify(world)} was refused; nothing was swapped and both ` +
          `tokens are as they were. Retry when the cluster answers.`,
      )
    }
  }

  // The successor must ANSWER before anything is retired or recorded — a
  // record swapped on hope is a cluster nobody can reach.
  const proof = await wire(cluster, successor, "/me", null)
  const held = (proof.body.worlds as string[]) ?? []
  const missing = worlds.filter((world) => !held.includes(world))

  if (!proof.ok || missing.length > 0) {
    return refusal(
      "successor_mute",
      `The successor does not hold ${missing.join(", ") || "anything"} yet; the elder ` +
        `remains live and the record unchanged. Retry — shares are idempotent.`,
    )
  }

  for (const world of worlds) {
    await wire(cluster, elder, "/grants/drop", { world })
  }

  if (opts.studio) {
    const studios = (cluster.studios ?? []).map((studio) =>
      studio.id === opts.studio ? { ...studio, token: successor } : studio,
    )
    await amend(env, login, id, { studios })
  } else {
    await amend(env, login, id, { token: successor })
  }

  return { ok: true, rotated: { token: successor, worlds } }
}

function refusal(problem: string, repair: string): { ok: false; refusal: Refusal } {
  return { ok: false, refusal: { problem, repair } }
}
