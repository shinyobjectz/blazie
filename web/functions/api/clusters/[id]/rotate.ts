/**
 * Rotate a cluster's credential — the founding token, or one Studio's.
 *
 * The new token comes back exactly once, like every minted credential. The
 * sequencing and its safety (both tokens live until the successor answers,
 * a failed rotation leaves the record unchanged) live in `lib/control/rotate`.
 */

import { answer, refuse, unauthenticated } from "@/lib/control/answer"
import { rotated } from "@/lib/control/rotate"
import type { Control } from "@/lib/control/model"
import { whoIs } from "@/lib/control/session"

export const onRequestPost: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const asked = (await request.json().catch(() => null)) as { studio?: string } | null

  const outcome = await rotated(env, session.login, String(params.id), {
    studio: asked?.studio,
  })

  if (!outcome.ok) return refuse(outcome.refusal.problem, outcome.refusal.repair)

  return answer({
    rotated: outcome.rotated.worlds,
    token: outcome.rotated.token,
    shown_once: true,
  })
}
