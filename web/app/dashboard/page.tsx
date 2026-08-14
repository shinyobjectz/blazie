"use client"

import { Crosshair, Minus, Orbit as OrbitIcon, Plus, X } from "lucide-react"
import Link from "next/link"
import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { useInView } from "motion/react"

import { Nothing } from "@/components/dashboard/page-shell"
import { RefusalNote } from "@/components/ui/refusal-note"
import { WorldSystem } from "@/components/ui/world-system"
import { showCount, showWhen } from "@/lib/format"
import {
  BANDS,
  type Band,
  type Body,
  type Census,
  ORBIT,
  bandOf,
  countOf,
  placeOf,
} from "@/lib/orbit"
import { cn } from "@/lib/utils"

import { useCluster } from "./cluster"

/**
 * Every world you hold, as a sky you can move around in.
 *
 * A console usually answers "what is in this world" one world at a time, and
 * the shape of the whole account is something you assemble in your head from
 * six pages. Here it is one picture: a planet's size is how much data is in it,
 * and each ring is a kind of thing that acts on it. A world heavy with agents
 * does not look like a world that is mostly data, and neither of them looks
 * like a world that is only a name somebody claimed.
 *
 * Every number on this page came back from a run against the world it is drawn
 * on. There is no summary table to read instead — a count kept beside the facts
 * is a second account of them that can be wrong — so this page is `worlds`
 * chunks of Lua, one per world, each independent. One world refusing must not
 * blank the sky.
 *
 * Those runs use `run` rather than the cluster's `ask`, so the snapshot name in
 * the header stays empty here. That is deliberate: `ask` records where the last
 * run read, and a page that read five worlds at five transactions has no single
 * answer to give. Pick a world and any other page will say.
 */

type Answer = { census: Census | null; error: unknown }

/** What the panel is open on: a world, or one thing circling it. */
type Looking = { world: string; body: Body | null }

const ZOOM = { least: 0.35, most: 1.6, step: 0.2 }

