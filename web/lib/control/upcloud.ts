/**
 * Making a machine, and making it a cluster.
 *
 * UpCloud is a vendor, so nothing here is vocabulary — a `Host` records who the
 * machine was bought from and the rest of the control plane never asks. Adding a
 * second vendor means another file this shape, not another word.
 *
 * ## Nothing listens
 *
 * The machine is provisioned with no inbound port open, and reaches Cloudflare
 * by dialling OUT through a tunnel. That is a stronger thing than a firewall
 * rule and a simpler one: there is no origin certificate to issue and renew, no
 * list of Cloudflare's addresses to keep current as it changes, and no port for
 * anybody to find. A cluster is reachable at a hostname on this zone and by
 * nothing else, which means the WAF, the rate limiting and the DDoS protection
 * in front of the console are in front of every cluster too.
 *
 * The firewall is still set, denying everything inbound. Not because the tunnel
 * needs it — it does not — but because a machine whose safety rests on nothing
 * having been started is a machine one `apt install` away from being wrong.
 */

import type { Host } from "./model"

const API = "https://api.upcloud.com/1.3"

export type Opening = {
  name: string
  hostname: string
  zone: string
  plan: string
  /** Connects the machine to the tunnel that fronts it. */
  tunnelToken: string
  /**
   * What signs this cluster's own cookies. Generated per cluster, written once.
   *
   * The release refuses to boot without it, deliberately — so the first machine
   * this ever made would have come up dead. Caught by the gate in the image
   * workflow before any of it ran, which is the entire reason that gate starts a
   * container and asks it a question rather than trusting a successful build.
   */
  secret: string
}

/**
 * The machine is never told the cluster's token, and does not need to be.
 *
 * A blazie caller IS a token's fingerprint: any bearer token is a caller, and it
 * simply holds no worlds until it claims one. So there is nothing to install —
 * the control plane mints a token, presents it, and becomes that cluster's first
 * caller by doing so. Measured against the live node before this was written,
 * because a cloud-init that set a variable nothing read would have looked
 * exactly like one that worked.
 *
 * What makes that safe is the tunnel rather than the token. Nothing listens on
 * the machine, so the only thing on earth that can present a token to it is the
 * control plane. On a cluster reachable from the internet this arrangement would
 * be wrong, and it is one of the reasons it is not.
 */

/**
 * An UpCloud API token, presented as a bearer.
 *
 * Not the username and password the API's Basic auth also accepts — a token can
 * be scoped and revoked without touching the login that can see the invoices,
 * which is the right shape for a credential a web service holds.
 */
export type Credentials = { token: string }

/**
 * The plans offered, and nothing else.
 *
 * A free-form plan string would let a console ask for something UpCloud does not
 * sell and find out four minutes later. These are the ones a cluster is worth
 * running on: below 2GB the BEAM and a build both fit badly.
 */
export const PLANS = [
  { id: "1xCPU-2GB", label: "1 CPU · 2 GB", monthly: 9 },
  { id: "2xCPU-4GB", label: "2 CPU · 4 GB", monthly: 18 },
  { id: "4xCPU-8GB", label: "4 CPU · 8 GB", monthly: 44 },
] as const

export const ZONES = [
  { id: "uk-lon1", label: "London" },
  { id: "de-fra1", label: "Frankfurt" },
  { id: "us-nyc1", label: "New York" },
  { id: "sg-sin1", label: "Singapore" },
] as const

export function known(list: readonly { id: string }[], id: string): boolean {
  return list.some((entry) => entry.id === id)
}

/**
 * Debian 12 Bookworm, because the image is built on bookworm and a host that
 * matches it is one fewer thing that can differ between what was tested and what
 * runs.
 *
 * Read off `/1.3/storage/template` rather than trusted: the uuid written here
 * first was not a template at all, and nothing would have said so until a
 * machine failed to clone four minutes into an otherwise successful provision.
 */
const TEMPLATE = "01000000-0000-4000-8000-000020070100"

export async function open(
  credentials: Credentials,
  opening: Opening,
): Promise<{ ok: true; host: Host } | { ok: false; problem: string; repair: string }> {
  const response = await fetch(`${API}/server`, {
    method: "POST",
    headers: {
      authorization: basic(credentials),
      "content-type": "application/json",
    },
    body: JSON.stringify({
      server: {
        title: `blazie ${opening.name}`,
        hostname: opening.hostname,
        zone: opening.zone,
        plan: opening.plan,
        // No password, no keys, no console. The machine is not something anybody
        // logs into — it is something that runs one container and dials out.
        login_user: { create_password: "no" },
        metadata: "yes",
        user_data: cloudInit(opening),
        storage_devices: {
          storage_device: [
            {
              action: "clone",
              storage: TEMPLATE,
              title: `${opening.hostname} disk`,
              size: 50,
              tier: "maxiops",
            },
          ],
        },
        // Nothing inbound. The tunnel is outbound, so this closes the machine
        // without closing what it needs.
        firewall: "on",
      },
    }),
    signal: AbortSignal.timeout(30_000),
  })

  if (!response.ok) {
    return {
      ok: false,
      problem: "would_not_open",
      repair: await said(response),
    }
  }

  const body = (await response.json()) as { server?: { uuid?: string } }
  const uuid = body.server?.uuid

  if (!uuid) {
    return {
      ok: false,
      problem: "would_not_open",
      repair: "UpCloud accepted the request and did not say which machine it made, so there is nothing to point at. Check the UpCloud console before asking again — a machine may exist.",
    }
  }

  return {
    ok: true,
    host: { vendor: "upcloud", uuid, plan: opening.plan, zone: opening.zone },
  }
}

