/**
 * Device flow: an agent asks, you approve, the agent collects.
 *
 * The shape is RFC 8628's, minus the OAuth ceremony we have no use for. It
 * exists because the alternative — a key pasted into a terminal — is a secret
 * that travels through a shell history, a config file and eventually a commit.
 * Here nothing secret is typed: the agent shows a short code, you approve that
 * code in a console you are already signed into, and the token goes straight to
 * the agent over the wire it asked on.
 *
 * Three requests, all here because they are one conversation:
 *
 *   POST ?ask=1   — the agent asks. Answers a code and how long it has.
 *   POST ?ok=1    — you approve, from the console, signed in.
 *   POST          — the agent collects, presenting the code it was given.
 */

import { answer, refuse, unauthenticated } from "@/lib/control/answer"
import { mintToken } from "@/lib/control/clusters"
import type { Control } from "@/lib/control/model"
import {
  type Grant,
  asRemit,
  fingerprint,
  grantShown,
  grants,
  grantsOf,
  keepGrants,
} from "@/lib/control/remit"
import { whoIs } from "@/lib/control/session"

/**
 * Five minutes, and the code is short.
 *
 * Both follow from the same fact: a person has to read this off one screen and
 * type it into another. Long enough to do that unhurried, short enough that a
 * code seen over a shoulder is worthless by the time it is useful.
 */
const PAIRING_SECONDS = 300

/** No vowels and no 0/O/1/I — a code is read aloud and typed by hand. */
const LETTERS = "BCDFGHJKLMNPQRSTVWXZ23456789"

type Pairing = {
  code: string
  /** What the agent calls itself, shown on the approval screen. */
  called: string
  asked: string
  /** Set when approved: whose it is, and what they allowed. */
  owner?: string
  remit?: Grant["remit"]
  /** Set once collected, so a code cannot be spent twice. */
  taken?: boolean
}

const pairing = (code: string) => `pairing:${code}`

function makeCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8))
  const said = [...bytes].map((b) => LETTERS[b % LETTERS.length]).join("")
  return `${said.slice(0, 4)}-${said.slice(4)}`
}

export const onRequestPost: PagesFunction<Control> = async (context) => {
  const url = new URL(context.request.url)

  if (url.searchParams.get("ask") === "1") return asked(context)
  if (url.searchParams.get("ok") === "1") return approved(context)

  return collected(context)
}

/** The agent asks. Needs no credential — a code is worth nothing unapproved. */
async function asked({ env, request }: Parameters<PagesFunction<Control>>[0]) {
  const said = (await request.json().catch(() => null)) as { called?: string } | null

  const held: Pairing = {
    code: makeCode(),
    called: String(said?.called ?? "an agent").slice(0, 60),
    asked: new Date().toISOString(),
  }

  await env.CONTROL.put(pairing(held.code), JSON.stringify(held), {
    // The expiry is the whole of the cleanup. A pairing nobody approves has to
    // stop existing on its own, or the namespace fills with live half-grants.
    expirationTtl: PAIRING_SECONDS,
  })

  return answer(
    {
      code: held.code,
      approve_at: `${new URL(request.url).origin}/dashboard/settings/`,
      expires_in: PAIRING_SECONDS,
      // Said so the agent can wait politely rather than hammering.
      poll_every: 3,
    },
    201,
  )
}

/** You approve, from the console. This is the only step that needs a session. */
async function approved({ env, request }: Parameters<PagesFunction<Control>>[0]) {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const said = (await request.json().catch(() => null)) as {
    code?: string
    remit?: Record<string, unknown>
  } | null

  const code = String(said?.code ?? "").trim().toUpperCase()
  const held = (await env.CONTROL.get(pairing(code), "json")) as Pairing | null

  if (!held) {
    return refuse(
      "no_such_code",
      `Nothing is waiting on ${JSON.stringify(code)}. Codes last five minutes — if the agent has been sitting a while, ask it for another.`,
      404,
    )
  }

  held.owner = session.login
  held.remit = asRemit(said?.remit as never)

  await env.CONTROL.put(pairing(code), JSON.stringify(held), {
    expirationTtl: PAIRING_SECONDS,
  })

  return answer({ approved: code, called: held.called, remit: held.remit })
}

/** The agent collects. The token crosses the wire exactly once, here. */
async function collected({ env, request }: Parameters<PagesFunction<Control>>[0]) {
  const said = (await request.json().catch(() => null)) as { code?: string } | null
  const code = String(said?.code ?? "").trim().toUpperCase()
  const held = (await env.CONTROL.get(pairing(code), "json")) as Pairing | null

  if (!held) {
    return refuse("no_such_code", "That code has expired or was never asked for. Ask for another.", 404)
  }

  if (!held.owner || !held.remit) {
    // Not an error. The agent is meant to sit here, and a refusal that reads as
    // a failure would make a client give up on the normal case.
    return answer({ pending: true, code }, 202)
  }

  if (held.taken) {
    return refuse(
      "already_taken",
      "That code was already collected. A code is good for one token; ask for another.",
      409,
    )
  }

  const token = `blz_${mintToken()}`
  const grant: Grant = {
    id: crypto.randomUUID(),
    name: held.called,
    owner: held.owner,
    fingerprint: await fingerprint(token),
    remit: held.remit,
    made: new Date().toISOString(),
  }

  const all = await grantsOf(env, held.owner)
  await keepGrants(env, held.owner, [...all, grant])
  await env.CONTROL.put(grants.by(grant.fingerprint), JSON.stringify(grant))

  // Spent. Kept rather than deleted for its remaining ttl, so a second attempt
  // is told it was already collected instead of being told nothing exists —
  // which is the difference between a clear answer and a mystery.
  held.taken = true
  await env.CONTROL.put(pairing(code), JSON.stringify(held), { expirationTtl: 60 })

  return answer({ token, grant: grantShown(grant) }, 201)
}
