/**
 * Forgetting a cluster, and what that means.
 *
 * Two different acts wearing one word, so they are two requests. Forgetting
 * drops the record and leaves the machine running; `?destroy=1` takes the
 * machine and the tunnel away too. Defaulting to the destructive one because it
 * is the tidier outcome would mean a mis-click deletes a database.
 */

import { answer, refuse, unauthenticated } from "@/lib/control/answer"
import type { Control } from "@/lib/control/model"
import { removeFor } from "@/lib/control/opening"
import { whoIs } from "@/lib/control/session"

export const onRequestDelete: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  // The sequence, the order and the one refusal that blocks live in `removeFor`,
  // which the MCP tool calls too. Two copies of a teardown is how you get one
  // that stops a machine and one that does not.
  const removed = await removeFor(
    env,
    session.login,
    String(params.id),
    new URL(request.url).searchParams.get("destroy") === "1",
  )

  if (!removed.ok) return refuse(removed.problem, removed.repair, removed.status)

  const { ok, ...said } = removed
  return answer({ ...said, ok })
}
