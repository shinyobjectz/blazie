/**
 * Forgetting a cluster, and what that means.
 *
 * Two different acts wearing one word, so they are two requests. Forgetting
 * drops the record and leaves the machine running; `?destroy=1` takes the
 * machine and the tunnel away too. Defaulting to the destructive one because it
 * is the tidier outcome would mean a mis-click deletes a database.
 */

import { answer, refuse, unauthenticated } from "@/lib/control/answer"
import { held, keep } from "@/lib/control/clusters"
import type { Control } from "@/lib/control/model"
import { whoIs } from "@/lib/control/session"
import * as tunnel from "@/lib/control/tunnel"
import * as upcloud from "@/lib/control/upcloud"

export const onRequestDelete: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const id = String(params.id)
  const all = await held(env, session.login)
  const cluster = all.find((c) => c.id === id)

  if (!cluster) {
    return refuse("no_such_cluster", "You hold no cluster with that id. It may already have been forgotten.", 404)
  }

  const destroy = new URL(request.url).searchParams.get("destroy") === "1"

  if (destroy) {
    if (cluster.host?.vendor === "upcloud" && env.UPCLOUD_TOKEN) {
      await upcloud.close({ token: env.UPCLOUD_TOKEN }, cluster.host.uuid)
    }

    if (env.CLOUDFLARE_API_TOKEN && env.CLOUDFLARE_ACCOUNT_ID && env.CLOUDFLARE_ZONE_ID) {
      const hostname = new URL(cluster.address).hostname
      await tunnel.unmake(
        {
          accountId: env.CLOUDFLARE_ACCOUNT_ID,
          zoneId: env.CLOUDFLARE_ZONE_ID,
          token: env.CLOUDFLARE_API_TOKEN,
          dnsToken: env.CLOUDFLARE_DNS_TOKEN,
        },
        cluster.id,
        hostname,
      )
    }
  }

  await keep(env, session.login, all.filter((c) => c.id !== id))
  return answer({ forgotten: id, destroyed: destroy })
}
