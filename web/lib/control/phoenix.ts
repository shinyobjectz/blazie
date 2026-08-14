/**
 * Speaking Phoenix's channel protocol, from the control plane.
 *
 * A cluster can already push a re-answered chunk every time a fact lands inside
 * what that chunk read. It is the best thing blazie does and the console could
 * not reach it, because the socket wants a token in its connect params and the
 * browser must never hold one.
 *
 * ## Why this rather than the other two
 *
 * A Durable Object could hold the socket for the browser. It keeps every
 * property and costs a paid product, a second deployable and a coordination
 * layer for something that coordinates nothing — one viewer, one query.
 *
 * The browser could open the socket straight to `<cluster>.blazie.dev` with a
 * short-lived token minted for it. Cheapest to build and it gives up the thing
 * the whole proxy exists for. Worse, blazie has no read-only grant: a token
 * scoped to the world being watched can also write to it, so "watch this" would
 * hand out the ability to change it.
 *
 * So: the control plane holds the websocket and hands the browser a stream. A
 * Worker can dial out with `Upgrade: websocket` and read `response.webSocket`
 * without a Durable Object, and can answer with a `ReadableStream` at the same
 * time. The token stays where every other token stays.
 *
 * The cost, said plainly: a Worker invocation is alive for as long as somebody
 * is watching, where a `run` is alive for a moment. That is a real bill and a
 * real limit, and it is why watching is something a page asks for rather than
 * something every page does.
 */

/**
 * Phoenix v2 frames are positional arrays, not objects.
 *
 * `[join_ref, ref, topic, event, payload]` — undocumented in the sense that it
 * is a wire format rather than an API, so it is written down here rather than
 * inferred at three call sites.
 */
export type Frame = [string | null, string | null, string, string, unknown]

export function frame(
  joinRef: string | null,
  ref: string | null,
  topic: string,
  event: string,
  payload: unknown,
): string {
  return JSON.stringify([joinRef, ref, topic, event, payload] satisfies Frame)
}

export function readFrame(raw: string): Frame | null {
  try {
    const said = JSON.parse(raw)
    return Array.isArray(said) && said.length === 5 ? (said as Frame) : null
  } catch {
    return null
  }
}

/** Joining a watch: the topic names it, the payload says what to keep answering. */
export function joining(topic: string, world: string, source: string): string {
  return frame("1", "1", topic, "phx_join", { world, source })
}

/**
 * Phoenix closes a socket that stops talking, so this is not optional.
 *
 * 30s is the default `heartbeat_interval` on the client side; the server's
 * timeout is 60s, so one missed beat is survivable and two are not.
 */
export function heartbeat(ref: number): string {
  return frame(null, String(ref), "phoenix", "heartbeat", {})
}

export const HEARTBEAT_MS = 30_000

/** Where a cluster's socket lives, with the credential the browser never sees. */
export function socketUrl(address: string, token: string): string {
  const url = new URL(`${address}/socket/websocket`)

  // `fetch` upgrades an https URL; `wss://` is what a browser would use and is
  // not what a Worker dials.
  url.searchParams.set("token", token)
  url.searchParams.set("vsn", "2.0.0")

  return url.toString()
}

/** One server-sent event. Named so the browser can tell an answer from a refusal. */
export function event(name: string, data: unknown): string {
  return `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`
}
