/**
 * The MCP surface, hosted here rather than run on your machine.
 *
 * That placement is the security design, not a deployment convenience. The
 * ordinary shape for this is a package a developer runs locally holding the
 * UpCloud token and the Cloudflare tokens — which puts every credential this
 * system has on a laptop, next to a language model that reads untrusted text.
 * Hosted, an agent holds a grant and nothing else; the control plane performs
 * the operations and keeps the credentials, and a compromised agent can do
 * exactly what its remit says and no more.
 *
 * The transport is JSON-RPC over POST, which is what MCP's streamable HTTP
 * transport is underneath. No SSE: nothing here streams, every tool answers in
 * one shot, and a transport with a channel nothing uses is a channel to get
 * wrong.
 */

import { answer, refuse } from "@/lib/control/answer"
import { Refused, type Doing, listed, toolNamed } from "@/lib/control/mcp"
import type { Control } from "@/lib/control/model"
import { grants, live, whose } from "@/lib/control/remit"

/** What this server says it is. The protocol version is the one MCP pins. */
const SERVER = { name: "blazie", version: "1", protocolVersion: "2025-06-18" }

type Call = { jsonrpc?: string; id?: unknown; method?: string; params?: Record<string, unknown> }

export const onRequestPost: PagesFunction<Control> = async ({ env, request }) => {
  const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "")

  if (!presented) {
    return refuse(
      "no_grant",
      "This needs a grant. Make one in the console under settings, and present it as `Authorization: Bearer <token>`.",
      401,
    )
  }

  const grant = await whose(env, presented)

  // The same refusal for "no such grant" and "wrong token", so a token that
  // guessed cannot learn that it guessed a real one.
  if (!grant) {
    return refuse(
      "no_grant",
      "That token is not a grant this control plane knows. Make one in the console under settings.",
      401,
    )
  }

  const alive = live(grant)
  if (!alive.ok) return refuse(alive.problem, alive.repair, 403)

  const call = (await request.json().catch(() => null)) as Call | null
  if (!call?.method) {
    return refuse("not_jsonrpc", "This speaks JSON-RPC. Send `{jsonrpc, id, method, params}`.", 400)
  }

  // Recorded before the work, so a grant being used is visible even when the
  // work refuses — "what has this token been doing" is a question about
  // attempts, not successes.
  await noteUsed(env, grant.owner, grant.id)

  const said = await dispatch({ env, grant, home: new URL(request.url).origin }, call)
  return answer({ jsonrpc: "2.0", id: call.id ?? null, ...said })
}

async function dispatch(doing: Doing, call: Call) {
  switch (call.method) {
    case "initialize":
      return {
        result: {
          protocolVersion: SERVER.protocolVersion,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: SERVER.name, version: SERVER.version },
          // Said up front, because an agent that knows its own bound can choose
          // not to attempt what will be refused — and because a person reading
          // the agent's transcript should be able to see what it was allowed.
          instructions:
            `You are talking to a blazie control plane as the grant ${JSON.stringify(doing.grant.name)}, ` +
            `held by ${doing.grant.owner}. Its remit: clusters=${doing.grant.remit.clusters}, ` +
            `at most ${doing.grant.remit.most} running, ` +
            `worlds=${doing.grant.remit.worlds.length ? doing.grant.remit.worlds.join(",") : "any it is granted"}, ` +
            (doing.grant.remit.studio
              ? `acting as Studio ${doing.grant.remit.studio} — you see one cluster and that Studio's worlds, and the cluster itself refuses anything past that, `
              : "") +
            `until ${doing.grant.remit.until}. Refusals carry a repair — read it, it says how to comply.`,
        },
      }

    // Nothing is subscribed and nothing is notified, so these are answered
    // rather than left to time out in a client that asked politely.
    case "notifications/initialized":
      return { result: {} }

    case "ping":
      return { result: {} }

    case "tools/list":
      return { result: { tools: listed() } }

    case "tools/call":
      return callTool(doing, call)

    default:
      return {
        error: { code: -32601, message: `no such method: ${call.method}` },
      }
  }
}

async function callTool(doing: Doing, call: Call) {
  const asked = (call.params ?? {}) as { name?: string; arguments?: Record<string, unknown> }
  const tool = asked.name ? toolNamed(asked.name) : undefined

  if (!tool) {
    return { error: { code: -32602, message: `no such tool: ${String(asked.name)}` } }
  }

  try {
    const got = await tool.run(doing, asked.arguments ?? {})

    return {
      result: {
        content: [{ type: "text", text: JSON.stringify(got, null, 2) }],
        structuredContent: got,
      },
    }
  } catch (thrown) {
    // A refusal is an ANSWER, not a transport error: `isError` puts it in front
    // of the model with its repair attached, where a JSON-RPC error would reach
    // the client's plumbing and be reported as "the tool failed". Every boundary
    // here says how to comply; that is worth nothing if the model never sees it.
    const problem = thrown instanceof Refused ? thrown.problem : "unexpected"
    const repair =
      thrown instanceof Refused
        ? thrown.repair
        : thrown instanceof Error
          ? thrown.message
          : String(thrown)

    return {
      result: {
        isError: true,
        content: [{ type: "text", text: `${problem}: ${repair}` }],
        structuredContent: { error: { problem, repair } },
      },
    }
  }
}

/** Last used, on the grant. Best effort — a failed note must not fail the call. */
async function noteUsed(env: Control, login: string, id: string) {
  try {
    const all = ((await env.CONTROL.get(grants.held(login), "json")) as
      | { id: string; used?: string }[]
      | null) ?? []

    const found = all.find((one) => one.id === id)
    if (!found) return

    found.used = new Date().toISOString()
    await env.CONTROL.put(grants.held(login), JSON.stringify(all))
  } catch {
    // Deliberately swallowed. This is bookkeeping; the call is the point.
  }
}
