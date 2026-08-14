import { type Control, type Held, keys } from "./model"

/**
 * What an agent may do on your behalf, and the ceiling it may not pass.
 *
 * ## Why a bound rather than a role
 *
 * The client of an MCP server is a language model, and anything it reads can
 * instruct it — a README, a fetched page, a row inside one of your own worlds.
 * So the credential must be assumed compromised, and the question is never "will
 * it be careful" but "what is the worst this token can do". A role called
 * `admin` answers that with "everything". A remit answers it with a number.
 *
 * ## Why `most` counts machines and not calls
 *
 * A rate limit does not bound spend. An agent opening one machine an hour for a
 * week costs the same as one opening a hundred and sixty-eight at once, and the
 * rate limit is satisfied throughout. What bounds spend is a ceiling on how many
 * exist at a time, checked against what is actually running rather than against
 * a tally this record keeps — a counter here would be a second account of the
 * machines that can disagree with the machines.
 *
 * ## Why opening and removing are separate
 *
 * Opening costs money, which is recoverable. Removing destroys a fact log, which
 * is not. They are not the same risk, so they are not the same permission, and
 * removing is off unless it was asked for.
 */
export type Remit = {
  /** What this may do to clusters. `none` still leaves every world tool. */
  clusters: "none" | "open" | "open+remove"
  /** How many clusters may be running at once, counting the ones you opened. */
  most: number
  /** Which worlds it may name. Empty means every world the cluster grants it. */
  worlds: string[]
  /** ISO 8601. Past it, nothing is permitted and the repair says to make another. */
  until: string
}

/**
 * A credential an agent presents, and what it is allowed to do with it.
 *
 * The token is never stored — only its fingerprint, the same way a cluster
 * records a caller. A stolen copy of this namespace reveals which grants exist
 * and what they could do, and no way to be any of them.
 */
export type Grant = {
  id: string
  /** What you called it, so a list of them is readable a month later. */
  name: string
  /** Whose it is. Every action it takes is taken as this login. */
  owner: string
  /** `sha256` of the presented token, hex. */
  fingerprint: string
  remit: Remit
  made: string
  /** When it was last presented, so a grant nobody uses is visible as such. */
  used?: string
  /** Set when revoked. Kept rather than deleted, so the list says what happened. */
  revoked?: string
}

/** A grant as it may be shown. Never the fingerprint — it is a hash, but of a live secret. */
export type GrantShown = Omit<Grant, "fingerprint">

export function grantShown(grant: Grant): GrantShown {
  // Built by naming what may be shown rather than by removing what may not. A
  // field added to `Grant` later is then absent here by default instead of
  // leaking until somebody remembers to exclude it.
  return {
    id: grant.id,
    name: grant.name,
    owner: grant.owner,
    remit: grant.remit,
    made: grant.made,
    ...(grant.used ? { used: grant.used } : {}),
    ...(grant.revoked ? { revoked: grant.revoked } : {}),
  }
}

export const grants = {
  held: (login: string) => `grants:${login}`,
  /** Which login a fingerprint belongs to, so a presented token is one read. */
  by: (fingerprint: string) => `grant:${fingerprint}`,
}

/** The most a remit may ever say, whatever was asked for. */
export const CEILING = { most: 10, days: 90 } as const

/** What a grant gets when nothing else was said: worlds, and nothing that spends. */
export function modest(): Remit {
  return {
    clusters: "none",
    most: 0,
    worlds: [],
    until: new Date(Date.now() + 30 * 86_400_000).toISOString(),
  }
}

/**
 * A remit from what was asked for, clamped to what may be granted.
 *
 * Clamped rather than refused, because the caller here is the console and the
 * ceiling is not a thing a person should have to discover by trial. What comes
 * back is what will actually apply, so the screen can show it.
 */
