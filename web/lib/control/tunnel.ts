/**
 * The way in, which is a way out.
 *
 * A cluster runs `cloudflared`, which dials Cloudflare and holds the connection
 * open. Requests to `<name>.blazie.dev` arrive at Cloudflare, go down that
 * connection, and reach the cluster on loopback. The machine listens on nothing.
 *
 * What this buys, in order of how much it matters:
 *
 *   * There is no port to attack. Not a filtered one — none.
 *   * No origin certificate. TLS ends at Cloudflare and the tunnel is its own
 *     encrypted connection, so there is nothing to issue, install or renew, and
 *     the strict-SSL failure that cost an afternoon on the first node cannot
 *     happen to a second one.
 *   * The WAF, the rate limiting and the DDoS protection already in front of the
 *     console are in front of every cluster, without a rule being written twice.
 *   * A cluster needs no public address at all, so it can live anywhere.
 *
 * The cost is a dependency on Cloudflare for reachability, which is a dependency
 * the console already has — it is served from there.
 */

const API = "https://api.cloudflare.com/client/v4"

export type Reaching = {
  accountId: string
  zoneId: string
  token: string
  /**
   * A second token, for the zone, when one token cannot hold both permissions.
   *
   * Cloudflare separates account-level permissions (Cloudflare Tunnel) from
   * zone-level ones (DNS), and a token minted for one commonly carries none of
   * the other. Opening a cluster needs both — a tunnel, and the record that
   * makes it reachable — so rather than insist on a single token that happens to
   * span the boundary, this accepts the split the API already has.
   *
   * Absent means one token does both, which is the tidier arrangement and still
   * the first thing to try.
   */
  dnsToken?: string
}

export type Made = {
  /** Connects a machine to this tunnel. Handed to cloud-init, never to a browser. */
  token: string
  id: string
  /** Where the cluster answers, once the machine is up. */
  address: string
}

/**
 * Whether a name is already answering on this zone.
 *
 * A cluster answers at `<name>.blazie.dev`, so names are unique across the whole
 * zone rather than per account — and the check before opening only looks at the
 * clusters YOU hold. A second person naming theirs `atlas` passes that check and
 * fails four steps later at the DNS record, after a tunnel and possibly a
 * machine have been made.
 *
 * Nobody has hit it because there is one account. That is a reason to fix it
 * now, not a reason it is not real.
 */
export async function taken(reaching: Reaching, hostname: string): Promise<boolean> {
  const found = await call(
    reaching,
    `/zones/${reaching.zoneId}/dns_records?name=${encodeURIComponent(hostname)}`,
    { method: "GET" },
  )

  return found.ok && Array.isArray(found.result) && found.result.length > 0
}

export async function make(
  reaching: Reaching,
  hostname: string,
  zone: string,
): Promise<{ ok: true; made: Made } | { ok: false; problem: string; repair: string }> {
  const tunnel = await call(reaching, `/accounts/${reaching.accountId}/cfd_tunnel`, {
    method: "POST",
    body: { name: `blazie-${hostname}`, config_src: "cloudflare" },
  })

  if (!tunnel.ok) return tunnel

  const id = (tunnel.result as { id?: string }).id
  const token = (tunnel.result as { token?: string }).token

  if (!id || !token) {
    return {
      ok: false,
      problem: "no_tunnel",
      repair: "Cloudflare made a tunnel and did not return its token, so there is nothing to give the machine. Check the API token carries Cloudflare Tunnel:Edit.",
    }
  }

  // What the tunnel does with what arrives: everything on this hostname goes to
  // the cluster on loopback. One rule, because a cluster serves one thing.
  const routed = await call(reaching, `/accounts/${reaching.accountId}/cfd_tunnel/${id}/configurations`, {
    method: "PUT",
    body: {
      config: {
        ingress: [
          { hostname: `${hostname}.${zone}`, service: "http://127.0.0.1:4000" },
          { service: "http_status:404" },
        ],
      },
    },
  })

  if (!routed.ok) return routed

  // The name it answers to. Proxied, which is what puts Cloudflare in front.
  const named = await call(reaching, `/zones/${reaching.zoneId}/dns_records`, {
    method: "POST",
    body: {
      type: "CNAME",
      name: hostname,
      content: `${id}.cfargotunnel.com`,
      proxied: true,
      comment: "a blazie cluster, opened from the console",
    },
  })

  if (!named.ok) return named

  return { ok: true, made: { id, token, address: `https://${hostname}.${zone}` } }
}

