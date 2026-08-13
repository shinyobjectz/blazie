import * as React from "react"

const MOBILE_BREAKPOINT = 768

/**
 * Whether this is a narrow viewport.
 *
 * A media query is something outside React that changes on its own, which is
 * the case `useSyncExternalStore` exists for. It used to be state plus an effect
 * that set it on mount — correct, and two renders every time, with the first
 * one always claiming the viewport was wide.
 */
export function useIsMobile() {
  return React.useSyncExternalStore(subscribe, narrow, prerendered)
}

function subscribe(onChange: () => void) {
  const mql = window.matchMedia(`(max-width: ${MOBILE_BREAKPOINT - 1}px)`)
  mql.addEventListener("change", onChange)
  return () => mql.removeEventListener("change", onChange)
}

function narrow() {
  return window.innerWidth < MOBILE_BREAKPOINT
}

// The prerender has no viewport to measure, and the old state started
// `undefined` and was read as `!!undefined` — so this is the same answer it
// always gave before mount, said out loud.
function prerendered() {
  return false
}
