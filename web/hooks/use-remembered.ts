"use client"

import * as React from "react"

/**
 * A value this browser remembered, read without an effect.
 *
 * Every page here is prerendered by the static export, so nothing in
 * `localStorage` exists at render time — which is why this kept being written as
 * "render the default, then correct it in an effect". That works, and it is
 * exactly the cascading render the compiler's lint objects to: two renders for
 * one value, on every page that remembers anything.
 *
 * `useSyncExternalStore` says the same thing in the shape React can see. The
 * third argument is the server's answer, so the prerender still contains the
 * default and still matches the first client render — the difference is that
 * React does the correcting instead of a second pass through an effect.
 */
export function useRemembered(key: string): string | null {
  const read = React.useCallback(() => window.localStorage.getItem(key), [key])

  return React.useSyncExternalStore(subscribe, read, prerendered)
}

// Nothing in this tab changes it under us — but another tab does, and `storage`
// is exactly that event. Subscribing costs nothing and means two consoles open
// side by side agree rather than diverging until one is reloaded.
function subscribe(onChange: () => void) {
  window.addEventListener("storage", onChange)
  return () => window.removeEventListener("storage", onChange)
}

// There is no browser yet, so there is nothing remembered yet.
function prerendered() {
  return null
}
