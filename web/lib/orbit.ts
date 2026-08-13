/**
 * A world as a system: what it holds, what circles it, and where that is drawn.
 *
 * The five kinds below are the whole model. Everything else here — the Lua the
 * console runs, the order the bands sit in, which one claims a declaration that
 * two of them match — is derived from that one list, so a sixth kind is a row
 * rather than a change. That is not speculative tidiness: embeddings and
 * symbols were the fifth and were added exactly that way, and the band before
 * them was written before either existed.
 *
 * Nothing here draws anything. It is a plain module so the layout can be proved
 * without a browser — `node lib/orbit.check.mts` asserts that no two worlds can
 * overlap and that the bands stay in order.
 */

export type Kind = "symbol" | "formula" | "embedding" | "agent" | "job"

export type Band = {
  kind: Kind
  /** Plural, because a band is always a count of something. */
  label: string
  /**
   * One mark per declaration, or a haze whose density is a count.
   *
   * A symbol has no identity worth clicking — there are as many of them as
   * there is data, and one vector is not a thing anybody wants to select. So
   * that band is drawn as a field rather than as objects, which is also the
   * honest picture: it is the world's own data seen another way.
   */
  draw: "bodies" | "belt"
  /** What `each` is asked for, verbatim. */
  spec: string
  /** Which of the found entity's fields travel back, for the panel to show. */
  carries: string[]
  /** Why it sits where it sits. Shown in the legend, so the picture explains itself. */
  reach: string
  /** The mark, tokens only. Colour and shape together — both carry the kind. */
  mark: string
  /** The same colour as text, for the legend and the panel. */
  ink: string
}

/**
 * Innermost first, ordered by how far the thing reaches out of the world.
 *
 * A symbol never leaves — it is the data restated. A formula reads the world
 * and writes to it and has no clock and no network by construction. An
 * embedding leaves, but only to say again what is already here. An agent leaves
 * to decide something new. A job leaves for whatever it likes, on a clock.
 *
 * The order does a second job, which is why it is worth stating that this is
 * not a coincidence: a body is claimed by the first band that matches it, and
 * the inner test is always the narrower one. An embedding declares `asks` the
 * same way an agent does — it IS a kind of asking — so it must be recognised
 * before the agents band gets to it or it is counted twice. Measured against a
 * seeded world: with the bands the other way round, one embedding produced one
 * agent and one embedding.
 */
export const BANDS: Band[] = [
  {
    kind: "symbol",
    label: "symbols",
    draw: "belt",
    spec: "{ answers = 'symbol' }",
    carries: ["space", "embeds"],
    reach: "the world's data, restated as vectors. it never leaves.",
    mark: "bg-muted-foreground rounded-full",
    ink: "text-muted-foreground",
  },
  {
    kind: "formula",
    label: "formulas",
    draw: "bodies",
    spec: "{ is = 'formula' }",
    carries: ["produces", "source"],
    reach: "a derivation. no clock and no network, so it can be thrown away and rebuilt.",
    mark: "bg-spark rotate-45",
    ink: "text-spark",
  },
  {
    kind: "embedding",
    label: "embeddings",
    draw: "bodies",
    spec: "{ embeds = true }",
    carries: ["embeds", "into", "asks"],
    reach: "asks a model to say what is already here, in a space you can compare in.",
    mark: "border border-white rounded-full",
    ink: "text-white",
  },
  {
    kind: "agent",
    label: "agents",
    draw: "bodies",
    spec: "{ asks = true }",
    carries: ["asks", "watches", "produces", "ran_at", "tries", "failed"],
    reach: "asks a model to decide something the world does not already say.",
    mark: "bg-flame rounded-full",
    ink: "text-flame",
  },
  {
    kind: "job",
    label: "jobs",
    draw: "bodies",
    spec: "{ is = 'job' }",
    carries: ["every", "ran_at", "failed"],
    reach: "reaches outside on a cadence. the only thing a schedule can attach to.",
    mark: "bg-ember rounded-sm",
    ink: "text-ember",
  },
]

export const bandOf = (kind: Kind): Band =>
  BANDS.find((band) => band.kind === kind) ?? BANDS[BANDS.length - 1]

/* ── what the console asks each world ──────────────────────────────────────── */