export function asRemit(asked: Partial<Remit> | undefined): Remit {
  const held = modest()
  if (!asked) return held

  const clusters =
    asked.clusters === "open" || asked.clusters === "open+remove"
      ? asked.clusters
      : "none"

  const longest = Date.now() + CEILING.days * 86_400_000
  const until = asked.until ? Math.min(Date.parse(asked.until), longest) : Date.parse(held.until)

  return {
    clusters,
    most: clusters === "none" ? 0 : Math.max(0, Math.min(CEILING.most, Math.floor(asked.most ?? 1))),
    worlds: Array.isArray(asked.worlds) ? asked.worlds.filter((one) => typeof one === "string") : [],
    until: new Date(Number.isFinite(until) ? until : Date.parse(held.until)).toISOString(),
  }
}

export type Verdict = { ok: true } | { ok: false; problem: string; repair: string }

/** Has this grant expired, or been revoked? Asked before anything else. */
export function live(grant: Grant): Verdict {
  if (grant.revoked) {
    return {
      ok: false,
      problem: "revoked",
      repair: `The grant ${JSON.stringify(grant.name)} was revoked on ${grant.revoked}. Make another in the console under settings.`,
    }
  }

  if (Date.parse(grant.remit.until) < Date.now()) {
    return {
      ok: false,
      problem: "expired",
      repair: `The grant ${JSON.stringify(grant.name)} expired on ${grant.remit.until}. Make another in the console under settings — grants expire so an abandoned one stops being a way in.`,
    }
  }

  return { ok: true }
}

/** May this grant name this world? An empty list means it did not narrow them. */
export function mayName(remit: Remit, world: string): Verdict {
  if (remit.worlds.length === 0 || remit.worlds.includes(world)) return { ok: true }

  return {
    ok: false,
    problem: "outside_remit",
    repair: `This grant may name ${remit.worlds.map((one) => JSON.stringify(one)).join(", ")} and not ${JSON.stringify(world)}. Widen it in the console under settings, or name one of those.`,
  }
}

/**
 * May this grant open another cluster?
 *
 * `running` is counted from the clusters actually held, never from a tally kept
 * here — a count beside the machines is a second account of them that can be
 * wrong, and the one that can be wrong is always the one being checked.
 */
export function mayOpen(remit: Remit, running: number): Verdict {
  if (remit.clusters === "none") {
    return {
      ok: false,
      problem: "outside_remit",
      repair:
        "This grant may not open clusters. Opening one makes a machine that bills, so it is off unless it was asked for — change the grant in the console under settings.",
    }
  }

  if (running >= remit.most) {
    return {
      ok: false,
      problem: "at_the_ceiling",
      repair: `This grant allows ${remit.most} cluster${remit.most === 1 ? "" : "s"} at once and there ${running === 1 ? "is" : "are"} already ${running}. Remove one, or raise the ceiling in the console under settings.`,
    }
  }

  return { ok: true }
}

/** May this grant remove a cluster? Separate from opening, and off by default. */
export function mayRemove(remit: Remit): Verdict {
  if (remit.clusters === "open+remove") return { ok: true }

  return {
    ok: false,
    problem: "outside_remit",
    repair:
      "This grant may not remove clusters. Removing one destroys every world on it, which is the one thing here that cannot be undone — grant it deliberately in the console under settings if that is what you want.",
  }
}

/** The fingerprint of a presented token. The same shape a cluster records. */
export async function fingerprint(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")
}

/** Who is presenting this token, if anybody. */
export async function whose(
  control: Control,
  token: string,
): Promise<Grant | null> {
  const held = await control.CONTROL.get(grants.by(await fingerprint(token)), "json")
  return (held as Grant | null) ?? null
}

export async function grantsOf(control: Control, login: string): Promise<Grant[]> {
  return ((await control.CONTROL.get(grants.held(login), "json")) as Grant[] | null) ?? []
}

export async function keepGrants(control: Control, login: string, all: Grant[]) {
  await control.CONTROL.put(grants.held(login), JSON.stringify(all))
}

/** Unused, but kept beside the rest so the key shapes stay in one file. */
export const CLUSTERS = keys.clusters
export type { Held }
