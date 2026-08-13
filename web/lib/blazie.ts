/**
 * The blazie client. Everything the console knows how to say to a cluster.
 *
 * There are two operations. You claim a ledger, and you run Lua against one.
 * There used to be `open`, `ask` and `write`, and between them they made the
 * console speak in facts and patterns — which is why the console read like an
 * internals tour rather than a database.
 *
 * There is no server here — `output: "export"` means this runs in the browser
 * and talks to the cluster's own HTTP API directly. The token lives in
 * localStorage because that is the only place a static page has.
 *
 * The one rule this file exists to enforce: a refusal is never swallowed. Every
 * boundary in blazie rejects with a `problem` and a `repair`, and the repair is
 * how you comply. A caller that throws away the repair turns a fixable mistake
 * into a mystery, so `Refusal` carries both and every caller shows them.
 */

const BASE = (
  process.env.NEXT_PUBLIC_BLAZIE_URL ?? "http://209.50.60.180"
).replace(/\/+$/, "")

const TOKEN_KEY = "blazie.token"

export const clusterUrl = BASE

/** A snapshot's name: which ledger you read, at which transaction. */
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

export type Me = {
  login: string | null
  caller: string
  ledgers: string[]
}

/**
 * A refusal that says how to comply. `repair` is the point — show it.
 */
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

/* ---------------------------------------------------------------- the token */

export function readToken(): string | null {
  if (typeof window === "undefined") return null
  return window.localStorage.getItem(TOKEN_KEY)
}

export function storeToken(token: string) {
  window.localStorage.setItem(TOKEN_KEY, token)
}

export function forgetToken() {
  window.localStorage.removeItem(TOKEN_KEY)
}

/* ------------------------------------------------------------- the requests */

type Sent = Record<string, unknown>

async function send<T>(
  path: string,
  { body, auth = true }: { body?: Sent; auth?: boolean } = {},
): Promise<T> {
  const headers: Record<string, string> = {}
  if (body !== undefined) headers["content-type"] = "application/json"

  if (auth) {
    const token = readToken()
    if (!token) {
      throw new Refusal(
        "no_token",
        "This browser is holding no token. Sign in with github to get one.",
        401,
      )
    }
    headers.authorization = `Bearer ${token}`
  }

  let response: Response
  try {
    response = await fetch(`${BASE}${path}`, {
      method: body === undefined ? "GET" : "POST",
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
  } catch {
    // A browser will not tell us why a fetch failed, so name every reason it
    // can be and let the operator pick. Silence is not an answer.
    throw new Refusal(
      "unreachable",
      `Nothing answered at ${BASE}. Check the cluster is up, that NEXT_PUBLIC_BLAZIE_URL points at it, and that this origin is in the cluster's console_origins.`,
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
        ? "Present a token: sign in again."
        : response.status === 404
          ? `Nothing is served at that path on ${BASE}. Check NEXT_PUBLIC_BLAZIE_URL points at a blazie cluster.`
          : `The cluster answered ${response.status} without saying how to comply. This is worth reporting — every refusal is supposed to carry a repair.`
  }

  return new Refusal(problem, repair, response.status)
}

/* --------------------------------------------------------------- the two verbs */

/** Trade a github oauth code for a token. No bearer — this is how you get one. */
export function authGithub(code: string) {
  return send<{ token: string; login: string }>("/auth/github", {
    body: { code },
    auth: false,
  })
}

/** Who this token is, and which ledgers it may name. */
export function me() {
  return send<Me>("/me")
}

/** Take a ledger name. It is granted to whoever claimed it. */
export function claim(ledger: string) {
  return send<{ ledger: string; name: SnapshotName }>("/ledgers", {
    body: { ledger },
  })
}

/**
 * Run Lua against a ledger.
 *
 * `name` pins which snapshot to read, so the same source at the same name is
 * the same answer forever. `also` widens the world to read; writes still land
 * in `ledger` and nowhere else.
 */
export function run(
  ledger: string,
  source: string,
  options: { name?: SnapshotName; also?: string[]; as?: "formula" | "job" } = {},
) {
  return send<RunResult>("/run", { body: { ledger, source, ...options } })
}