/**
 * How many of one kind are described rather than merely counted.
 *
 * The count above the cap is still exact — it is incremented before this is
 * consulted. What stops is the describing, because a world with ten thousand
 * agents should not send ten thousand rows so that a dozen dots can be drawn.
 */
const DESCRIBED = 64

const carrying = (band: Band) =>
  band.carries.map((field) => `${field} = e.${field}`).join(", ")

/**
 * The chunk, built from the bands so the two cannot disagree.
 *
 * A hand-written chunk beside a hand-written band list is two lists that have
 * to be kept in step by remembering to, which is the failure this repo has a
 * standing rule about. Generated, adding a kind cannot leave the census
 * behind — and the source is still real Lua a person can paste into the
 * editor, which is why the page shows it.
 *
 * Nothing here reads a field off an entity, and that is the whole of why it
 * survives worlds the other pages do not. A guest gets five million words
 * before it is stopped, and touching each entity is what spends them —
 * measured against a seeded node, `pairs(e)` per entity refused somewhere
 * between six and eight thousand, `e.is` per entity refused at eight thousand,
 * and the two counts below answered the same question at eight thousand
 * without effort. Asking twice and subtracting is cheaper than looking once,
 * because the second ask is one indexed query and the look is a table per
 * entity.
 *
 * That is also why there is no field count. It is the same `pairs(e)` walk, and
 * the front page draws every world you hold, so it is the page that can least
 * afford to be the first to refuse — the data page already answers "how many
 * fields" for the one world you are looking at.
 *
 * The ceiling is not gone, only pushed: `each {}` builds the whole id list
 * before a loop body runs, so past roughly ten thousand entities a world
 * refuses however little the chunk then does with them. A world in that state
 * keeps its planet and shows the refusal, which carries the repair.
 */
export const ORBIT = [
  `-- what ${new Intl.ListFormat("en").format(BANDS.map((b) => b.label))} this world holds.`,
  `-- the mass of a world is everything that does not say what it is: an`,
  `-- attribute, a job and a formula all declare themselves, and data does not.`,
  `local entities, declared = 0, 0`,
  `for _ in each {} do entities = entities + 1 end`,
  `for _ in each { is = true } do declared = declared + 1 end`,
  `local data = entities - declared`,
  ``,
  `local orbit, belts, seen = {}, {}, {}`,
  `local counts = { ${BANDS.map((b) => `${b.kind} = 0`).join(", ")} }`,
  ``,
  `-- first band to recognise a declaration keeps it, so nothing is counted twice.`,
  `local function claim(kind, e, of)`,
  `  if seen[e.id] then return end`,
  `  seen[e.id] = true`,
  `  counts[kind] = counts[kind] + 1`,
  `  if counts[kind] > ${DESCRIBED} then return end`,
  `  of.kind, of.id = kind, e.id`,
  `  orbit[#orbit + 1] = of`,
  `end`,
  ...BANDS.map((band) =>
    band.draw === "belt"
      ? [
          ``,
          `for e in each ${band.spec} do`,
          `  local n = 0`,
          `  for _ in each { [e.id] = true } do n = n + 1 end`,
          `  counts.${band.kind} = counts.${band.kind} + n`,
          `  belts[#belts + 1] = { field = e.id, ${carrying(band)}, held = n }`,
          `end`,
        ].join("\n")
      : [
          ``,
          `for e in each ${band.spec} do`,
          `  claim('${band.kind}', e, { ${carrying(band)} })`,
          `end`,
        ].join("\n"),
  ),
  ``,
  `return { entities = entities, data = data,`,
  `         counts = counts, belts = belts, orbit = orbit }`,
].join("\n")

export type Body = {
  kind: Kind
  id: string
  /** Whatever its band asked to carry. Absent means the world does not say. */
  [field: string]: unknown
}

export type Belt = {
  field: string
  space?: string
  embeds?: string
  held: number
}

export type Census = {
  /** Everything in the world, declarations included. */
  entities: number
  /** Everything that does not declare what it is. The planet's mass. */
  data: number
  counts: Record<Kind, number>
  belts: Belt[]
  orbit: Body[]
}

/** Zero for a kind a world has none of, and for a world that answered oddly. */
export function countOf(census: Census | null, kind: Kind): number {
  const held = census?.counts?.[kind]
  return typeof held === "number" ? held : 0
}

