/**
 * Take a world name on one of your clusters.
 *
 * The same proxy as `run`, for the same reason — the token stays here. Kept as
 * its own route rather than folded in because claiming is a different operation
 * on the cluster and pretending otherwise would mean this file deciding what a
 * chunk means, which is the cluster's job.
 */

import { refuse, unauthenticated } from "@/lib/control/answer"
import { one, presenting } from "@/lib/control/clusters"
import type { Control } from "@/lib/control/model"
import { whoIs } from "@/lib/control/session"

export const onRequestPost: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const cluster = await one(env, session.login, String(params.id))
  if (!cluster) return refuse("no_such_cluster", "You hold no cluster with that id.", 404)

  const body = await request.text()

  // Which caller to speak as. Named studio, or the founding one that owns
  // everything — and a studio that does not exist is refused rather than
  // quietly becoming the founding token, because a typo that grants everything
  // is the worst way this could fail.
  const asked = (() => {
    try {
      return JSON.parse(body || "{}") as { studio?: string }
    } catch {
      return {}
    }
  })()

  const token = presenting(cluster, asked.studio)

  if (!token) {
    return refuse(
      "no_such_studio",
      `${cluster.name} holds no studio with that id. A studio is made before it can be spoken for.`,
      404,
    )
  }

  let answered: Response

  try {
    answered = await fetch(`${cluster.address}/worlds`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body,
      signal: AbortSignal.timeout(20_000),
    })
  } catch {
    return refuse(
      "unreachable",
      `${cluster.name} did not answer. If you opened it in the last few minutes it may still be installing.`,
      502,
    )
  }

  return new Response(answered.body, {
    status: answered.status,
    headers: { "content-type": "application/json" },
  })
}
