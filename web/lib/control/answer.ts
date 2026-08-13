/**
 * How the control plane answers, and how it refuses.
 *
 * The same rule the cluster itself is under: a boundary that rejects without
 * saying how to comply produces loops rather than compliance. So there is one
 * refusal shape here and it is the cluster's own — `{error: {problem, repair}}`
 * — which means the console has one way to read a failure whether it came from
 * a cluster or from the thing in front of it.
 */

export function answer(body: unknown, status = 200): Response {
  return Response.json(body, { status })
}

export function refuse(
  problem: string,
  repair: string,
  status = 422,
): Response {
  return Response.json({ error: { problem, repair } }, { status })
}

/** Nobody is signed in. Said the same way everywhere so the console can act on it. */
export function unauthenticated(): Response {
  return refuse(
    "not_signed_in",
    "This browser is not signed in. Sign in with github from the console.",
    401,
  )
}

/**
 * A setting the deployment needs and does not have.
 *
 * Named rather than generic, because the repair is a command somebody has to
 * run and a message that does not contain it wastes the operator's afternoon.
 */
export function unconfigured(setting: string): Response {
  return refuse(
    "not_configured",
    `This deployment has no ${setting}. Set it with: npx wrangler pages secret put ${setting} --project-name blazie`,
    503,
  )
}
