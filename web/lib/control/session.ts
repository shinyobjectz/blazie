/**
 * Who is signed in, as a cookie that carries nothing.
 *
 * The cookie holds a random id and the id names a record in KV. Nothing is
 * signed, because nothing in the cookie is worth forging: a value that is not
 * in the store is not a session, and one that is can be revoked by deleting it.
 * A signed cookie carrying a login would be smaller and could not be taken
 * back, which is the wrong trade for the thing that decides whose clusters you
 * can see.
 */

import { type Control, type Session, SESSION_SECONDS, keys } from "./model"

const COOKIE = "blazie_session"

export async function opened(
  control: Control,
  login: string,
): Promise<string> {
  const id = crypto.randomUUID()
  const session: Session = { login, opened: new Date().toISOString() }

  await control.CONTROL.put(keys.session(id), JSON.stringify(session), {
    expirationTtl: SESSION_SECONDS,
  })

  return id
}

export async function whoIs(
  control: Control,
  request: Request,
): Promise<Session | null> {
  const id = readCookie(request, COOKIE)
  if (!id) return null

  const held = await control.CONTROL.get(keys.session(id))
  return held ? (JSON.parse(held) as Session) : null
}

export async function close(control: Control, request: Request) {
  const id = readCookie(request, COOKIE)
  if (id) await control.CONTROL.delete(keys.session(id))
}

/**
 * `Secure` and `HttpOnly` and `Lax`, all three deliberately.
 *
 * HttpOnly because a session id readable by script is a session id an injected
 * script takes. Lax rather than Strict because github's redirect lands on this
 * origin as a cross-site navigation, and Strict would drop the cookie on the
 * one request that has just created it.
 */
export function setCookie(id: string): string {
  return [
    `${COOKIE}=${id}`,
    "Path=/",
    "HttpOnly",
    "Secure",
    "SameSite=Lax",
    `Max-Age=${SESSION_SECONDS}`,
  ].join("; ")
}

export function clearCookie(): string {
  return `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`
}

function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get("cookie")
  if (!header) return null

  for (const part of header.split(";")) {
    const [key, ...rest] = part.trim().split("=")
    if (key === name) return rest.join("=")
  }

  return null
}
