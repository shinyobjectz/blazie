/**
 * The blazie client. Everything the console knows how to say to a cluster.
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

/** A snapshot's name: which transaction of which ledger you are reading. */
export type SnapshotName = Record<string, number>

/** An id travels as a number or a string. */
export type Id = string | number

/** A symbol is always produced by a formula, never taken from outside. */
export type SymbolValue = { $symbol: { space: string; values: number[] } }

/** Any JSON value, plus the one reserved envelope. */
export type Value = unknown

export type Fact = {
  id: Id
  attribute: string
  value: Value
  tx: number
  /** null came from outside. A string names the code that produced it. */
  by: string | null
}

/**
 * An absent key is a wildcard; a present one matches exactly. There are no
 * operators — this is a pattern, not a query language.
 */
export type Pattern = {
  id?: Id
  attribute?: string
  value?: Value
  by?: string
}

export type Me = {
  login: string | null
  caller: string
  ledgers: string[]
}

export type Assertion = {
  id: Id
  attribute: string
  value: Value
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

  // Some boundaries (the generic error handler) carry no repair. Rather than
  // show a bare problem, say the most useful true thing we know.
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

/* --------------------------------------------------------- the four verbs +2 */

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

/** open — which ledgers → a snapshot name. */
export async function open(ledgers: string[]): Promise<SnapshotName> {
  const { name } = await send<{ name: SnapshotName }>("/open", {
    body: { ledgers },
  })
  return name
}

/** ask — name, question → facts. */
export async function ask(
  name: SnapshotName,
  pattern: Pattern = {},
): Promise<Fact[]> {
  const { facts } = await send<{ facts: Fact[] }>("/ask", {
    body: { name, pattern },
  })
  return facts
}

/** write — name, facts → a new name. */
export async function write(
  ledger: string,
  facts: Assertion[],
): Promise<SnapshotName> {
  const { name } = await send<{ name: SnapshotName }>("/write", {
    body: { ledger, facts },
  })
  return name
}
