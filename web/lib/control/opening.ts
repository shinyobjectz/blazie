import { asHostname, held, keep, mintToken } from "./clusters"
import { type Control, type Held } from "./model"
import * as tunnel from "./tunnel"
import * as upcloud from "./upcloud"

/**
 * Opening a cluster and taking one away, as functions rather than as endpoints.
 *
 * They were the bodies of two `PagesFunction`s, which was fine while a person
 * with a session was the only thing that could ask. An agent asks now, and the
 * choice was between calling this logic or writing it again for the other
 * caller — and every check in here was paid for by a failure: a template uuid
 * that was not a template, a name already answering on the zone, a trial
 * firewall that no tunnel can survive, a machine made before the way in.
 *
 * A second copy would have started correct and drifted, and the drift would be
 * invisible until an agent provisioned something a person could not. So there
 * is one copy and both callers are thin.
 *
 * What stays at the boundary is presentation: the endpoints turn these into
 * HTTP, the MCP tools turn them into refusals a model can read. Neither decides
 * anything.
 */

export type Opened =
  | { ok: true; cluster: Held }
  | { ok: false; problem: string; repair: string; status: number }

export type Asked = { name?: string; zone?: string; plan?: string }

/** Everything the control plane must be told before it can make a machine. */
export function configured(env: Control): string | null {
  for (const [name, value] of [
    ["UPCLOUD_TOKEN", env.UPCLOUD_TOKEN],
    ["CLOUDFLARE_API_TOKEN", env.CLOUDFLARE_API_TOKEN],
    ["CLOUDFLARE_ACCOUNT_ID", env.CLOUDFLARE_ACCOUNT_ID],
    ["CLOUDFLARE_ZONE_ID", env.CLOUDFLARE_ZONE_ID],
  ] as const) {
    if (!value) return name
  }

  return null
}

const no = (problem: string, repair: string, status = 422): Opened => ({
  ok: false,
  problem,
  repair,
  status,
})

/**
 * Make a cluster for this login.
 *
 * The order is the whole design and it is the order of what cannot be undone:
 * everything that can be checked is checked before anything is made, the way in
 * is made before the machine, and the record is written before the machine can
 * report on itself. Each of those was learned from the version that did it the
 * other way round.
 */