export default function Orbit() {
  const { worlds, run, world: chosen, choose } = useCluster()

  const viewport = useRef<HTMLDivElement>(null)
  const onScreen = useInView(viewport)

  const [answers, setAnswers] = useState<Record<string, Answer>>({})
  const [looking, setLooking] = useState<Looking | null>(null)
  const [zoom, setZoom] = useState(0.8)
  const [pan, setPan] = useState({ x: 0, y: 0 })

  /**
   * Yours first, then the node's, then by name.
   *
   * Position comes from this order, so the order has to be a property of the
   * names rather than of whatever `/me` happened to return — a sky that
   * rearranges itself between reloads is a sky nobody learns. The node's own
   * worlds go to the outside because the middle of your console should be
   * yours.
   */
  const ordered = useMemo(
    () =>
      [...worlds].sort(
        (a, b) =>
          Number(a.startsWith("$")) - Number(b.startsWith("$")) || a.localeCompare(b),
      ),
    [worlds],
  )

  const ask = useCallback(() => {
    let live = true

    for (const world of ordered) {
      run(world, ORBIT)
        .then((result) => {
          if (live) {
            setAnswers((held) => ({
              ...held,
              [world]: { census: result.value as Census, error: null },
            }))
          }
        })
        .catch((thrown) => {
          if (live) setAnswers((held) => ({ ...held, [world]: { census: null, error: thrown } }))
        })
    }

    return () => {
      live = false
    }
  }, [ordered, run])

  useEffect(ask, [ask])

  // Where a drag ended up, so a click that was really a drag does not also
  // select whatever happened to be under the pointer when it stopped.
  const dragging = useRef<{ x: number; y: number } | null>(null)
  const moved = useRef(false)

  const unlessDragged = (act: () => void) => () => {
    if (!moved.current) act()
  }

  /**
   * Bring a world to the middle.
   *
   * `placeOf` is in space coordinates and the pan is in screen pixels, so the
   * scale has to be applied here — the transform below is `translate` then
   * `scale`, which is the order that keeps a drag moving the sky by exactly as
   * far as the pointer went, at every zoom.
   */
  const focus = useCallback(
    (world: string) => {
      const place = placeOf(ordered.indexOf(world))
      setPan({ x: -place.x * zoom, y: -place.y * zoom })
    },
    [ordered, zoom],
  )

  /**
   * Zoom on the wheel, but only while a modifier is down.
   *
   * The sky is tall and there is a page under it. A plain wheel that zoomed
   * would trap anybody trying to scroll past, so the plain wheel is left alone
   * and the buttons are the discoverable way in. It is a listener rather than
   * `onWheel` because React's is passive, and a passive listener cannot call
   * `preventDefault` — the page would zoom AND scroll.
   */
  useEffect(() => {
    const held = viewport.current
    if (!held) return

    const wheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return
      event.preventDefault()
      setZoom((was) =>
        Math.min(ZOOM.most, Math.max(ZOOM.least, was - Math.sign(event.deltaY) * ZOOM.step)),
      )
    }

    held.addEventListener("wheel", wheel, { passive: false })
    return () => held.removeEventListener("wheel", wheel)
  }, [])

  if (ordered.length === 0) {
    return (
      <Nothing icon={OrbitIcon} title="nothing in the sky yet">
          a world is where data lives.{" "}
          <Link
            href="/dashboard/ordered"
            className="text-white underline decoration-white/30 underline-offset-4"
          >
            make one
          </Link>{" "}
        and it appears here, with whatever you put in orbit around it.
      </Nothing>
    )
  }

  const open = looking ? answers[looking.world] : undefined

  return (
    // Full bleed, and the negative margins are how: the console pads every page
    // and the sky is the one page whose subject IS the space. A bordered box
    // inside a padded column made it a picture of a sky on a page; this makes
    // the page the sky, and everything that was a heading above it becomes a
    // badge floating on it.
    <div className="-mx-6 -my-8 h-[calc(100svh-3.5rem)]">
      <div
        ref={viewport}
        className="relative h-full w-full touch-none select-none overflow-hidden bg-background"
        onPointerDown={(event) => {
          dragging.current = { x: event.clientX - pan.x, y: event.clientY - pan.y }
          moved.current = false
          event.currentTarget.setPointerCapture(event.pointerId)
        }}
        onPointerMove={(event) => {
          const from = dragging.current
          if (!from) return
          const next = { x: event.clientX - from.x, y: event.clientY - from.y }
          if (Math.hypot(next.x - pan.x, next.y - pan.y) > 3) moved.current = true
          setPan(next)
        }}
        onPointerUp={(event) => {
          dragging.current = null
          event.currentTarget.releasePointerCapture(event.pointerId)
        }}
        onPointerCancel={() => {
          dragging.current = null
        }}
      >
        {/* The sky itself. Everything in it is placed from the middle, so the
            pan is one transform rather than a position per world. */}
        <div
          className="absolute left-1/2 top-1/2"
          style={{
            transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom})`,
          }}
        >
          {ordered.map((world, index) => {
            const place = placeOf(index)
            const answer = answers[world]

            return (
              <div className="absolute" key={world} style={{ left: place.x, top: place.y }}>
                <WorldSystem
                  world={world}
                  census={answer?.census ?? null}
                  refused={Boolean(answer?.error)}
                  chosen={world === chosen}
                  held={!onScreen}
                  selected={looking?.world === world ? (looking.body?.id ?? null) : null}
                  onChoose={unlessDragged(() => {
                    choose(world)
                    focus(world)
                    setLooking({ world, body: null })
                  })}
                  onInspect={(body) =>
                    unlessDragged(() => setLooking({ world, body }))()
                  }
                />
              </div>
            )
          })}
        </div>

        {/* Chrome, floating. Everything here used to be a block of page above
            and below the sky; as badges it stays legible and stops competing
            with the thing it describes. */}
        <Head />

        <div className="absolute right-3 top-3 flex flex-col gap-1">
          <Handle
            label="closer"
            onClick={() => setZoom((was) => Math.min(ZOOM.most, was + ZOOM.step))}
          >
            <Plus className="size-3.5" />
          </Handle>
          <Handle
            label="further out"
            onClick={() => setZoom((was) => Math.max(ZOOM.least, was - ZOOM.step))}
          >
            <Minus className="size-3.5" />
          </Handle>
          <Handle
            label="back to the middle"
            onClick={() => {
              setZoom(0.8)
              setPan({ x: 0, y: 0 })
            }}
          >
            <Crosshair className="size-3.5" />
          </Handle>
        </div>

        <Legend answers={answers} />

        <p className="font-mono pointer-events-none absolute bottom-3 right-3 text-[10px] text-muted-foreground/70">
          drag · ⌘/ctrl+scroll to zoom · click a planet
        </p>

        {looking ? (
          <Panel
            looking={looking}
            census={open?.census ?? null}
            error={open?.error}
            retry={ask}
            onClose={() => setLooking(null)}
          />
        ) : null}
      </div>
    </div>
  )
}

/**
 * The title, as a badge on the sky rather than a heading above it.
 *
 * The explanation moved into a tooltip. On a page whose whole subject is space,
 * four lines of prose permanently occupying the top of it is the one thing
 * guaranteed to be read once and then be in the way forever.
 */
function Head() {
  return (
    <div
      className="pointer-events-auto absolute left-3 top-3 flex items-center gap-2 rounded-md border border-border bg-background/70 px-2.5 py-1.5 backdrop-blur"
      title="every world you hold, and what acts on it. a planet is sized by how much data is in it; each ring is a kind of thing that circles it, further out the further it reaches outside the world. everything here was counted by asking the world itself."
      onPointerDown={(event) => event.stopPropagation()}
    >
      <OrbitIcon className="size-3.5 text-muted-foreground" />
      <span className="font-mono text-xs text-white">orbit</span>
    </div>
  )
}

function Handle({
  label,
  onClick,
  children,
}: {
  label: string
  onClick: () => void
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
      // The sky under this is a drag target, and a pointerdown that starts on a
      // button would otherwise begin a pan and end as a click on nothing.
      onPointerDown={(event) => event.stopPropagation()}
      className="flex size-7 items-center justify-center rounded-md border border-border bg-background/70 text-muted-foreground backdrop-blur transition-colors hover:border-white/30 hover:text-white"
    >
      {children}
    </button>
  )
}

/**
 * What you clicked, in words.
 *
 * A planet answers with its census; a body answers with whatever its band asked
 * the world to carry back. Neither is fetched on click — both are already here,
 * because they came back in the same run that drew the ring. A panel that had
 * to ask again would be a second account of what is already on screen.
 */
function Panel({
  looking,
  census,
  error,
  retry,
  onClose,
}: {
  looking: Looking
  census: Census | null
  error: unknown
  retry: () => void
  onClose: () => void
}) {
  const band = looking.body ? bandOf(looking.body.kind) : null

  return (
    <div
      className="absolute bottom-3 right-3 max-h-3/4 w-80 overflow-y-auto rounded-lg border border-border bg-muted/95 p-4 backdrop-blur"
      onPointerDown={(event) => event.stopPropagation()}
    >
      <div className="mb-3 flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-mono truncate text-sm text-white">
            {looking.body ? looking.body.id : looking.world}
          </p>
          <p className={cn("text-xs", band ? band.ink : "text-muted-foreground")}>
            {band ? `${band.kind} in ${looking.world}` : "world"}
          </p>
        </div>
        <button
          type="button"
          aria-label="close"
          onClick={onClose}
          className="shrink-0 text-muted-foreground transition-colors hover:text-white"
        >
          <X className="size-4" />
        </button>
      </div>

      {error ? (
        <RefusalNote error={error} retry={retry} />
      ) : looking.body ? (
        <Says body={looking.body} band={band} />
      ) : census ? (
        <World census={census} />
      ) : (
        <p className="font-mono text-xs text-muted-foreground">asking…</p>
      )}
    </div>
  )
}

/** One body, as the fields its band carried back. */
function Says({ body, band }: { body: Body; band: Band | null }) {
  const said = Object.entries(body).filter(
    ([field, value]) => field !== "kind" && field !== "id" && value !== undefined,
  )

  return (
    <>
      {band ? (
        <p className="mb-3 text-xs leading-relaxed text-muted-foreground">{band.reach}</p>
      ) : null}

      {said.length === 0 ? (
        <p className="text-xs text-muted-foreground">
          it is declared and says nothing else about itself yet.
        </p>
      ) : (
        <dl className="space-y-2">
          {said.map(([field, value]) => (
            <div key={field}>
              <dt className="font-mono text-xs text-muted-foreground">{shown(field)}</dt>
              <dd className="font-mono mt-0.5 text-xs break-words text-white/85">
                <Value field={field} value={value} />
              </dd>
            </div>
          ))}
        </dl>
      )}
    </>
  )
}

/** The field names a world uses, said the way a person would ask for them. */
const NAMES: Record<string, string> = {
  ran_at: "last run",
  every: "cadence",
  asks: "asks",
  into: "space",
  embeds: "embeds",
  failed: "what went wrong",
  tries: "attempts",
  source: "the lua it runs",
}

const shown = (field: string) => NAMES[field] ?? field

function Value({ field, value }: { field: string; value: unknown }) {
  if (field === "ran_at" && typeof value === "number") return <>{showWhen(value)}</>

  // A cadence is written in seconds and read in minutes, and a job every three
  // hundred seconds is a job that says "every five minutes" out loud.
  if (field === "every" && typeof value === "number") {
    return <>every {value < 120 ? `${value}s` : `${Math.round(value / 60)}m`}</>
  }

  if (field === "failed") return <span className="text-flame">{String(value)}</span>

  if (field === "source") {
    return (
      <pre className="mt-1 overflow-x-auto rounded-md border border-border p-2 leading-relaxed text-white/70">
        {String(value)}
      </pre>
    )
  }

  if (typeof value === "boolean" || typeof value === "number") return <>{String(value)}</>
  if (typeof value === "string") return <span className="text-spark">{value}</span>
  return <>{JSON.stringify(value)}</>
}

/** One world's census: its mass, and one line per band it has anything in. */
function World({ census }: { census: Census }) {
  return (
    <>
      <dl className="space-y-1.5">
        <Line of={census.data} one="entity" many="entities" />
      </dl>

      <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
        {showCount(census.entities)} in all — the rest declare what they are,
        which is the vocabulary rather than the data. the planet is sized by the
        data.
      </p>

      <div className="mt-4 space-y-1.5">
        {BANDS.map((band) => {
          const count = countOf(census, band.kind)
          if (count === 0) return null

          return (
            <div className="flex items-baseline gap-2" key={band.kind}>
              <span aria-hidden className={cn("size-2 shrink-0 self-center", band.mark)} />
              <dt className="font-mono text-sm text-white">{showCount(count)}</dt>
              <dd className="text-sm text-muted-foreground">
                {count === 1 ? band.label.replace(/s$/, "") : band.label}
              </dd>
            </div>
          )
        })}
      </div>

      {census.belts.length > 0 ? (
        <div className="mt-4 border-t border-border pt-3">
          <p className="mb-2 text-xs text-muted-foreground">
            the latent field, by space. two spaces are never comparable, so they
            are never one number.
          </p>
          {census.belts.map((belt) => (
            <p className="font-mono text-xs text-white/70" key={belt.field}>
              {belt.field} · {showCount(belt.held)} in {belt.space ?? "no space"}
            </p>
          ))}
        </div>
      ) : null}
    </>
  )
}

function Line({ of, one, many }: { of: number; one: string; many: string }) {
  return (
    <div className="flex items-baseline gap-2">
      <dt className="font-mono text-sm text-white">{showCount(of)}</dt>
      <dd className="text-sm text-muted-foreground">{of === 1 ? one : many}</dd>
    </div>
  )
}

/**
 * What the rings mean, and how many of each thing you hold in all.
 *
 * Below the sky rather than floating in it. Five bands with a sentence each is
 * a paragraph, and a paragraph pinned over a picture is in the way of the
 * picture — the panel earns its overlay by being about the thing you just
 * clicked, and this does not.
 */
function Legend({ answers }: { answers: Record<string, Answer> }) {
  const held = Object.values(answers).map((answer) => answer.census)

  return (
    // Five cards of prose became five chips. The totals are the part worth
    // having on screen at all times; what each band MEANS is a thing you read
    // once, so it is a tooltip now rather than a paragraph competing with the
    // sky it is describing.
    <div
      className="absolute bottom-3 left-3 flex flex-wrap gap-1.5"
      onPointerDown={(event) => event.stopPropagation()}
    >
      {BANDS.map((band) => {
        const across = held.reduce((sum, census) => sum + countOf(census, band.kind), 0)

        return (
          <span
            key={band.kind}
            title={band.reach}
            className="flex items-center gap-1.5 rounded-md border border-border bg-background/70 px-2 py-1 backdrop-blur"
          >
            <span aria-hidden className={cn("size-1.5 shrink-0", band.mark)} />
            <span className="font-mono text-xs text-white">{showCount(across)}</span>
            <span className={cn("text-xs", band.ink)}>{band.label}</span>
          </span>
        )
      })}
    </div>
  )
}
