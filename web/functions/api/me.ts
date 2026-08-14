/**
 * Who this browser is, and whether the deployment can do anything.
 *
 * `can` is here so the console can say what is missing rather than offering a
 * button that refuses. A deployment with no UpCloud credentials can still hold
 * clusters and run against them; it just cannot make one.
 */

import { answer } from "@/lib/control/answer"
import type { Control } from "@/lib/control/model"
import { whoIs } from "@/lib/control/session"

export const onRequestGet: PagesFunction<Control> = async ({ env, request }) => {
  const session = await whoIs(env, request)

  return answer({
    login: session?.login ?? null,
    can: {
      sign_in: Boolean(env.GITHUB_CLIENT_ID && env.GITHUB_CLIENT_SECRET),
      // Said rather than assumed: a cluster opened without this holds facts on
      // one disk with no copy anywhere, and that is invisible until it matters.
      back_up: Boolean(
        env.BACKUP_BUCKET &&
          env.BACKUP_ENDPOINT &&
          env.BACKUP_ACCESS_KEY_ID &&
          env.BACKUP_SECRET_ACCESS_KEY,
      ),
      open_clusters: Boolean(
        env.UPCLOUD_TOKEN &&
          env.CLOUDFLARE_API_TOKEN &&
          env.CLOUDFLARE_ACCOUNT_ID &&
          env.CLOUDFLARE_ZONE_ID,
      ),
    },
  })
}