/**
 * Take the tunnel and its name away, so a forgotten cluster leaves nothing.
 *
 * The tunnel is retried, because Cloudflare refuses to delete one that still has
 * connections: "stop all cloudflared replicas, or wait a few minutes for
 * connections to close". Destroying a cluster kills the machine and the
 * connections drain afterwards, so the first attempt lands inside exactly that
 * window — measured, and it took 30 seconds to clear.
 *
 * Swallowing it left a healthy tunnel behind with four live connections while
 * the record that named it was already gone. That is the same shape as the
 * destroy that reported success while a machine kept billing, and it is worth
 * saying twice: a cleanup whose failure nobody reads is not a cleanup.
 */
export async function unmake(
  reaching: Reaching,
  id: string,
  hostname: string,
): Promise<boolean> {
  const found = await call(
    reaching,
    `/zones/${reaching.zoneId}/dns_records?name=${encodeURIComponent(hostname)}`,
    { method: "GET" },
  )

  if (found.ok && Array.isArray(found.result)) {
    for (const record of found.result as { id: string }[]) {
      await call(reaching, `/zones/${reaching.zoneId}/dns_records/${record.id}`, {
        method: "DELETE",
      })
    }
  }

  // The name goes first and the tunnel second: a record pointing at a tunnel
  // that is gone is a 1033, and a tunnel with no record is invisible.
  for (let attempt = 0; attempt < 8; attempt++) {
    const gone = await call(reaching, `/accounts/${reaching.accountId}/cfd_tunnel/${id}`, {
      method: "DELETE",
    })

    if (gone.ok) return true

    await new Promise((wake) => setTimeout(wake, 15_000))
  }

  return false
}

type Answered =
  | { ok: true; result: unknown }
  | { ok: false; problem: string; repair: string }

async function call(
  reaching: Reaching,
  path: string,
  { method, body }: { method: string; body?: unknown },
): Promise<Answered> {
  let response: Response

  // Which token by which half of the API is being asked. The path says it
  // exactly — `/zones/…` is the zone, everything else is the account — so this
  // needs no flag at the call sites and cannot be got wrong by forgetting one.
  const token = path.startsWith("/zones/") ? (reaching.dnsToken ?? reaching.token) : reaching.token

  try {
    response = await fetch(`${API}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(20_000),
    })
  } catch {
    return {
      ok: false,
      problem: "cloudflare_unreachable",
      repair: "Cloudflare's API did not answer. Nothing was changed; ask again.",
    }
  }

  const said = (await response.json().catch(() => null)) as {
    success?: boolean
    result?: unknown
    errors?: { message?: string; code?: number }[]
  } | null

  if (response.ok && said?.success) return { ok: true, result: said.result }

  const why = said?.errors?.map((e) => e.message).filter(Boolean).join("; ")

  return {
    ok: false,
    problem: "cloudflare_refused",
    repair: why
      ? `Cloudflare refused: ${why}`
      : `Cloudflare answered ${response.status} without saying why. ${
          path.startsWith("/zones/")
            ? "Check the token used for DNS carries Zone:DNS:Edit on this zone — CLOUDFLARE_DNS_TOKEN if set, otherwise CLOUDFLARE_API_TOKEN."
            : "Check CLOUDFLARE_API_TOKEN carries Account:Cloudflare Tunnel:Edit."
        }`,
  }
}