/* ── where all of that is drawn ────────────────────────────────────────────── */

/**
 * How big the planet is, in four steps.
 *
 * Four rather than a continuous scale because the avatar renders at fixed
 * sizes, and that constraint turned out to be the better picture anyway: a
 * continuous area invites reading a ratio off the screen, and the ratio would
 * be a lie the moment one world has three rows and another has three million.
 * A step says "this order of magnitude" and the exact count sits beside it in
 * the panel, which is the only place a number should be read from.
 */
const PLANETS = [
  { from: 10_000, size: "2xl", span: 112 },
  { from: 100, size: "xl", span: 80 },
  { from: 1, size: "lg", span: 56 },
  { from: 0, size: "md", span: 28 },
] as const

export type Planet = { size: "md" | "lg" | "xl" | "2xl"; span: number }

export function planetOf(data: number): Planet {
  const step = PLANETS.find((one) => data >= one.from) ?? PLANETS[PLANETS.length - 1]
  return { size: step.size, span: step.span }
}

/** Clear of the surface, so a heavy world's first band is not inside it. */
const SURFACE = 16
const GAP = 16

/** Measured from the planet's edge, which is where an orbit actually starts. */
export function radiusOf(planet: Planet, index: number): number {
  return planet.span / 2 + SURFACE + index * GAP
}

/** The widest a system can be, which is what the spacing below has to clear. */
export const REACH = radiusOf(planetOf(Infinity), BANDS.length - 1)

/**
 * How far apart two worlds are placed.
 *
 * Every system is given the same room whatever it weighs. Spacing by size
 * would put the small worlds shoulder to shoulder and the large ones a screen
 * apart, and then the gaps in the picture would mean something they do not.
 */
export const PITCH = 2 * REACH + 48

/** The box one system is drawn in, centred on its planet. */
export const CELL = PITCH

/**
 * Where a world sits: rings of six, twelve, eighteen, outward from the middle.
 *
 * Deliberately NOT seeded, unlike everything else about a world here. A seeded
 * position collides — two names landing on one spot is not rare, it is the
 * birthday problem — and two planets drawn on top of each other is a worse
 * failure than a predictable arrangement. So position comes from the order, and
 * the seed governs what a system looks like rather than where it is: the phase
 * of every band, and the face at the centre.
 */
export function placeOf(index: number): { x: number; y: number } {
  if (index <= 0) return { x: 0, y: 0 }

  let ring = 1
  let first = 1
  while (first + 6 * ring <= index) {
    first += 6 * ring
    ring += 1
  }

  const slots = 6 * ring
  // A quarter-slot turn per ring, so consecutive rings do not line their worlds
  // up into spokes. Spokes read as a diagram; this is meant to read as a sky.
  const angle = ((index - first + ring * 0.25) / slots) * Math.PI * 2

  return {
    x: Math.round(Math.cos(angle) * ring * PITCH),
    y: Math.round(Math.sin(angle) * ring * PITCH),
  }
}

/**
 * Outer bands turn slower, which is both what orbits do and what keeps a system
 * legible — five rings at one speed reads as a single spinning disc.
 */
export function periodOf(index: number): number {
  return 60 + index * 40
}

/**
 * Past this many marks a band is pixels rather than a count.
 *
 * The number is written beside the picture and is the honest answer, so the
 * ring is the glance and never the measurement.
 */
export const CIRCLING = 12
const SCATTERED = 44

/**
 * Where the marks of one band go, as degrees and a drift off the ring.
 *
 * The golden angle, so a band of five and a band of forty are both evenly
 * spread without either being told how many there are. A belt gets a drift as
 * well, because a field of dots sitting exactly on a circle is a ring — and the
 * drift is a small lattice rather than randomness, which needs no seed and
 * cannot clump.
 */
export function marksOf(
  count: number,
  phase: number,
  draw: Band["draw"],
): { angle: number; drift: number }[] {
  const shown = Math.min(count, draw === "belt" ? SCATTERED : CIRCLING)

  return Array.from({ length: Math.max(0, shown) }, (_, i) => ({
    angle: draw === "belt" ? phase + i * 137.507 : phase + (i * 360) / shown,
    drift: draw === "belt" ? ((i * 5) % 7) - 3 : 0,
  }))
}
