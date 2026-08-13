/**
 * The clusters you hold, and opening one.
 *
 * Opening is the whole onboarding. There is no step where somebody copies a
 * command into a terminal, because the point of the control plane is that the
 * console can do the thing rather than explain it — and because a first cluster
 * that requires a working cluster to create would never be a first one.
 */

import { answer, refuse, unauthenticated, unconfigured } from "@/lib/control/answer"
import { asHostname, held, keep, mintToken, reach } from "@/lib/control/clusters"
import { type Control, type Held, shown } from "@/lib/control/model"
import { whoIs } from "@/lib/control/session"
import * as tunnel from "@/lib/control/tunnel"
import * as upcloud from "@/lib/control/upcloud"

export const onRequestGet: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  return answer({ clusters: (await held(env, session.login)).map(shown) })
}

export const onRequestPost: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  for (const [name, value] of [
    ["UPCLOUD_USERNAME", env.UPCLOUD_USERNAME],
    ["UPCLOUD_PASSWORD", env.UPCLOUD_PASSWORD],
    ["CLOUDFLARE_API_TOKEN", env.CLOUDFLARE_API_TOKEN],
    ["CLOUDFLARE_ACCOUNT_ID", env.CLOUDFLARE_ACCOUNT_ID],
    ["CLOUDFLARE_ZONE_ID", env.CLOUDFLARE_ZONE_ID],
  ] as const) {
    if (!value) return unconfigured(name)
  }

  const asked = (await request.json().catch(() => null)) as {
    name?: string
    zone?: string
    plan?: string
  } | null

  if (!asked?.name) {
    return refuse("no_name", "A cluster needs a name. It is what you will call it and what it answers at.")
  }

  const hostname = asHostname(asked.name)

  if (!hostname) {
    return refuse(
      "unusable_name",
      `${JSON.stringify(asked.name)} leaves nothing that can be a hostname. Use letters, digits and hyphens.`,
    )
  }

  const zone = asked.zone ?? upcloud.ZONES[0].id
  const plan = asked.plan ?? upcloud.PLANS[0].id

  if (!upcloud.known(upcloud.ZONES, zone)) {
    return refuse("no_such_zone", `There is no zone ${JSON.stringify(zone)}. Pick one of: ${upcloud.ZONES.map((z) => z.id).join(", ")}.`)
  }

  if (!upcloud.known(upcloud.PLANS, plan)) {
    return refuse("no_such_plan", `There is no plan ${JSON.stringify(plan)}. Pick one of: ${upcloud.PLANS.map((p) => p.id).join(", ")}.`)
  }

  const already = await held(env, session.login)

  if (already.some((c) => c.name === asked.name)) {
    return refuse("name_taken", `You already hold a cluster called ${JSON.stringify(asked.name)}. Names are how you tell them apart, so pick another.`)
  }

  const reaching = {
    accountId: env.CLOUDFLARE_ACCOUNT_ID!,
    zoneId: env.CLOUDFLARE_ZONE_ID!,
    token: env.CLOUDFLARE_API_TOKEN!,
    dnsToken: env.CLOUDFLARE_DNS_TOKEN,
  }

  // The way in before the machine, so a machine is never made that cannot be
  // reached. The other order leaves a server running and unreachable and
  // billing, which is the failure worth designing against.
  const made = await tunnel.make(reaching, hostname, env.CLUSTER_ZONE ?? "blazie.dev")
  if (!made.ok) return refuse(made.problem, made.repair, 502)

  const token = mintToken()

  const opened = await upcloud.open(
    { username: env.UPCLOUD_USERNAME!, password: env.UPCLOUD_PASSWORD! },
    { name: asked.name, hostname, zone, plan, tunnelToken: made.made.token, secret: mintToken() },
  )

  if (!opened.ok) {
    // Nothing half-made is left behind. A tunnel with no machine on it is
    // invisible until somebody reads a bill.
    await tunnel.unmake(reaching, made.made.id, hostname)
    return refuse(opened.problem, opened.repair, 502)
  }

  const cluster: Held = {
    id: made.made.id,
    name: asked.name,
    address: made.made.address,
    token,
    state: "opening",
    host: opened.host,
    opened: new Date().toISOString(),
  }

  await keep(env, session.login, [...already, cluster])

  return answer({ cluster: shown(cluster) }, 201)
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

      return found.ok
        ? { ...cluster, state: "open" as const, refusal: undefined }
        : {
            ...cluster,
            state: "unreachable" as const,
            refusal: { problem: found.problem, repair: found.repair },
          }
    }),
  )

  await keep(env, session.login, looked)
  return answer({ clusters: looked.map(shown) })
}
