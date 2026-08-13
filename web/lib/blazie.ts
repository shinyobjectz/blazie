/**
 * The console's client. Everything it knows how to say.
 *
 * It talks to the control plane, which is served from this same origin, and the
 * control plane talks to clusters. That indirection is the design rather than an
 * accident: a cluster's token lives there and never reaches a browser, so a
 * cluster needs no inbound port and this page needs no CORS grant.
 *
 * There used to be a `BASE` compiled in at build time, which meant the console
 * could only ever address one cluster and changing which one meant rebuilding
 * it. Which cluster is now an argument.
 *
 * The one rule this file exists to enforce: a refusal is never swallowed. Every
 * boundary in blazie rejects with a `problem` and a `repair`, and the repair is
 * how you comply. A caller that throws away the repair turns a fixable mistake
 * into a mystery, so `Refusal` carries both and every caller shows them.
 */

/** A snapshot's name: which world you read, at which transaction. */
export type SnapshotName = Record<string, number>

/** Whatever the chunk returned, shaped as JSON by the cluster. */
export type Value = unknown

export type RunResult = {
  value: Value
  /** Where the read happened, and where anything written landed. */
  name: SnapshotName
  /** How many assertions the chunk staged. Zero for a read. */
  wrote: number
}

/** A cluster, as the console is allowed to see it. Never its token. */
export type Cluster = {
  id: string
  name: string
  address: string
  state: "opening" | "open" | "unreachable"
  refusal?: { problem: string; repair: string }
  host?: { vendor: string; uuid: string; plan: string; zone: string }
  opened: string
}

export type Who = {
  login: string | null
  can: { sign_in: boolean; open_clusters: boolean }
}

/** A refusal that says how to comply. `repair` is the point — show it. */
export class Refusal extends Error {
  readonly problem: string
  readonly repair: string
  readonly status: number

  constructor(problem: string, repair: string, status: number) {
    super(`${problem}: ${repair}`)
    this.name = "Refusal"
    this.problem = problem
    this.repair = repair
    this.status = status
  }
}

export function isRefusal(error: unknown): error is Refusal {
  return error instanceof Refusal
}

/** Nobody is signed in — the one refusal the console routes on rather than shows. */
export function isUnauthenticated(error: unknown): boolean {
  return isRefusal(error) && error.status === 401
}

/* ------------------------------------------------------------- the requests */

async function send<T>(
  path: string,
  { body, method }: { body?: unknown; method?: string } = {},
): Promise<T> {
  const headers: Record<string, string> = {}
  if (body !== undefined) headers["content-type"] = "application/json"

  let response: Response

  try {
    response = await fetch(path, {
      method: method ?? (body === undefined ? "GET" : "POST"),
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      // Same origin, so the session cookie rides along without being touched by
      // anything here. There is no token for this file to read or store.
      credentials: "same-origin",
    })
  } catch {
    throw new Refusal(
      "unreachable",
      "The console could not reach its own control plane. That usually means the network went away rather than anything being wrong with a cluster.",
      0,
    )
  }

  if (response.ok) return (await response.json()) as T

  throw await refusalFrom(response)
}

async function refusalFrom(response: Response): Promise<Refusal> {
  let problem = String(response.status)
  let repair = ""

  try {
    const body = (await response.json()) as {
      error?: { problem?: string; repair?: string }
    }
    if (body?.error?.problem) problem = body.error.problem
    if (body?.error?.repair) repair = body.error.repair
  } catch {
    // Not JSON. Fall through to the invented repair below.
  }

  if (!repair) {
    repair =
      response.status === 401
        ? "This browser is not signed in. Sign in with github."
        : `Something answered ${response.status} without saying how to comply. This is worth reporting — every refusal is supposed to carry a repair.`
  }

  return new Refusal(problem, repair, response.status)
}

/* ----------------------------------------------------------------- who, and out */

export function who() {
  return send<Who>("/api/me")
}

export function signOut() {
  return send<{ signed_out: boolean }>("/api/auth/out", { body: {} })
}

/** Where signing in starts. A full navigation, because github redirects back. */
export const SIGN_IN = "/api/auth/github"

/* -------------------------------------------------------------- the clusters */

export function clusters() {
  return send<{ clusters: Cluster[] }>("/api/clusters")
}

/**
 * Ask every cluster whether it is answering, and record what it said.
 *
 * Separate from listing because it costs a request to each one — a console that
 * checked on every render would spend a cluster's own capacity finding out that
 * it is up.
 */
export function look() {
  return send<{ clusters: Cluster[] }>("/api/clusters", { method: "PATCH" })
}

export function openCluster(asked: { name: string; zone: string; plan: string }) {
  return send<{ cluster: Cluster }>("/api/clusters", { body: asked })
}

/**
 * Drop the record. With `destroy`, take the machine and the tunnel too.
 *
 * Two acts, one word, so the destructive one is never the default: forgetting a
 * cluster and deleting a database should not be the same click.
 */
export function forgetCluster(id: string, destroy = false) {
  return send<{ forgotten: string; destroyed: boolean }>(
    `/api/clusters/${encodeURIComponent(id)}${destroy ? "?destroy=1" : ""}`,
    { method: "DELETE" },
  )
}

/* ------------------------------------------------------------------ the verb */

/**
 * Run Lua against a world on a cluster.
 *
 * `name` pins which snapshot to read, so the same source at the same name is the
 * same answer forever. `also` widens the world to read; writes still land in
 * `world` and nowhere else.
 */
export function run(
  cluster: string,
  world: string,
  source: string,
  options: { name?: SnapshotName; also?: string[]; as?: "formula" | "job" } = {},
) {
  return send<RunResult>(`/api/clusters/${encodeURIComponent(cluster)}/run`, {
    body: { world, source, ...options },
  })
}

/** Which worlds this caller may name on that cluster. */
export function worldsOn(cluster: string) {
  return send<{ caller: string; login: string | null; worlds: string[] }>(
    `/api/clusters/${encodeURIComponent(cluster)}/me`,
  )
}

/** Take a world name on a cluster. First come, and yours once taken. */
export function claim(cluster: string, world: string) {
  return send<{ world: string; name: SnapshotName }>(
    `/api/clusters/${encodeURIComponent(cluster)}/worlds`,
    { body: { world } },
  )
}
