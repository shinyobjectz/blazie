/** Who the control plane is on that cluster, and which worlds it may name. */

import { refuse, unauthenticated } from "@/lib/control/answer"
import { one } from "@/lib/control/clusters"
import type { Control } from "@/lib/control/model"
import { whoIs } from "@/lib/control/session"

export const onRequestGet: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const cluster = await one(env, session.login, String(params.id))
  if (!cluster) return refuse("no_such_cluster", "You hold no cluster with that id.", 404)

  let answered: Response

  try {
    answered = await fetch(`${cluster.address}/me`, {
      headers: { authorization: `Bearer ${cluster.token}` },
      signal: AbortSignal.timeout(15_000),
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
