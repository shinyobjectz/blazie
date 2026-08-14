"use client"

import { signOut } from "@/lib/blazie"

/**
 * Signing out, from the screens that are not the console.
 *
 * It lived only in settings, which is inside the shell — and the shell is
 * exactly what does not render when the console cannot read what you hold, or
 * when you hold nothing and get the onboarding screen instead. So the two
 * states somebody is most likely to be stuck in were the two with no way out of
 * them, and the only remedy was clearing a cookie by hand.
 *
 * A dead end is a bug even when what caused it was somebody's browser
 * extension. Every screen that can be arrived at has to be one that can be left.
 */
export function WayOut() {
  return (
    <p className="text-sm text-muted-foreground">
      signed in and want out?{" "}
      <button
        type="button"
        onClick={() => {
          // Navigating in `finally` rather than `then`: if the request is what
          // is unreachable, the button still has to work, because being unable
          // to reach the control plane is the case it exists for.
          void signOut().finally(() => window.location.replace("/dashboard/"))
        }}
        className="text-white underline decoration-white/30 underline-offset-4 transition-colors hover:decoration-white"
      >
        sign out
      </button>
    </p>
  )
}
