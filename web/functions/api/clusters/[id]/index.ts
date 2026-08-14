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
  let machineGone = true
  let tunnelGone = true

  if (destroy) {
    if (cluster.host?.vendor === "upcloud" && env.UPCLOUD_TOKEN) {
      machineGone = await upcloud.close({ token: env.UPCLOUD_TOKEN }, cluster.host.uuid)
    }

    if (env.CLOUDFLARE_API_TOKEN && env.CLOUDFLARE_ACCOUNT_ID && env.CLOUDFLARE_ZONE_ID) {
      const hostname = new URL(cluster.address).hostname
      tunnelGone = await tunnel.unmake(
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

  // A machine that would not go is the only thing worth keeping the record for.
  //
  // Both used to block it, and that made removal a state you could not leave.
  // Cloudflare refuses a tunnel with live connections, they take minutes to
  // drain, and `unmake` retried for longer than the request survives — so a
  // removal whose machine had already gone refused on the tunnel, kept the
  // record, and refused identically on every attempt after. The console showed
  // a cluster that no longer existed and would not let go of it.
  //
  // The two are not the same risk. Losing the record of a running machine loses
  // a bill nobody can see. A tunnel left behind costs nothing, answers nothing
  // once its machine is gone, and is named `blazie-<cluster>`, so it can be
  // found without the record. Only the first is worth being stuck over.
  if (destroy && !machineGone) {
    return refuse(
      "machine_remains",
      `${cluster.name}'s machine would not stop and delete, so the record has been kept — otherwise it would keep billing with nothing pointing at it. Its id is ${cluster.host?.uuid ?? "unknown"}. Ask again, or remove it from the UpCloud console.`,
      502,
    )
  }

  await keep(env, session.login, all.filter((c) => c.id !== id))

  // Said rather than refused. The caller wanted the cluster gone and it is; this
  // is one thing left draining that nobody has to wait on.
  return answer({
    forgotten: id,
    destroyed: destroy,
    ...(destroy && !tunnelGone
      ? {
          note: `The machine is gone. Its tunnel was still draining connections and Cloudflare would not delete it yet — it answers nothing now, and Cloudflare will accept a delete of blazie-${cluster.name} shortly.`,
        }
      : {}),
  })
}