export async function openFor(
  env: Control,
  login: string,
  asked: Asked,
  home: string,
): Promise<Opened> {
  const missing = configured(env)
  if (missing) {
    return no(
      "not_configured",
      `This deployment has no ${missing}. Set it with: npx wrangler pages secret put ${missing} --project-name blazie`,
      503,
    )
  }

  if (!asked.name) {
    return no("no_name", "A cluster needs a name. It is what you will call it and what it answers at.")
  }

  const hostname = asHostname(asked.name)

  if (!hostname) {
    return no(
      "unusable_name",
      `${JSON.stringify(asked.name)} leaves nothing that can be a hostname. Use letters, digits and hyphens.`,
    )
  }

  const zone = asked.zone ?? upcloud.ZONES[0].id
  const plan = asked.plan ?? upcloud.PLANS[0].id

  if (!upcloud.known(upcloud.ZONES, zone)) {
    return no(
      "no_such_zone",
      `There is no zone ${JSON.stringify(zone)}. Pick one of: ${upcloud.ZONES.map((z) => z.id).join(", ")}.`,
    )
  }

  if (!upcloud.known(upcloud.PLANS, plan)) {
    return no(
      "no_such_plan",
      `There is no plan ${JSON.stringify(plan)}. Pick one of: ${upcloud.PLANS.map((p) => p.id).join(", ")}.`,
    )
  }

  const already = await held(env, login)

  if (already.some((c) => c.name === asked.name)) {
    return no(
      "name_taken",
      `You already hold a cluster called ${JSON.stringify(asked.name)}. Names are how you tell them apart, so pick another.`,
    )
  }

  // Asked before anything is made. A trial account's firewall cannot be
  // disabled or modified and drops outbound 7844, which is the only port
  // cloudflared can reach Cloudflare on — so a cluster opened on one installs
  // perfectly and never connects. Three provisions found that out the long way.
  const allowed = await upcloud.limits({ token: env.UPCLOUD_TOKEN! })

  if (!allowed.ok) return no(allowed.problem, allowed.repair, 502)

  if (allowed.trialFirewall) {
    return no(
      "trial_account",
      "This UpCloud account is in trial mode, and a trial firewall cannot be changed or turned off. It drops outbound 7844, which is the only port a Cloudflare Tunnel can use — so a cluster opened here would install correctly and never become reachable. Take the account out of trial in the UpCloud control panel, then open it again.",
      409,
    )
  }

  // Whether it fits, before anything is made. UpCloud refuses a machine that
  // exceeds the account's cores or memory, and finding that out after a tunnel
  // exists is finding it out too late — the same lesson as the name.
  const wanted = upcloud.PLANS.find((p) => p.id === plan)!
  const using = await upcloud.spent({ token: env.UPCLOUD_TOKEN! })

  if (allowed.cores !== null && using.cores + wanted.cores > allowed.cores) {
    return no(
      "no_room",
      `This account allows ${allowed.cores} cores and is using ${using.cores}. ${wanted.label} needs ${wanted.cores}, which does not fit — pick a smaller one, or take a cluster away first.`,
      409,
    )
  }

  if (allowed.memory !== null && using.memory + wanted.memory > allowed.memory) {
    return no(
      "no_room",
      `This account allows ${allowed.memory}MB of memory and is using ${using.memory}. ${wanted.label} needs ${wanted.memory}MB, which does not fit — pick a smaller one, or take a cluster away first.`,
      409,
    )
  }

  const reaching = {
    accountId: env.CLOUDFLARE_ACCOUNT_ID!,
    zoneId: env.CLOUDFLARE_ZONE_ID!,
    token: env.CLOUDFLARE_API_TOKEN!,
    dnsToken: env.CLOUDFLARE_DNS_TOKEN,
  }

  // Asked of the zone, not of your own list. A cluster answers at
  // `<name>.blazie.dev`, so the name is global — and finding that out from a
  // failed DNS write, after a tunnel exists, is finding it out too late.
  if (await tunnel.taken(reaching, `${hostname}.${env.CLUSTER_ZONE ?? "blazie.dev"}`)) {
    return no(
      "name_answered_for",
      `${JSON.stringify(asked.name)} already answers on this zone. Cluster names are global rather than per account, because a cluster IS its name — pick another.`,
    )
  }

  // The way in before the machine, so a machine is never made that cannot be
  // reached. The other order leaves a server running and unreachable and
  // billing, which is the failure worth designing against.
  const made = await tunnel.make(reaching, hostname, env.CLUSTER_ZONE ?? "blazie.dev")
  if (!made.ok) return no(made.problem, made.repair, 502)

  const token = mintToken()
  const hello = mintToken()

  const opened = await upcloud.open(
    { token: env.UPCLOUD_TOKEN! },
    {
      name: asked.name,
      hostname,
      zone,
      plan,
      tunnelToken: made.made.token,
      secret: mintToken(),
      masterKey: mintToken(),
      // Where to report, taken from the request rather than written down, so a
      // preview deployment provisions machines that call the preview back.
      home,
      id: made.made.id,
      hello,
      // A prefix per cluster, keyed by id rather than name — a name can be
      // given up and taken by somebody else, and a backup must not follow the
      // name to a different cluster.
      backup:
        env.BACKUP_BUCKET && env.BACKUP_ENDPOINT && env.BACKUP_ACCESS_KEY_ID && env.BACKUP_SECRET_ACCESS_KEY
          ? {
              bucket: env.BACKUP_BUCKET,
              endpoint: env.BACKUP_ENDPOINT,
              accessKeyId: env.BACKUP_ACCESS_KEY_ID,
              secretAccessKey: env.BACKUP_SECRET_ACCESS_KEY,
              prefix: `clusters/${made.made.id}/`,
            }
          : undefined,
      blobs:
        env.BLOB_BUCKET && env.BACKUP_ENDPOINT && env.BACKUP_ACCESS_KEY_ID && env.BACKUP_SECRET_ACCESS_KEY
          ? {
              bucket: env.BLOB_BUCKET,
              endpoint: env.BACKUP_ENDPOINT,
              accessKeyId: env.BACKUP_ACCESS_KEY_ID,
              secretAccessKey: env.BACKUP_SECRET_ACCESS_KEY,
              prefix: `clusters/${made.made.id}/`,
            }
          : undefined,
    },
  )

  if (!opened.ok) {
    // Nothing half-made is left behind. A tunnel with no machine on it is
    // invisible until somebody reads a bill.
    await tunnel.unmake(reaching, made.made.id, hostname)
    return no(opened.problem, opened.repair, 502)
  }

  const cluster: Held = {
    id: made.made.id,
    name: asked.name,
    address: made.made.address,
    token,
    hello,
    state: "opening",
    host: opened.host,
    opened: new Date().toISOString(),
  }

  // Written before the machine can report, so a step it sends has somewhere to
  // land. The other order raced its own cloud-init.
  await keep(env, login, [...already, cluster])

  return { ok: true, cluster }
}

