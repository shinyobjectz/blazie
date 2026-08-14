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

  /**
   * What the machine presents when it calls home. Server-side only.
   *
   * Not the cluster's token: this one is good for exactly one endpoint, saying
   * how the install is going, and it is the only credential a machine holds. A
   * machine that has been taken over can lie about its own progress and nothing
   * else, which is the smallest useful thing to be able to say.
   */
  hello: string

  /** The last thing the machine said about becoming a cluster. */
  saying?: Said

  /**
   * The tenant boundaries on this cluster.
   *
   * A Studio is a set of worlds and a caller that may name exactly those, so
   * what is kept here is the caller — one token per Studio rather than one per
   * cluster that owns everything on it.
   *
   * Absent on a cluster opened before Studios existed, which is why every read
   * of it tolerates undefined: the founding token still works and still owns
   * everything, and a cluster is not migrated by being looked at.
   */
  studios?: Studio[]
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
 * What a machine says while it is becoming a cluster.
 *
 * A closed set rather than free text, so the console can say how far along
 * something is rather than printing a log line. The order is the order they
 * happen in, which is what makes "stuck at `pulled`" a sentence.
 */
export const STEPS = ["booted", "packages", "docker", "pulled", "serving", "tunnelled"] as const

export type Step = (typeof STEPS)[number]

export type Said = {
  /** A step reached, or `failed` — which carries what went wrong. */
  step: Step | "failed"
  at: string
  /** Set on `failed`: the command, and what it printed. */
  detail?: string
}

export function isStep(value: unknown): value is Step | "failed" {
  return value === "failed" || (STEPS as readonly string[]).includes(String(value))
}

/**
 * A cluster as the browser is allowed to see it.
 *
 * The token is not in it and cannot be added by forgetting to remove it —
 * `shown/1` is the only way a cluster crosses the wire.
 */
export type Shown = Omit<Held, "token" | "hello" | "studios"> & {
  studios: StudioShown[]
}

export function shown(cluster: Held): Shown {
  // Destructured out rather than deleted, so the type says they are gone
  // instead of a cast promising it. `void` marks them as dropped on purpose.
  const { token, hello, studios, ...rest } = cluster
  void token
  void hello

  // Mapped rather than passed through: a Studio carries a token too, and the
  // one way a credential reaches a browser is somebody forgetting a nested one.
  return { ...rest, studios: (studios ?? []).map(studioShown) }
}

/**
 * A tenant boundary: a caller that may name a set of worlds and no others.
 *
 * WHICH worlds is deliberately not stored here. That lives in the cluster's own
 * `$authority`, which is the record — and a control plane keeping its own list
 * beside it would be answering from a copy of the thing whose whole point is
 * that it is the record. Ask the cluster with this token and it says.
 */
export type Studio = {
  id: string
  name: string
  /** Server-side only, like every other credential here. */
  token: string
  opened: string
}

/** A Studio as the browser may see it: who it is, never what it presents. */
export type StudioShown = Omit<Studio, "token">

export function studioShown(studio: Studio): StudioShown {
  const { token, ...rest } = studio
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

  /** An UpCloud API token (`ucat_…`), presented as a bearer. */
  UPCLOUD_TOKEN?: string

  /**
   * Where a cluster copies itself to, and what it presents to get there.
   *
   * A cluster with no backup is one disk with no copy anywhere, which is the
   * single largest gap between what the hand-built node had and what the console
   * can make. Absent means clusters are opened without one — allowed, because a
   * default destination is a bucket nobody chose, but the console says so.
   */
  BACKUP_BUCKET?: string
  /**
   * Where blob bytes live. A different bucket from the backup, deliberately: a
   * backup is a copy of this cluster and a blob is the cluster's data, and a
   * restore that overwrote blobs with a copy of itself would be a bad day.
   */
  BLOB_BUCKET?: string
  BACKUP_ENDPOINT?: string
  BACKUP_ACCESS_KEY_ID?: string
  BACKUP_SECRET_ACCESS_KEY?: string

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

  /**
   * Which login holds a cluster, so a cluster can be found by its id alone.
   *
   * A machine calling home has no session and does not know whose it is — it
   * knows what it is. Without this the only way to find the record would be to
   * read every login's list, which is a scan that grows with the customer base
   * on the hot path of every provision.
   */
  owner: (cluster: string) => `owner:${cluster}`,
}
