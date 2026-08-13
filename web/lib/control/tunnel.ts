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
}

export type Made = {
  /** Connects a machine to this tunnel. Handed to cloud-init, never to a browser. */
  token: string
  id: string
  /** Where the cluster answers, once the machine is up. */
  address: string
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

/** Take the tunnel and its name away, so a forgotten cluster leaves nothing behind. */
export async function unmake(reaching: Reaching, id: string, hostname: string) {
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

  await call(reaching, `/accounts/${reaching.accountId}/cfd_tunnel/${id}`, {
    method: "DELETE",
  })
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

  try {
    response = await fetch(`${API}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${reaching.token}`,
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
      : `Cloudflare answered ${response.status} without saying why. Check CLOUDFLARE_API_TOKEN carries Cloudflare Tunnel:Edit and DNS:Edit on this zone.`,
  }
}
