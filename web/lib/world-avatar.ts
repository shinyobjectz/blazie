/**
 * A world's face, derived from its name and nothing else.
 *
 * The cluster stores no avatar and there is no seed column to add one to — a
 * world is a name and a sequence of facts. So the name IS the seed, which buys
 * the property that actually matters here: two people looking at `orders` see
 * the same circle, in different browsers, after a reload, without anything
 * having been written down.
 *
 * That only holds if the arithmetic is exact, so the hash and the stream below
 * are integer work end to end (`Math.imul`, `>>> 0`); a float appears only once
 * a number has been drawn, and is rounded to three places before anyone can
 * compare two of them. The usual one-liner — hashing through `Math.sin` — is
 * free to differ in the last bit between engines, and a face that differs in
 * the last bit is a different face.
 *
 * What it cost: nobody can choose a world's face, and renaming a world gives it
 * a new one. Both are fine. A name here is already global and permanent, and an
 * avatar nobody picks is an avatar nobody has to.
 *
 * This is a plain module rather than part of the component so the proof can run
 * without a browser — `node lib/world-avatar.check.mts` asserts that two names
 * differ and that one name is stable. The values it prints are quoted at the
 * bottom of this file.
 */

export type Avatar = {
  /** The base pattern the warp is applied over. */
  shape: "checks" | "stripes" | "edge"
  swirl: number
  swirlIterations: number
  distortion: number
  proportion: number
  softness: number
  shapeScale: number
  rotation: number
  /** Which combination, indexed into `PALETTES`. */
  palette: number
  /** How far that combination's three colours are turned, so not every world leads the same. */
  turn: number
  /** Where the still rendering puts its light, in percent. */
  lightX: number
  lightY: number
  /** Slow, and slightly different per world so a page of them does not pulse in step. */
  speed: number
}

const SHAPES = ["checks", "stripes", "edge"] as const

/** FNV-1a, 32-bit. Small, well-spread on short strings, and all integer. */
function seedOf(world: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < world.length; i += 1) {
    h ^= world.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h >>> 0
}

/**
 * mulberry32. One hash gives one number; a face needs a dozen, and slicing bits
 * off a single 32-bit hash runs out and starts correlating the last few
 * parameters with the first few.
 */
function stream(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const round = (n: number) => Math.round(n * 1000) / 1000

/**
 * The combinations a world's face can be drawn from.
 *
 * Chosen rather than generated. Letting the seed pick three tokens out of the
 * set produced muddy pairings — bone against spark is one cream circle, slate
 * against umber is a grey one — and a face is a picture, so which colours go
 * together is the part a person should have decided. Eight of them, turned
 * three ways, is twenty-four looks, which is more than any console has worlds.
 *
 * Every one carries a dark, and it sits between two bright values rather than
 * leading: leading with it handed the shader's own distribution a dark band to
 * widen, and the worlds that landed there came out as black discs with a rim.
 *
 * Tokens, never values. A colour is allowed to be written down in exactly one
 * place in this tree, and it is `globals.css`.
 */
const PALETTES: { dark: string; marks: [string, string, string] }[] = [
  // The mark itself, unchanged. A world may still simply look like blazie.
  { dark: "--muted", marks: ["--flame", "--ember", "--spark"] },
  { dark: "--face-oxblood", marks: ["--ember", "--flame", "--face-gold"] },
  { dark: "--face-umber", marks: ["--face-rust", "--ember", "--face-bone"] },
  { dark: "--face-oxblood", marks: ["--face-gold", "--spark", "--face-rust"] },
  { dark: "--face-umber", marks: ["--face-slate", "--flame", "--face-gold"] },
  { dark: "--muted", marks: ["--face-bone", "--face-rust", "--ember"] },
  { dark: "--face-umber", marks: ["--flame", "--face-oxblood", "--face-bone"] },
  { dark: "--face-oxblood", marks: ["--face-gold", "--face-slate", "--spark"] },
]

/**
 * The ranges are narrower than the shader allows, deliberately.
 *
 * Measured by rendering a sheet of them: the ends of each range are where the
 * faces stop being different from each other. A `softness` near one blurs the
 * whole circle to a single orange disc, and a `shapeScale` near zero zooms one
 * band of the pattern up until it fills the frame — two worlds that landed
 * there were indistinguishable at 56px, which is the only thing this has to
 * get right. What survives is the middle of the space, where a face still has
 * an edge in it at menu size.
 */
export function avatarOf(world: string): Avatar {
  const next = stream(seedOf(world))

  return {
    shape: SHAPES[Math.floor(next() * SHAPES.length)],
    swirl: round(0.35 + next() * 0.55),
    swirlIterations: 4 + Math.floor(next() * 8),
    distortion: round(0.15 + next() * 0.3),
    proportion: round(0.35 + next() * 0.3),
    softness: round(0.15 + next() * 0.3),
    shapeScale: round(0.5 + next() * 0.45),
    rotation: Math.floor(next() * 360),
    palette: Math.floor(next() * PALETTES.length),
    turn: Math.floor(next() * 3),
    lightX: Math.floor(25 + next() * 50),
    lightY: Math.floor(25 + next() * 50),
    speed: round(0.08 + next() * 0.12),
  }
}

/** The chosen combination, turned: lead, its dark, and the other two. */
export function paletteOf(avatar: Avatar): string[] {
  const { dark, marks } = PALETTES[avatar.palette % PALETTES.length]
  const turned = marks.map((_, i) => marks[(i + avatar.turn) % marks.length])
  return [turned[0], dark, turned[1], turned[2]]
}

/* ── the proof ──────────────────────────────────────────────────────────────
 *
 * `node lib/world-avatar.check.mts`, on 2026-08-13:
 *
 *   main    checks  swirl 0.829  rot  27  palette 1.0  ember  oxblood flame gold
 *   orders  edge    swirl 0.785  rot 114  palette 3.2  rust   oxblood gold  spark
 *   $vitals stripes swirl 0.395  rot 303  palette 6.2  bone   umber   flame oxblood
 *
 * A thousand runs of `avatarOf("main")` produce one distinct result, and the
 * three above differ in shape, swirl, rotation and palette turn — which is the
 * whole claim: same name, same face; different name, different face.
 */
