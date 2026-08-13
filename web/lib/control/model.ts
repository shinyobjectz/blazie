/**
 * What the control plane knows, and the one shape a cluster has.
 *
 * A cluster is a running blazie, reachable at an address, holding worlds — the
 * word means the same thing here as it does in `Blazie.Cluster`, which is about
 * how the nodes inside one agree on who owns which world. This is the view from
 * outside; that is the view from within.
 */

export type Held = {
  id: string
  name: string
  /** Where it answers. No trailing slash, ever — the client appends paths. */
  address: string
  /**
   * The credential this cluster answers to.
   *
   * Server-side only. It is why every call to a cluster is proxied rather than
   * made from the browser: a token the browser holds is a token in a place we
   * do not control, and the whole reason the control plane is here is to keep
   * the credentials in one that we do.
   */
  token: string
  state: State
  /** What went wrong, with how to comply. Set only when `state` is unreachable. */
  refusal?: { problem: string; repair: string }
  host?: Host
  opened: string
}

/**
 * Opening, open, or unreachable — and nothing between.
 *
 * A machine that is being made and a machine that is answering are different
 * enough that a console showing one as the other would be lying. `unreachable`
 * covers both "never came up" and "was up and is not now", deliberately: the
 * difference matters to whoever has to fix it and not at all to what the
 * console can do next, which is nothing either way.
 */
export type State = "opening" | "open" | "unreachable"

export type Host = {
  /** Whose machine. A vendor is not vocabulary, so it is a value here. */
  vendor: "upcloud"
  uuid: string
  plan: string
  zone: string
}

/**
 * A cluster as the browser is allowed to see it.
 *
 * The token is not in it and cannot be added by forgetting to remove it —
 * `shown/1` is the only way a cluster crosses the wire.
 */
export type Shown = Omit<Held, "token">

export function shown(cluster: Held): Shown {
  // Destructured out rather than deleted, so the type says the token is gone
  // instead of a cast promising it. `void` marks it as dropped on purpose.
  const { token, ...rest } = cluster
  void token
  return rest
}

export type Session = {
  login: string
  opened: string
}

/** A day. Long enough not to be a nuisance, short enough to be a session. */
export const SESSION_SECONDS = 60 * 60 * 24

/**
 * What the deployment must be told, and nothing it can work out for itself.
 *
 * Every one of these is a secret set with `wrangler pages secret put`, which is
 * why they are optional in the type: a deployment missing one refuses the
 * operations that need it, naming it and the command that sets it, rather than
 * failing somewhere further in with a stack trace.
 */
export type Control = {
  CONTROL: KVNamespace

  GITHUB_CLIENT_ID?: string
  GITHUB_CLIENT_SECRET?: string

  UPCLOUD_USERNAME?: string
  UPCLOUD_PASSWORD?: string

  /** Needs Account:Cloudflare Tunnel:Edit — and Zone:DNS:Edit unless the next one is set. */
  CLOUDFLARE_API_TOKEN?: string
  /** Only when one token cannot hold both. Used for the zone's DNS record. */
  CLOUDFLARE_DNS_TOKEN?: string
  CLOUDFLARE_ACCOUNT_ID?: string
  CLOUDFLARE_ZONE_ID?: string
  /** The zone clusters are named under. `blazie.dev` unless told otherwise. */
  CLUSTER_ZONE?: string
}

export const keys = {
  session: (id: string) => `session:${id}`,
  clusters: (login: string) => `clusters:${login}`,
}
