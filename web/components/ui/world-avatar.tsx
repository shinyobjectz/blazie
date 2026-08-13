"use client"

import { Warp } from "@paper-design/shaders-react"
import { useInView, useReducedMotion } from "motion/react"
import { useEffect, useMemo, useRef, useState } from "react"

import { cn } from "@/lib/utils"
import { type Avatar, avatarOf, paletteOf } from "@/lib/world-avatar"

/**
 * The circle that stands for a world, everywhere one is named.
 *
 * Two renderings of the same numbers. The still one is a pair of CSS gradients
 * and costs nothing; the live one is the warp shader. They agree on colour,
 * turn and light, so a menu row and a card read as the same world without the
 * menu row having to own a GPU context.
 *
 * Which you get is not entirely up to the caller — see `LIVE` below.
 */

/** On the scale, so a menu row and a card cannot drift a pixel apart. */
const SIZES = {
  sm: "size-5",
  md: "size-7",
  lg: "size-14",
} as const

/**
 * How many avatars may run a shader at once, per tab.
 *
 * Each live one is its own WebGL context and a browser has a hard ceiling on
 * those — Chrome starts dropping the oldest at sixteen, and a dropped context
 * does not throw. It leaves a blank circle and no way to find out why. A
 * console listing thirty worlds would hit that on the worlds page and then
 * carry the damage to every other page in the tab.
 *
 * Six is under every limit with room to spare for a page that also wants a
 * background shader. Beyond it an avatar quietly takes the still rendering,
 * which is derived from the same seed and is the same world's colours — the
 * page degrades in fidelity rather than in correctness.
 */
const LIVE = 6
let lit = 0

/**
 * The tokens, as the browser actually painted them.
 *
 * WebGL wants numbers, so this is the one place a colour leaves the stylesheet
 * — and it leaves by being read off the document rather than written down a
 * second time in TypeScript. Change `--flame` and every avatar changes with it.
 */
function resolve(tokens: string[]): string[] {
  const painted = getComputedStyle(document.documentElement)
  return tokens.map((token) => painted.getPropertyValue(token).trim())
}

/**
 * Claim one of the live slots, and the resolved colours with it.
 *
 * Nothing here can run before mount anyway: the static export prerenders these
 * pages, and neither `getComputedStyle` nor a GL context exists then. So the
 * still rendering is not a fallback bolted on — it is what the HTML contains,
 * and the shader is what arrives afterwards if there is room for it.
 */
function useLit(tokens: string[] | null): string[] | null {
  const [colors, setColors] = useState<string[] | null>(null)
  const wanted = tokens?.join(" ") ?? ""

  useEffect(() => {
    if (!wanted || lit >= LIVE) return

    lit += 1
    setColors(resolve(wanted.split(" ")))

    return () => {
      lit -= 1
      setColors(null)
    }
  }, [wanted])

  return colors
}

/**
 * The still rendering: a conic sweep with the light placed by the seed.
 *
 * `var(--…)` rather than resolved values, so this one never needs telling that
 * the palette moved.
 */
function stillOf(avatar: Avatar): string {
  const [lead, dark, next, last] = paletteOf(avatar).map((token) => `var(${token})`)
  return [
    `radial-gradient(circle at ${avatar.lightX}% ${avatar.lightY}%, ${last}, transparent 60%)`,
    `conic-gradient(from ${avatar.rotation}deg, ${lead}, ${dark}, ${next}, ${last}, ${lead})`,
  ].join(", ")
}

export function WorldAvatar({
  world,
  size = "md",
  live = false,
  className,
}: {
  world: string
  size?: keyof typeof SIZES
  /** Ask for the shader. Granted while there is a context to spare. */
  live?: boolean
  className?: string
}) {
  const avatar = useMemo(() => avatarOf(world), [world])
  const colors = useLit(live ? paletteOf(avatar) : null)
  const reduceMotion = useReducedMotion() ?? false

  return (
    <span
      aria-hidden
      className={cn(
        "relative block shrink-0 overflow-hidden rounded-full border border-border",
        SIZES[size],
        className,
      )}
      style={{ background: stillOf(avatar) }}
    >
      {colors ? (
        <Warp
          colors={colors}
          distortion={avatar.distortion}
          // A different starting point per world, which is what keeps the
          // reduced-motion rendering from showing every world the same frame.
          frame={avatar.rotation * 137}
          height="100%"
          proportion={avatar.proportion}
          rotation={avatar.rotation}
          shape={avatar.shape}
          shapeScale={avatar.shapeScale}
          softness={avatar.softness}
          // Zero stops the render loop outright rather than animating at nothing
          // a second — the shader mount drops its rAF entirely at this value,
          // and it already pauses itself when the tab is hidden or the element
          // scrolls out of the viewport.
          speed={reduceMotion ? 0 : avatar.speed}
          swirl={avatar.swirl}
          swirlIterations={avatar.swirlIterations}
          width="100%"
        />
      ) : null}
    </span>
  )
}

/**
 * What circles a world: one dot per agent and per job, on a slow ring.
 *
 * The counts are already written beside this in words, so the ring is not the
 * measurement — it is the glance. Which is why it caps: past a dozen dots you
 * are counting pixels, and the number in the caption is the honest answer
 * anyway. Agents come first so a world's shape at a glance is "mostly agents"
 * or "mostly jobs" rather than a shuffle.
 */
const CIRCLING = 12

export function WorldOrbit({
  world,
  agents,
  jobs,
  live = false,
}: {
  world: string
  agents: number
  jobs: number
  live?: boolean
}) {
  const ring = useRef<HTMLSpanElement>(null)
  const onScreen = useInView(ring)

  const dots = useMemo(() => {
    const held = Math.min(agents, CIRCLING)
    const rest = Math.min(jobs, CIRCLING - held)
    return [
      ...Array.from({ length: held }, () => "agent" as const),
      ...Array.from({ length: rest }, () => "job" as const),
    ]
  }, [agents, jobs])

  // The seed decides where the ring starts, so two worlds with one job each do
  // not have that job in the same place.
  const phase = avatarOf(world).rotation

  return (
    <span ref={ring} className="relative block size-24">
      <span className="absolute inset-1 rounded-full border border-border" />

      <span
        className={cn(
          "absolute inset-1 block",
          dots.length > 0 && "orbiting",
          !onScreen && "orbit-held",
        )}
      >
        {dots.map((kind, i) => (
          <span
            className="absolute inset-0 block"
            key={`${kind}-${i}`}
            style={{ transform: `rotate(${phase + (i * 360) / dots.length}deg)` }}
          >
            <span
              className={cn(
                "absolute left-1/2 top-0 block size-1.5 -translate-x-1/2 rounded-full",
                kind === "agent" ? "bg-flame" : "bg-ember",
              )}
            />
          </span>
        ))}
      </span>

      <span className="absolute inset-0 flex items-center justify-center">
        <WorldAvatar world={world} size="lg" live={live} />
      </span>
    </span>
  )
}
