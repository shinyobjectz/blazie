/**
 * Which image a cluster should be running.
 *
 * Asked by the machine, not told to it. A cluster listens on nothing, so there
 * is no way to push an upgrade at one — and giving it an inbound port to be
 * upgraded through would undo the reason it has none.
 *
 * Authenticated by the opening secret, the same credential the machine already
 * holds for saying how it is getting on. It is good for two questions about
 * itself and nothing else.
 */

import { answer, refuse } from "@/lib/control/answer"
import { one, ownerOf, same } from "@/lib/control/clusters"
import type { Control } from "@/lib/control/model"

/**
 * What CI publishes on every push to main.
 *
 * A tag rather than a digest, deliberately: the machine compares the digest it
 * pulled against the digest it is running, so `latest` moving is exactly the
 * signal. Pinning here would mean this file is what has to be edited to ship,
 * which is a deploy step nobody remembers.
 */
const WANTED = "ghcr.io/shinyobjectz/blazie:latest"

export const onRequestGet: PagesFunction<Control> = async ({ env, request, params }) => {
  const id = String(params.id)
  const presented = new URL(request.url).searchParams.get("hello")

  if (!presented) return refuse("incomplete", "Asking needs `hello`.", 400)

  const login = await ownerOf(env, id)
  const cluster = login ? await one(env, login, id) : null

  if (!cluster || !same(cluster.hello, presented)) {
    return refuse("not_yours", "That is not a cluster you can speak for.", 403)
  }

  return answer({ image: WANTED })
}
