"use client"

import { cn } from "@/lib/utils"
import {
  BANDS,
  type Body,
  CELL,
  type Census,
  countOf,
  marksOf,
  periodOf,
  planetOf,
  radiusOf,
} from "@/lib/orbit"
import { avatarOf } from "@/lib/world-avatar"

import { WorldAvatar } from "./world-avatar"

/**
 * One world, drawn as what it is: a planet, and everything that circles it.
 *
 * Every ring here is a measurement. A band with nothing in it is not drawn at
 * all, which is the whole reason this is a picture rather than a table — a
 * world that is only data is a bare planet, and a world carrying five agents
 * and a symbol field has a visible structure, before anybody reads a number.
 * The numbers are still the answer; they are in the panel.
 *
 * The seed decides where each band starts, so two worlds with one job each do
 * not have that job in the same place, and a world's system is as stable across
 * browsers and reloads as its face is.
 */

export function WorldSystem({
  world,
  census,
  refused,
  chosen,
  held,
  selected,
  onChoose,
  onInspect,
}: {
  world: string
  census: Census | null
  refused: boolean
  chosen: boolean
  /** Off screen. The rings hold rather than turn — a console is left open all day. */
  held: boolean
  /** Which body is open in the panel, so the mark can say so. */
  selected: string | null
  onChoose: () => void
  onInspect: (body: Body) => void
}) {
  // A world that refused has no known mass, and the smallest step would say it
  // is empty — which is the one thing we know it is not, since counting it is
  // what ran out of room. So it is drawn at neither extreme and the broken ring
  // is what says the number is missing.
  const planet = planetOf(refused ? 1 : (census?.data ?? 0))
  const phase = avatarOf(world).rotation

  // Grouped once. A band asks for its own kind rather than the census being
  // reshaped per band, so a kind nothing matched is simply an empty list.
  const circling = (kind: string) =>
    census?.orbit?.filter((body) => body.kind === kind) ?? []

  return (
    <div
      className="absolute"
      style={{
        width: CELL,
        height: CELL,
        // The cell is centred on its planet, so `placeOf` can say where a world
        // is without also having to know how wide its system came out.
        marginLeft: -CELL / 2,
        marginTop: -CELL / 2,
      }}
    >
      {BANDS.map((band, index) => {
        const count = countOf(census, band.kind)
        if (count === 0) return null

        const radius = radiusOf(planet, index)
        const marks = marksOf(count, phase + index * 47, band.draw)
        const bodies = circling(band.kind)

        return (
          <Ring
            key={band.kind}
            radius={radius}
            held={held}
            period={periodOf(index)}
            // A belt is a field of vectors, not a set of orbits. Drawing the
            // circle it happens to average out to would claim a structure the
            // data does not have.
            drawn={band.draw === "bodies"}
          >
            {marks.map((mark, i) => {
              const body = bodies[i % Math.max(1, bodies.length)]

              return (
                <span
                  className="absolute inset-0 block"
                  key={`${band.kind}-${i}`}
                  style={{ transform: `rotate(${mark.angle}deg)` }}
                >
                  {band.draw === "belt" || !body ? (
                    <span
                      aria-hidden
                      className={cn(
                        "absolute left-1/2 block size-1 -translate-x-1/2 opacity-60",
                        band.mark,
                      )}
                      style={{ top: mark.drift }}
                    />
                  ) : (
                    <button
                      type="button"
                      onClick={(event) => {
                        event.stopPropagation()
                        onInspect(body)
                      }}
                      // The mark is the size it should be read at; the button is
                      // the size it has to be hit at. An eight-pixel target that
                      // is also moving is a target nobody hits.
                      className="group/mark absolute left-1/2 top-0 flex size-4 -translate-x-1/2 -translate-y-1/2 items-center justify-center"
                      title={`${band.kind} · ${body.id}`}
                    >
                      <span
                        className={cn(
                          "block size-2 transition-transform group-hover/mark:scale-150",
                          band.mark,
                          selected === body.id && "scale-150 ring-1 ring-white",
                        )}
                      />
                    </button>
                  )}
                </span>
              )
            })}
          </Ring>
        )
      })}

      {/* A world that refused is still a world. It gets its planet and a broken
          ring instead of vanishing from the sky, because a world you cannot see
          is one you cannot click to find out why. */}
      {refused ? (
        <Ring radius={radiusOf(planet, 0)} held drawn={false} period={0}>
          <span className="absolute inset-0 rounded-full border border-dashed border-flame/50" />
        </Ring>
      ) : null}

      <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2">
        <button
          type="button"
          onClick={onChoose}
          className={cn(
            "block rounded-full ring-offset-2 ring-offset-background transition-all hover:ring-1 hover:ring-white/40",
            chosen && "ring-1 ring-flame hover:ring-flame",
          )}
          title={world}
        >
          <WorldAvatar
            world={world}
            size={planet.size}
            // The one shader in the sky. Every planet asking for one would be a
            // page of WebGL contexts, and the budget in `WorldAvatar` would hand
            // most of them the still rendering anyway — silently, and at the
            // cost of having tried.
            live={chosen}
          />
        </button>
      </div>

      <span
        aria-hidden
        className={cn(
          "font-mono absolute left-1/2 -translate-x-1/2 whitespace-nowrap text-xs",
          chosen ? "text-white" : "text-muted-foreground",
        )}
        style={{ top: CELL / 2 + radiusOf(planet, BANDS.length - 1) + 10 }}
      >
        {world}
      </span>
    </div>
  )
}

/**
 * One band, turning.
 *
 * `orbiting` and `orbit-held` are the utilities `globals.css` already defines
 * for this, and they are longhand rather than the `animation` shorthand so that
 * holding one only touches the play state. The duration is set here because it
 * is the one part that differs per band — inline wins over the utility, and
 * `prefers-reduced-motion` still wins over both, since that rule takes the
 * animation's NAME away and no duration can put it back.
 */
function Ring({
  radius,
  period,
  held,
  drawn,
  children,
}: {
  radius: number
  period: number
  held: boolean
  drawn: boolean
  children: React.ReactNode
}) {
  return (
    <span
      className="absolute left-1/2 top-1/2 block"
      style={{
        width: radius * 2,
        height: radius * 2,
        marginLeft: -radius,
        marginTop: -radius,
      }}
    >
      {drawn ? (
        <span className="absolute inset-0 block rounded-full border border-border" />
      ) : null}

      <span
        className={cn("absolute inset-0 block", period > 0 && "orbiting", held && "orbit-held")}
        style={period > 0 ? { animationDuration: `${period}s` } : undefined}
      >
        {children}
      </span>
    </span>
  )
}
