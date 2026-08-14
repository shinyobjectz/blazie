/**
 * Comparing a route to the pathname the app actually reports.
 *
 * `next.config.ts` sets `trailingSlash: true`, so `usePathname()` answers
 * `/dashboard/clusters/` while every route literal in the app is written
 * without the slash. `===` between the two is therefore always false, and that
 * is not a cosmetic difference: the onboarding guard used it to ask "am I there
 * yet", so an account holding no clusters redirected to the page it was already
 * on, and kept redirecting. The first screen a new account sees was the one
 * screen that could not load.
 *
 * Normalising in one place rather than writing the slash into every literal,
 * because the config is what decides and it can be changed back.
 */

/** A path with any trailing slashes taken off. `/` becomes the empty string. */
function bare(path: string): string {
  return path.replace(/\/+$/, "")
}

/** Is this pathname exactly that route, whatever either says about slashes? */
export function at(pathname: string, route: string): boolean {
  return bare(pathname) === bare(route)
}

/**
 * Is this pathname that route, or something below it?
 *
 * The boundary is the separator rather than the bare prefix, so `/dashboard/data`
 * does not claim `/dashboard/database`. No two routes collide that way today;
 * this costs nothing and stops the next one being a bug nobody looks for.
 */
export function under(pathname: string, route: string): boolean {
  const here = bare(pathname)
  const there = bare(route)

  return here === there || here.startsWith(`${there}/`)
}
