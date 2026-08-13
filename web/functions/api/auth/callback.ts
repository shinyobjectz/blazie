/**
 * Where github lands, and the only place a github secret is used.
 *
 * The exchange happens here rather than in the browser because it needs the
 * client secret, and a secret a static page can reach is not one. What the
 * browser gets back is a session cookie it cannot read.
 */

import { refuse, unconfigured } from "@/lib/control/answer"
import type { Control } from "@/lib/control/model"
import { opened, setCookie } from "@/lib/control/session"

export const onRequestGet: PagesFunction<Control> = async ({ env, request }) => {
  if (!env.GITHUB_CLIENT_ID) return unconfigured("GITHUB_CLIENT_ID")
  if (!env.GITHUB_CLIENT_SECRET) return unconfigured("GITHUB_CLIENT_SECRET")

  const code = new URL(request.url).searchParams.get("code")

  if (!code) {
    return refuse(
      "no_code",
      "github redirected here without a code. Start again from the console — this address is only ever reached from github.",
      400,
    )
  }

  const traded = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({
      client_id: env.GITHUB_CLIENT_ID,
      client_secret: env.GITHUB_CLIENT_SECRET,
      code,
    }),
    signal: AbortSignal.timeout(15_000),
  }).catch(() => null)

  const said = (await traded?.json().catch(() => null)) as
    | { access_token?: string; error_description?: string }
    | null

  if (!said?.access_token) {
    return refuse(
      "would_not_trade",
      said?.error_description ??
        "github would not trade that code for a token. A code is single-use and expires quickly — start the sign-in again.",
      401,
    )
  }

  const whom = await fetch("https://api.github.com/user", {
    headers: {
      authorization: `Bearer ${said.access_token}`,
      "user-agent": "blazie-console",
      accept: "application/vnd.github+json",
    },
    signal: AbortSignal.timeout(15_000),
  }).catch(() => null)

  const user = (await whom?.json().catch(() => null)) as { login?: string } | null

  if (!user?.login) {
    return refuse(
      "no_login",
      "github traded the code and then would not say who it belongs to. Try again.",
      502,
    )
  }

  const session = await opened(env, user.login)
  const to = new URL("/dashboard/", new URL(request.url).origin)

  return new Response(null, {
    status: 302,
    headers: { location: to.toString(), "set-cookie": setCookie(session) },
  })
}