/**
 * Take the machine away, and its disk.
 *
 * Stopped first, because UpCloud refuses to delete a running server — measured,
 * after a destroy that removed the tunnel and the DNS record and left the
 * machine running and billing. That is precisely the outcome this whole design
 * claims to avoid, and it survived because the delete's failure was swallowed:
 * `.catch(() => undefined)` on a call whose success nobody checked.
 *
 * `hard`, not `soft`. A machine being destroyed is one nothing is expected from,
 * and a soft stop waits on a guest that may be the reason it is being destroyed.
 */
export async function close(credentials: Credentials, uuid: string): Promise<boolean> {
  await fetch(`${API}/server/${uuid}/stop`, {
    method: "POST",
    headers: { authorization: basic(credentials), "content-type": "application/json" },
    body: JSON.stringify({ stop_server: { stop_type: "hard" } }),
    signal: AbortSignal.timeout(30_000),
  }).catch(() => undefined)

  // Polled rather than assumed. Stopping is not instant and a delete sent too
  // early is refused exactly as it was before.
  for (let i = 0; i < 30; i++) {
    const state = await stateOf(credentials, uuid)

    // Already gone, which is a success rather than a case to handle.
    if (state === null) return true
    if (state === "stopped") break

    await new Promise((wake) => setTimeout(wake, 4_000))
  }

  const gone = await fetch(`${API}/server/${uuid}/?storages=1&backups=delete`, {
    method: "DELETE",
    headers: { authorization: basic(credentials) },
    signal: AbortSignal.timeout(60_000),
  }).catch(() => null)

  return Boolean(gone?.ok)
}

async function stateOf(credentials: Credentials, uuid: string): Promise<string | null> {
  const said = await fetch(`${API}/server/${uuid}`, {
    headers: { authorization: basic(credentials) },
    signal: AbortSignal.timeout(20_000),
  }).catch(() => null)

  if (!said?.ok) return null

  const body = (await said.json().catch(() => null)) as { server?: { state?: string } } | null
  return body?.server?.state ?? null
}

/**
 * Everything the machine does, once.
 *
 * Deliberately short. It installs a container runtime, runs one published image
 * and one tunnel, and closes everything else — there is no build here, no source
 * checkout, and no step that depends on a machine somebody is holding. A cluster
 * that could only be opened from a particular laptop would not be a product.
 */
function cloudInit(opening: Opening): string {
  return `#cloud-config
package_update: true
packages:
  - docker.io
  - ufw

write_files:
  - path: /etc/blazie.env
    permissions: "0600"
    content: |
      BLAZIE_CLUSTER=${opening.hostname}
      SECRET_KEY_BASE=${opening.secret}

runcmd:
  # Inbound: nothing. The tunnel dials out, so denying everything costs the
  # machine no reachability at all and takes away every port a scan could find.
  - ufw --force default deny incoming
  - ufw --force default allow outgoing
  - ufw --force enable

  - systemctl enable --now docker
  - mkdir -p /var/lib/blazie

  - docker run -d --name blazie --restart always
      --env-file /etc/blazie.env
      -v /var/lib/blazie:/data
      -p 127.0.0.1:4000:4000
      ghcr.io/shinyobjectz/blazie:latest

  # Reaches Cloudflare from the inside. Nothing is opened for it.
  - docker run -d --name tunnel --restart always --network host
      cloudflare/cloudflared:latest tunnel --no-autoupdate run
      --token ${opening.tunnelToken}
`
}

function basic({ token }: Credentials): string {
  return `Bearer ${token}`
}

// UpCloud says why in a shape of its own, and the operator needs the why rather
// than the status code.
async function said(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as {
      error?: { error_message?: string; error_code?: string }
    }

    if (body.error?.error_message) {
      return `UpCloud refused: ${body.error.error_message}${
        body.error.error_code ? ` (${body.error.error_code})` : ""
      }`
    }
  } catch {
    // Not JSON.
  }

  return `UpCloud answered ${response.status} without saying why. Check UPCLOUD_TOKEN, and that the account is permitted to create servers and has cores and memory left within its resource limits.`
}