export type Removed =
  | { ok: true; forgotten: string; destroyed: boolean; note?: string }
  | { ok: false; problem: string; repair: string; status: number }

/**
 * Drop the record, and with `destroy` take the machine and the way in too.
 *
 * Only a machine that would not go blocks the record from being dropped. Both
 * used to, and that made removal a state you could not leave: Cloudflare refuses
 * a tunnel with live connections, they take minutes to drain, so a removal whose
 * machine had already gone refused on the tunnel and refused identically on
 * every attempt after. Losing the record of a running machine loses a bill
 * nobody can see; a leftover tunnel costs nothing and is named after its
 * cluster.
 */
export async function removeFor(
  env: Control,
  login: string,
  id: string,
  destroy: boolean,
): Promise<Removed> {
  const all = await held(env, login)
  const cluster = all.find((one) => one.id === id)

  if (!cluster) {
    return { ok: false, problem: "no_such_cluster", repair: "There is no cluster with that id.", status: 404 }
  }

  let machineGone = true
  let tunnelGone = true

  if (destroy) {
    if (cluster.host?.vendor === "upcloud" && env.UPCLOUD_TOKEN) {
      machineGone = await upcloud.close({ token: env.UPCLOUD_TOKEN }, cluster.host.uuid)
    }

    if (env.CLOUDFLARE_API_TOKEN && env.CLOUDFLARE_ACCOUNT_ID && env.CLOUDFLARE_ZONE_ID) {
      tunnelGone = await tunnel.unmake(
        {
          accountId: env.CLOUDFLARE_ACCOUNT_ID,
          zoneId: env.CLOUDFLARE_ZONE_ID,
          token: env.CLOUDFLARE_API_TOKEN,
          dnsToken: env.CLOUDFLARE_DNS_TOKEN,
        },
        cluster.id,
        new URL(cluster.address).hostname,
      )
    }
  }

  if (destroy && !machineGone) {
    return {
      ok: false,
      problem: "machine_remains",
      repair: `${cluster.name}'s machine would not stop and delete, so the record has been kept — otherwise it would keep billing with nothing pointing at it. Its id is ${cluster.host?.uuid ?? "unknown"}. Ask again, or remove it from the UpCloud console.`,
      status: 502,
    }
  }

  await keep(env, login, all.filter((one) => one.id !== id))

  return {
    ok: true,
    forgotten: id,
    destroyed: destroy,
    ...(destroy && !tunnelGone
      ? {
          note: `The machine is gone. Its tunnel was still draining connections and Cloudflare would not delete it yet — it answers nothing now, and Cloudflare will accept a delete of blazie-${cluster.name} shortly.`,
        }
      : {}),
  }
}
