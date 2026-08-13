/**
 * The proof that no two worlds can be drawn on top of each other.
 *
 * `node lib/orbit.check.mts` — same arrangement as `world-avatar.check.mts`,
 * and for the same reason: a console with no test runner in it should not gain
 * one so that two functions of arithmetic can be checked.
 *
 * Overlap is the failure worth proving away rather than eyeballing. It appears
 * only once somebody has enough worlds to reach the second ring, which is after
 * the picture has been looked at and approved a hundred times.
 *
 * Printing the chunk is the other half. It is generated from the band list, so
 * this is where a person can read what the console will actually send.
 */

import assert from "node:assert/strict"

import { BANDS, CELL, ORBIT, PITCH, REACH, marksOf, placeOf, planetOf, radiusOf } from "./orbit.ts"

// No two worlds within a system's width of each other, out to four rings — 61
// worlds, which is more than any console has.
const places = Array.from({ length: 61 }, (_, i) => placeOf(i))

let closest = Infinity
for (let a = 0; a < places.length; a += 1) {
  for (let b = a + 1; b < places.length; b += 1) {
    const apart = Math.hypot(places[a].x - places[b].x, places[a].y - places[b].y)
    closest = Math.min(closest, apart)
  }
}

// A system is `REACH` from its centre in every direction, so two of them clear
// each other exactly when their centres are more than twice that apart.
assert.ok(
  closest > 2 * REACH,
  `two worlds ${closest.toFixed(1)}px apart, and a system is ${2 * REACH}px wide`,
)

// Stable: where a world sits is a function of its index and nothing else.
assert.deepEqual(placeOf(7), placeOf(7))
assert.deepEqual(placeOf(0), { x: 0, y: 0 })

// The bands stay in order and never touch, at every planet size.
for (const data of [0, 1, 99, 100, 9_999, 10_000, 4_000_000]) {
  const planet = planetOf(data)
  assert.ok(radiusOf(planet, 0) > planet.span / 2, "the first band is inside the planet")

  for (let i = 1; i < BANDS.length; i += 1) {
    assert.ok(radiusOf(planet, i) > radiusOf(planet, i - 1), "bands out of order")
  }

  assert.ok(radiusOf(planet, BANDS.length - 1) <= REACH, "a system reaches past its cell")
}

// A band is claimed by the first kind that matches, and `asks` matches both an
// embedding and an agent — so the narrower one has to be asked first or one
// declaration is counted as two.
const embedding = BANDS.findIndex((band) => band.kind === "embedding")
const agent = BANDS.findIndex((band) => band.kind === "agent")
assert.ok(embedding < agent, "agents would swallow every embedding")

// Every band reaches the chunk. A kind that is drawn but never asked for is a
// band that is always empty, which looks exactly like a world having none.
for (const band of BANDS) {
  assert.ok(ORBIT.includes(band.spec), `${band.kind} is drawn but never asked for`)
}

// Colours are classes over tokens, never values. A hex here would be a colour
// that no longer moves when the palette does.
for (const band of BANDS) {
  assert.doesNotMatch(band.mark + band.ink, /#|rgb|hsl/)
}

// A band of one is one mark, and a band of a thousand is not a thousand marks.
assert.equal(marksOf(1, 0, "bodies").length, 1)
assert.equal(marksOf(0, 0, "bodies").length, 0)
assert.ok(marksOf(1_000, 0, "bodies").length < 20)
assert.ok(marksOf(1_000, 0, "belt").length < 64)

console.log(ORBIT)
console.log(
  `\n  ok — ${BANDS.length} bands, a system ${2 * REACH}px wide in a ${CELL}px cell,` +
    ` nearest two worlds ${closest.toFixed(0)}px apart (pitch ${PITCH})`,
)
