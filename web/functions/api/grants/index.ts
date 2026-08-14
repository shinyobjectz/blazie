/**
 * The grants you have made, and making one.
 *
 * A grant is a token an agent presents and the remit it may act within. The
 * token is shown ONCE, here, and never again: what is kept is its fingerprint,
 * the same way a cluster records a caller. That is not ceremony — a namespace
 * that could hand back the tokens it has issued is a namespace whose compromise
 * hands over every agent at once.
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

export const onRequestGet: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  return answer({ grants: (await grantsOf(env, session.login)).map(grantShown) })
}

export const onRequestPost: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const asked = (await request.json().catch(() => null)) as {
    name?: string
    remit?: Record<string, unknown>
  } | null

  const name = String(asked?.name ?? "").trim()

  if (!name) {
    return refuse(
      "no_name",
      "A grant needs a name — what is holding it. A list of five tokens called nothing is a list you cannot revoke safely from.",
    )
  }

  const all = await grantsOf(env, session.login)

  if (all.some((one) => !one.revoked && one.name === name)) {
    return refuse(
      "name_taken",
      `You already hold a live grant called ${JSON.stringify(name)}. Revoke it first, or name this one differently — telling two apart is the whole reason they are named.`,
    )
  }

  const token = `blz_${mintToken()}`
  const grant: Grant = {
    id: crypto.randomUUID(),
    name,
    owner: session.login,
    fingerprint: await fingerprint(token),
    remit: asRemit(asked?.remit as never),
    made: new Date().toISOString(),
  }

  await keepGrants(env, session.login, [...all, grant])

  // The fingerprint points back, so presenting a token is one read rather than a
  // scan of every login's grants on the hot path of every agent call.
  await env.CONTROL.put(grants.by(grant.fingerprint), JSON.stringify(grant))

  return answer(
    {
      grant: grantShown(grant),
      // Once. The console must show it now or it is gone, which is said here so
      // the screen has no excuse for pretending it can be fetched again.
      token,
      shown_once: true,
    },
    201,
  )
}

export const onRequestDelete: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const id = new URL(request.url).searchParams.get("id")
  const all = await grantsOf(env, session.login)
  const found = all.find((one) => one.id === id)

  if (!found) {
    return refuse("no_such_grant", "There is no grant with that id to revoke.", 404)
  }

  // Marked, not removed. "Who could do what, and when" stays answerable, which
  // is the same reason a cluster's grants are facts rather than rows.
  found.revoked = new Date().toISOString()

  await keepGrants(env, session.login, all)
  await env.CONTROL.delete(grants.by(found.fingerprint))

  return answer({ revoked: found.id })
}
