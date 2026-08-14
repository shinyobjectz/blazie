/**
 * Route comparison, which is why onboarding could not load.
 *
 * `trailingSlash: true` makes `usePathname()` answer `/dashboard/clusters/`
 * while the route literals are written bare, so `===` between them was always
 * false. The onboarding guard asked "am I already there" that way, decided no
 * on the page it had just arrived at, and redirected to it again. Every account
 * holding no clusters — which is every new one — saw only that.
 *
 * Nothing in the suite could have caught it, because the layout is a component
 * and the comparison was inline. So the comparison is a function now and this
 * runs in `pnpm test`, which is what `just check` calls. The sibling
 * `lib/*.check.mts` files are run by hand and would not have been.
 */

import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { at, under } from "../lib/path.ts"

describe("at", () => {
  it("matches whatever either side says about the trailing slash", () => {
    // The one that mattered: what Next reports against what the app writes.
    assert.equal(at("/dashboard/clusters/", "/dashboard/clusters"), true)
    assert.equal(at("/dashboard/clusters", "/dashboard/clusters"), true)
    assert.equal(at("/dashboard/clusters/", "/dashboard/clusters/"), true)
  })

  it("is still a different route when it is a different route", () => {
    assert.equal(at("/dashboard/", "/dashboard/clusters"), false)
    assert.equal(at("/dashboard/data/", "/dashboard/clusters"), false)
  })

  it("holds for the orbit, which never lit up in the nav", () => {
    assert.equal(at("/dashboard/", "/dashboard"), true)
    assert.equal(at("/dashboard/data/", "/dashboard"), false)
  })
})

describe("under", () => {
  it("takes a route and anything below it", () => {
    assert.equal(under("/dashboard/data/", "/dashboard/data"), true)
    assert.equal(under("/dashboard/data/rows/", "/dashboard/data"), true)
  })

  it("stops at the separator rather than the bare prefix", () => {
    // No two routes collide this way today. This is the assertion that says so
    // out loud, so adding `/dashboard/data` beside `/dashboard/database` fails
    // here rather than lighting two nav items at once.
    assert.equal(under("/dashboard/database/", "/dashboard/data"), false)
  })

  it("does not make every route the orbit", () => {
    assert.equal(under("/dashboard/data/", "/dashboard"), true)
    assert.equal(under("/dashboard/", "/dashboard/data"), false)
  })
})
