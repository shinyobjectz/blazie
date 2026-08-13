/**
 * Run Lua against one of your clusters.
 *
 * A proxy, and the reason for it is the whole shape of this design: the cluster's
 * token lives in the control plane and does not leave it, so the browser cannot
 * call a cluster directly and does not have to be trusted with the credential
 * that would let it. What the browser sends is which cluster and what to run.
 *
 * Two things fall out for free. There is no CORS, because the console and this
 * are one origin — the `console_origins` list a cluster used to keep is no
 * longer anything anybody configures. And a cluster needs no inbound port, so
 * the only thing on earth that can reach it is this.
 */

import { refuse, unauthenticated } from "@/lib/control/answer"
import { one } from "@/lib/control/clusters"
import type { Control } from "@/lib/control/model"
import { whoIs } from "@/lib/control/session"

export const onRequestPost: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const cluster = await one(env, session.login, String(params.id))

  if (!cluster) {
    return refuse("no_such_cluster", "You hold no cluster with that id.", 404)
  }

  const body = await request.text()

  let answered: Response

  try {
    answered = await fetch(`${cluster.address}/run`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${cluster.token}`,
        "content-type": "application/json",
      },
      body,
      signal: AbortSignal.timeout(30_000),
    })
  } catch {
    return refuse(
      "unreachable",
      `${cluster.name} did not answer. If you opened it in the last few minutes it may still be installing; otherwise check it on the clusters page.`,
      502,
    )
  }

  // Passed through exactly. A cluster's refusals already carry their repair, and
  // rewrapping them here would put this in front of an answer that was already
  // the right one.
  return new Response(answered.body, {
    status: answered.status,
    headers: { "content-type": "application/json" },
  })
}
