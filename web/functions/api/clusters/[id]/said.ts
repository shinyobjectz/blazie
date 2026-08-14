/**
 * A machine saying how it is getting on.
 *
 * The only endpoint here that takes no session, because the thing calling it is
 * a machine halfway through becoming a cluster and there is nobody signed in on
 * it. What it presents instead is the opening secret, which is good for this and
 * nothing else.
 *
 * ## Why this exists at all
 *
 * The first real provision made its tunnel, its name and its machine, and then
 * stopped — and could not be asked why, because a cluster is built with no
 * password and no key. There is no way in and no way to read cloud-init's
 * output. The control plane could see only that `/me` did not answer, which is
 * the same answer for "still installing", "cloud-init died" and "the tunnel
 * never dialled" — three states needing three different responses, reported as
 * one.
 *
 * So the machine speaks first. It has outbound network by definition, since that
 * is how the tunnel works, and nothing has to be opened for it.
 */

import { answer, refuse } from "@/lib/control/answer"
import { amend, one, ownerOf, same } from "@/lib/control/clusters"
import { type Control, SAID_KEPT, type Said, isStep } from "@/lib/control/model"

export const onRequestPost: PagesFunction<Control> = async ({ env, request, params }) => {
  const id = String(params.id)

  const said = (await request.json().catch(() => null)) as {
    hello?: string
    step?: string
    detail?: string
  } | null

  if (!said?.hello || !said.step) {
    return refuse("incomplete", "Saying something needs `hello` and `step`.", 400)
  }

  if (!isStep(said.step)) {
    return refuse("no_such_step", `${JSON.stringify(said.step)} is not a step a machine reaches.`, 400)
  }

  const login = await ownerOf(env, id)
  const cluster = login ? await one(env, login, id) : null

  // Deliberately the same refusal for "no such cluster" and "wrong secret". A
  // machine that guessed an id should not learn that it guessed right.
  if (!cluster || !same(cluster.hello, said.hello)) {
    return refuse("not_yours", "That is not a cluster you can speak for.", 403)
  }

  const heard: Said = {
    step: said.step,
    at: new Date().toISOString(),
    // Bounded, because this is a machine reporting a command's output and a
    // stack trace would otherwise become a KV value that grows every retry.
    detail: said.detail ? String(said.detail).slice(0, 2_000) : undefined,
  }

  await amend(env, login!, id, {
    saying: heard,
    // Kept in order, so a failed provision carries the sequence up to it rather
    // than only the last line — which is most of the diagnosis.
    said: [...(cluster.said ?? []), heard].slice(-SAID_KEPT),
    // Reaching the last step is not the same as answering, which is checked
    // separately and is what actually decides `open`. What this does is stop a
    // machine that has finished installing from being described as opening.
    ...(said.step === "failed" ? { state: "unreachable" as const } : {}),
  })

  return answer({ heard: said.step })
}
