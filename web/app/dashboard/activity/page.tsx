"use client"

import { Activity as ActivityIcon } from "lucide-react"
import { useCallback, useEffect, useState } from "react"

import { Nothing, PageHead } from "@/components/dashboard/page-shell"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Skeleton } from "@/components/ui/skeleton"
import type { Value } from "@/lib/blazie"
import { showBytes, showCount, showWhen } from "@/lib/format"

import { useCluster } from "../cluster"

/**
 * What the node has been doing.
 *
 * There is no health endpoint and no metrics store. The jobs that watch the
 * node write their readings into ordinary worlds, so this page is the same Lua
 * as every other page — pointed at `$vitals` instead of at yours.
 *
 * Which is also why each panel runs on its own: they are separate worlds, and
 * one this caller was not granted must not blank the others.
 */

type Panel = {
  world: string
  entity: string
  title: string
  blurb: string
  readings: { label: string; field: string; as: (n: number) => string }[]
}

const PANELS: Panel[] = [
  {
    world: "$vitals",
    entity: "vitals",
    title: "the node",
    blurb: "one reading per cadence. the older ones never went anywhere.",
    readings: [
      { label: "memory", field: "memory_bytes", as: showBytes },
      { label: "open worlds", field: "open_ledgers", as: showCount },
      { label: "processes", field: "processes", as: showCount },
      { label: "subscriptions", field: "subscriptions", as: showCount },
    ],
  },
  {
    world: "$backup",
    entity: "backup",
    title: "what is copied",
    blurb: "the last run's report, written by the job that ran it.",
    readings: [
      { label: "copied", field: "copied_bytes", as: showBytes },
      { label: "segments", field: "copied_segments", as: showCount },
      { label: "held worlds", field: "held_ledgers", as: showCount },
    ],
  },
  {
    world: "$drill",
    entity: "drill",
    title: "last proven restore",
    blurb:
      "a backup nobody restored is a hope. this moves only when one actually did.",
    readings: [
      { label: "proven at", field: "proven_at", as: showWhen },
      { label: "worlds restored", field: "restored_ledgers", as: showCount },
    ],
  },
]

export default function Activity() {
  const { worlds } = useCluster()

  return (
    <>
      <PageHead title="activity">
        there is no health endpoint here. the jobs that watch the node write what
        they saw into worlds, and this reads them with the same lua as anything
        else.
      </PageHead>

      <div className="grid gap-x-10 gap-y-9 sm:grid-cols-2 lg:grid-cols-3">
        {PANELS.map((panel) => (
          <PanelView
            key={panel.world}
            panel={panel}
            granted={worlds.includes(panel.world)}
          />
        ))}
      </div>
    </>
  )
}

function PanelView({ panel, granted }: { panel: Panel; granted: boolean }) {
  const { run } = useCluster()
  const [attempt, setAttempt] = useState(0)
  const asking = `${panel.world} ${panel.entity} ${attempt}`

  const [answered, setAnswered] = useState<{
    to: string
    held: Record<string, Value> | null
    error: unknown
  } | null>(null)

  useEffect(() => {
    if (!granted) return
    let live = true

    // Whatever the job last wrote about itself, as a plain table.
    const source = `local out = {}
for field, value in pairs(${panel.entity}) do out[field] = value end
return out`

    run(panel.world, source)
      .then(
        (result) =>
          live &&
          setAnswered({ to: asking, held: (result.value ?? {}) as Record<string, Value>, error: null }),
      )
      .catch((thrown) => live && setAnswered({ to: asking, held: null, error: thrown }))

    return () => {
      live = false
    }
  }, [panel, granted, asking, run])

  const read = useCallback(() => setAttempt((n) => n + 1), [])

  // Only an answer to what is being asked now. Clearing the error by hand at the
  // top of the effect was a synchronous setState inside one, and this says the
  // same thing by construction: a refusal from the previous panel cannot be
  // shown against this one, because it is not addressed to it.
  const current = answered?.to === asking ? answered : null
  const held = current?.held ?? null
  const error = current?.error ?? null

  return (
    <div className="border-l-2 border-flame/50 pl-5">
      <h3 className="text-base font-medium tracking-tight text-white">
        {panel.title}
      </h3>
      <p className="font-mono mt-1 text-xs text-muted-foreground">
        {panel.world}
      </p>

      {!granted ? (
        <p className="mt-4 max-w-xs text-sm leading-relaxed text-muted-foreground">
          this caller was not granted{" "}
          <span className="font-mono text-white/70">{panel.world}</span>. a
          reach is a list, so this is a grant nobody wrote.
        </p>
      ) : error ? (
        <RefusalNote error={error} className="mt-4 -ml-5 border-l-0 pl-5" retry={read} />
      ) : !held ? (
        <div className="mt-4 space-y-2">
          {[0, 1, 2].map((i) => (
            <Skeleton key={i} className="h-5 w-full bg-white/5" />
          ))}
        </div>
      ) : Object.keys(held).length === 0 ? (
        <p className="mt-4 max-w-xs text-sm leading-relaxed text-muted-foreground">
          granted, but nothing has been written here yet.
        </p>
      ) : (
        <>
          <dl className="mt-4 space-y-2.5">
            {panel.readings.map((reading) => {
              const value = held[reading.field]
              return (
                <div key={reading.label} className="flex items-baseline gap-3">
                  <dt className="w-28 shrink-0 text-sm text-muted-foreground">
                    {reading.label}
                  </dt>
                  <dd className="font-mono text-sm text-white">
                    {typeof value === "number" ? reading.as(value) : "—"}
                  </dd>
                </div>
              )
            })}
          </dl>
          <p className="mt-4 text-xs leading-relaxed text-muted-foreground">
            {panel.blurb}
          </p>
        </>
      )}
    </div>
  )
}

export function NoReadings() {
  return (
    <Nothing icon={ActivityIcon} title="nothing has reported yet">
      the jobs that watch this node have a cadence. until the runner ticks one,
      there is nothing written to read.
    </Nothing>
  )
}
