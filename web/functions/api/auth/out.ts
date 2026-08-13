/** Give the session back. */

import { answer } from "@/lib/control/answer"
import type { Control } from "@/lib/control/model"
import { clearCookie, close } from "@/lib/control/session"

export const onRequestPost: PagesFunction<Control> = async ({ env, request }) => {
  await close(env, request)

  const said = answer({ signed_out: true })
  said.headers.set("set-cookie", clearCookie())
  return said
}
