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
      open_clusters: Boolean(
        env.UPCLOUD_USERNAME &&
          env.UPCLOUD_PASSWORD &&
          env.CLOUDFLARE_API_TOKEN &&
          env.CLOUDFLARE_ACCOUNT_ID &&
          env.CLOUDFLARE_ZONE_ID,
      ),
    },
  })
}
