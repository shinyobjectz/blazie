/**
 * Whose clusters are whose, and what it takes to reach one.
 */

import { type Control, type Held, keys } from "./model"

export async function held(
  control: Control,
  login: string,
): Promise<Held[]> {
  const found = await control.CONTROL.get(keys.clusters(login))
  return found ? (JSON.parse(found) as Held[]) : []
}

export async function keep(control: Control, login: string, all: Held[]) {
  await control.CONTROL.put(keys.clusters(login), JSON.stringify(all))

  // The index that lets a machine be found by what it knows about itself. Kept
  // beside the list rather than derived from it, because the machine calls home
  // before anybody has asked the console anything.
  await Promise.all(all.map((c) => control.CONTROL.put(keys.owner(c.id), login)))
}

/** Who holds this cluster, from its id alone. */
export async function ownerOf(control: Control, id: string): Promise<string | null> {
  return await control.CONTROL.get(keys.owner(id))
}

/**
 * Whether two secrets match, without leaking which character differed.
 *
 * A plain `===` on strings short-circuits at the first difference, and the time
 * that takes is measurable across enough requests. This is the one comparison
 * here that an attacker controls one side of.
 */
export function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false

  let differing = 0
  for (let i = 0; i < a.length; i++) differing |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return differing === 0
}

export async function one(
  control: Control,
  login: string,
  id: string,
): Promise<Held | null> {
  return (await held(control, login)).find((c) => c.id === id) ?? null
}

export async function amend(
  control: Control,
  login: string,
  id: string,
  change: Partial<Held>,
): Promise<Held | null> {
  const all = await held(control, login)
  const at = all.findIndex((c) => c.id === id)
  if (at < 0) return null

  all[at] = { ...all[at], ...change }
  await keep(control, login, all)
  return all[at]
}

/**
 * Ask a cluster who it thinks the caller is.
 *
 * The readiness check, and it is `/me` rather than a ping on purpose: a machine
 * that accepts a connection has not necessarily finished becoming a blazie, and
 * the question that distinguishes them is whether it can answer one about
 * itself with the token we gave it.
 */
export async function reach(
  cluster: Pick<Held, "address" | "token">,
): Promise<{ ok: true } | { ok: false; problem: string; repair: string }> {
  let response: Response

  try {
    response = await fetch(`${cluster.address}/me`, {
      headers: { authorization: `Bearer ${cluster.token}` },
      signal: AbortSignal.timeout(8_000),
    })
  } catch {
    return {
      ok: false,
      problem: "unreachable",
      repair: `Nothing answered at ${cluster.address}. If it was opened moments ago it may still be installing — a machine takes a few minutes to become a cluster.`,
    }
  }

  if (response.ok) return { ok: true }

  if (response.status === 401) {
    return {
      ok: false,
      problem: "wrong_token",
      repair: `${cluster.address} is answering but refused the token held for it. The cluster was probably rebuilt without this record being told.`,
    }
  }

  return {
    ok: false,
    problem: "not_a_cluster",
    repair: `${cluster.address} answered ${response.status} to /me, which a blazie cluster does not. Check the address points at one.`,
  }
}

/** A token a cluster will answer to, made where it can be kept. */
export function mintToken(): string {
  const bytes = new Uint8Array(32)
  crypto.getRandomValues(bytes)
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("")
}

/**
 * A name that can be a hostname, from a name a person typed.
 *
 * Refused rather than mangled when nothing survives — a cluster silently called
 * `cluster-` because its name was in another script is worse than being told to
 * pick another.
 */
export function asHostname(name: string): string | null {
  const cleaned = name
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)

  return cleaned.length > 0 ? cleaned : null
}
