/**
 * The tenant boundaries on a cluster.
 *
 * A Studio is a set of worlds and a caller that may name exactly those. Making
 * one mints a caller and nothing else — it holds no worlds until it claims
 * them, which is what makes the boundary real rather than declared: two Studios
 * cannot see each other because seeing requires naming, and naming is refused
 * at the cluster's door.
 */

import { answer, refuse, unauthenticated } from "@/lib/control/answer"
import { amend, mintToken, one } from "@/lib/control/clusters"
import { type Control, type Studio, studioShown } from "@/lib/control/model"
import { whoIs } from "@/lib/control/session"

export const onRequestGet: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const cluster = await one(env, session.login, String(params.id))
  if (!cluster) return refuse("no_such_cluster", "You hold no cluster with that id.", 404)

  return answer({ studios: (cluster.studios ?? []).map(studioShown) })
}

export const onRequestPost: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const cluster = await one(env, session.login, String(params.id))
  if (!cluster) return refuse("no_such_cluster", "You hold no cluster with that id.", 404)

  const asked = (await request.json().catch(() => null)) as { name?: string } | null

  if (!asked?.name?.trim()) {
    return refuse("no_name", "A studio needs a name. It is what you will call the tenant.")
  }

  const name = asked.name.trim()
  const held = cluster.studios ?? []

  if (held.some((s) => s.name === name)) {
    return refuse(
      "name_taken",
      `This cluster already holds a studio called ${JSON.stringify(name)}. Names are how you tell them apart.`,
    )
  }

  const studio: Studio = {
    id: crypto.randomUUID(),
    name,
    token: mintToken(),
    opened: new Date().toISOString(),
  }

  await amend(env, session.login, cluster.id, { studios: [...held, studio] })

  return answer({ studio: studioShown(studio) }, 201)
}
