/**
 * The clusters you hold, and opening one.
 *
 * Opening is the whole onboarding. There is no step where somebody copies a
 * command into a terminal, because the point of the control plane is that the
 * console can do the thing rather than explain it — and because a first cluster
 * that requires a working cluster to create would never be a first one.
 */

import { answer, refuse, unauthenticated } from "@/lib/control/answer"
import { claimFirst, held, keep, reach } from "@/lib/control/clusters"
import { type Control, shown } from "@/lib/control/model"
import { type Asked, openFor } from "@/lib/control/opening"
import { whoIs } from "@/lib/control/session"
import * as upcloud from "@/lib/control/upcloud"

/**
 * How long a machine gets to become a cluster before silence means failure.
 *
 * Measured runs reach `tunnelled` inside two minutes. Ten is deliberately far
 * past that: the cost of waiting too long is a spinner, and the cost of giving
 * up too early is telling somebody their cluster is broken while it installs.
 */
const OPENING_MS = 10 * 60 * 1000

export const onRequestGet: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  return answer({ clusters: (await held(env, session.login)).map(shown) })
}

export const onRequestPost: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const asked = (await request.json().catch(() => null)) as Asked | null

  // Every check, every order, every refusal lives in `openFor`, which the MCP
  // tool calls too. This turns the answer into HTTP and decides nothing — a
  // second copy of the provisioning sequence would start correct and drift, and
  // the drift would be invisible until an agent could provision something a
  // person could not.
  const opened = await openFor(env, session.login, asked ?? {}, new URL(request.url).origin)

  if (!opened.ok) return refuse(opened.problem, opened.repair, opened.status)

  return answer({ cluster: shown(opened.cluster) }, 201)
}

/**
 * Ask a cluster whether it has finished becoming one.
 *
 * Separate from opening because opening returns before the machine exists — a
 * request that waited for cloud-init would sit for four minutes and time out
 * somewhere in the middle, leaving the console unable to say what happened to a
 * machine that was, in fact, coming up fine.
 */
export const onRequestPatch: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const all = await held(env, session.login)

  const looked = await Promise.all(
    all.map(async (cluster) => {
      const found = await reach(cluster)

      if (found.ok) {
        // The first time it answers, and only then. A cluster with no world the
        // caller holds is a console where every page can only refuse, and this
        // is the moment there is something to claim it on.
        if (cluster.state !== "open") await claimFirst(cluster)

        return { ...cluster, state: "open" as const, refusal: undefined }
      }

      // Not answering is not the same as not going to. A machine spends its
      // first few minutes cloning a disk, installing docker and pulling an
      // image, and during all of it the address returns 530 because the tunnel
      // has nothing behind it yet. Calling that "unreachable" told somebody
      // their brand new cluster was broken while it was, in fact, working.
      //
      // So the machine's own account wins over the guess: it stays opening
      // until it says it failed, or until long enough has passed that it is not
      // coming up.
      const since = Date.now() - Date.parse(cluster.opened)
      const failed = cluster.saying?.step === "failed"

      if (!failed && since < OPENING_MS) {
        // What the vendor says, while the machine cannot say anything. This is
        // the disk-clone minute — the part that looks most like a hang and is
        // the only part with nothing of its own to report.
        const state =
          env.UPCLOUD_TOKEN && cluster.host
            ? await upcloud.stateOf({ token: env.UPCLOUD_TOKEN }, cluster.host.uuid)
            : null

        return {
          ...cluster,
          state: "opening" as const,
          refusal: undefined,
          host: cluster.host && state ? { ...cluster.host, state } : cluster.host,
        }
      }

      return {
        ...cluster,
        state: "unreachable" as const,
        refusal: { problem: found.problem, repair: found.repair },
      }
    }),
  )

  await keep(env, session.login, looked)
  return answer({ clusters: looked.map(shown) })
}
