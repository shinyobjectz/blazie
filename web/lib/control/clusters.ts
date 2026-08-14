/**
 * Whose clusters are whose, and what it takes to reach one.
 */

import { type Control, type Held, type Studio, keys } from "./model"

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
 * Which token to present, for a Studio or for the cluster itself.
 *
 * No Studio named means the founding caller — the one minted when the cluster
 * was opened, which owns everything on it. That is the right default for the
 * console's own housekeeping and the wrong one for a tenant, which is why
 * naming a Studio is how a tenant is spoken for.
 *
 * A Studio that does not exist is not silently the founding token. Falling back
 * would mean a typo in a Studio name quietly granting everything, which is the
 * single worst way for this to fail.
 */
export function presenting(cluster: Held, studio?: string | null): string | null {
  if (!studio) return cluster.token

  return (cluster.studios ?? []).find((s) => s.id === studio)?.token ?? null
}

/** Does this cluster hold this Studio? The scoping question, asked of a list. */
export function holdsStudio(cluster: Held, studio: string): boolean {
  return (cluster.studios ?? []).some((s) => s.id === studio)
}

/**
 * The Studio by that id, from everything this login holds.
 *
 * What a grant naming a Studio is checked against when it is MADE — so a typo
 * is refused at creation with what exists, rather than becoming a credential
 * that fails on every call with no way to say why.
 */
export async function studioHeld(
  control: Control,
  login: string,
  studio: string,
): Promise<{ cluster: Held; studio: Studio } | null> {
  for (const cluster of await held(control, login)) {
    const found = (cluster.studios ?? []).find((s) => s.id === studio)
    if (found) return { cluster, studio: found }
  }

  return null
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

/**
 * The world a cluster's first caller gets, so the console is not empty.
 *
 * A cluster boots holding `$vitals` and `$authority` — the node's own, reserved
 * behind the `$` prefix and created by the supervision tree. What it does NOT
 * have is a world the caller holds: a blazie caller is a token's fingerprint,
 * and a token holds nothing until it claims something. So a freshly opened
 * cluster answered `/me` with an empty list, and the console it dropped you into
 * said "no worlds yet" on every page and could only refuse.
 *
 * Claimed from here rather than seeded on the machine, because a grant belongs
 * to a token and the machine is deliberately never told what the token is.
 */
export const FIRST_WORLD = "main"

export async function claimFirst(
  cluster: Pick<Held, "address" | "token">,
): Promise<boolean> {
  const said = await fetch(`${cluster.address}/worlds`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${cluster.token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ world: FIRST_WORLD }),
    signal: AbortSignal.timeout(8_000),
  }).catch(() => null)

  // A name already taken is not a failure here — it means this ran twice, and
  // the second one found what the first one made.
  return Boolean(said?.ok) || said?.status === 422
}
