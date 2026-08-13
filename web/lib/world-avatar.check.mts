/**
 * The proof that a world's face is derived rather than assigned.
 *
 * `node lib/world-avatar.check.mts` — no runner and no dependency, because
 * adding a test framework to a console with no tests to run in it is a bigger
 * decision than this file is worth. Node strips the types itself.
 *
 * It is a `.mts` so Node loads it as a module without `"type": "module"` in the
 * package, which would change how every other file in here is read. Node
 * resolves what is written rather than what a bundler would have guessed, so
 * the import below carries its extension — which is why `tsconfig.json` sets
 * `allowImportingTsExtensions`. That flag only permits; nothing else has to
 * start writing extensions, and it is a no-op for a project that emits nothing.
 */

import assert from "node:assert/strict"

import { type Avatar, avatarOf, paletteOf } from "./world-avatar.ts"

const shown = (a: Avatar) =>
  `${a.shape.padEnd(7)} swirl ${a.swirl.toFixed(3)}  rot ${String(a.rotation).padStart(3)}  palette ${a.palette}.${a.turn}  ${paletteOf(a).join(" ")}`

for (const world of ["main", "orders", "$vitals"]) {
  console.log(`  ${world.padEnd(7)} ${shown(avatarOf(world))}`)
}

// Stable: the same name is the same face, however many times it is asked.
const first = JSON.stringify(avatarOf("main"))
for (let i = 0; i < 1000; i += 1) {
  assert.equal(JSON.stringify(avatarOf("main")), first, "main drifted")
}

// Distinct: names that differ do not land on the same face. A hundred is enough
// to catch a derivation that quietly ignores its seed, which is the failure
// this is really watching for.
const faces = new Set<string>()
for (let i = 0; i < 100; i += 1) faces.add(JSON.stringify(avatarOf(`world-${i}`)))
assert.equal(faces.size, 100, "two different names produced the same face")

// A neighbouring name is not a neighbouring face — one character apart must not
// look like the same world at a glance.
const main = avatarOf("main")
const mail = avatarOf("mail")
assert.notEqual(main.rotation, mail.rotation)
assert.notEqual(main.swirl, mail.swirl)

// The palette is named, never resolved. A hex here would be a colour that no
// longer moves when the token does.
for (let i = 0; i < 200; i += 1) {
  for (const token of paletteOf(avatarOf(`world-${i}`))) {
    assert.match(token, /^--[a-z-]+$/)
  }
}

console.log("\n  ok — stable per name, distinct across names, tokens only")
