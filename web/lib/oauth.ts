/**
 * The one-time value that binds an OAuth callback to the browser that started
 * the flow.
 *
 * Without it, a link somebody sends you completes THEIR sign-in in YOUR
 * browser, and you end up holding a token you did not ask for. It is checked
 * here rather than by the node because what it proves is about this tab: the
 * server cannot tell a callback it expected from one it did not.
 *
 * sessionStorage, so it does not outlive the tab — which is the whole lifetime
 * a sign-in has.
 */
export const STATE_KEY = "blazie:oauth-state"

export function mintState(): string {
  const state = crypto.randomUUID()
  sessionStorage.setItem(STATE_KEY, state)
  return state
}

/** Reads and consumes it, so one value can never be replayed. */
export function takeState(): string | null {
  const state = sessionStorage.getItem(STATE_KEY)
  sessionStorage.removeItem(STATE_KEY)
  return state
}
