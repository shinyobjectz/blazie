/**
 * Where signing in starts.
 *
 * A redirect rather than a link the console builds, so the client id lives in
 * one place — a secret on the deployment — instead of being compiled into a
 * static page where changing it means rebuilding the console.
 */

import { unconfigured } from "@/lib/control/answer"
import type { Control } from "@/lib/control/model"

export const onRequestGet: PagesFunction<Control> = async ({ env, request }) => {
  if (!env.GITHUB_CLIENT_ID) return unconfigured("GITHUB_CLIENT_ID")

  const here = new URL(request.url)

  const to = new URL("https://github.com/login/oauth/authorize")
  to.searchParams.set("client_id", env.GITHUB_CLIENT_ID)
  // `/callback/github`, because that is what this OAuth app has registered and
  // github matches the redirect against it. A tidier `/api/auth/callback` would
  // have been refused on every sign-in — github allows a subpath of the
  // registered URL and that is not one.
  to.searchParams.set("redirect_uri", `${here.origin}/callback/github`)
  // Nothing is read from github but who you are, so nothing is asked for.
  to.searchParams.set("scope", "read:user")

  return Response.redirect(to.toString(), 302)
}
