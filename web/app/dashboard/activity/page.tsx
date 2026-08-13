"use client"

import { Activity as ActivityIcon } from "lucide-react"
import { useCallback, useEffect, useState } from "react"

import { Nothing, PageHead } from "@/components/dashboard/page-shell"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Skeleton } from "@/components/ui/skeleton"
import { type Value, run } from "@/lib/blazie"
import { showBytes, showCount, showWhen } from "@/lib/format"

import { useCluster } from "../cluster"

/**
 * What the node has been doing.
 *
 * There is no health endpoint and no metrics store. The jobs that watch the
 * node write their readings into ordinary ledgers, so this page is the same Lua
 * as every other page — pointed at `$vitals` instead of at yours.
 *
 * Which is also why each panel runs on its own: they are separate ledgers, and
 * one this caller was not granted must not blank the others.
 */

type Panel = {
  ledger: string
  entity: string
  title: string
  blurb: string
  readings: { label: string; field: string; as: (n: number) => string }[]
}

const PANELS: Panel[] = [
  {
    ledger: "$vitals",
    entity: "vitals",
    title: "the node",
    blurb: "one reading per cadence. the older ones never went anywhere.",
    readings: [
      { label: "memory", field: "memory_bytes", as: showBytes },
      { label: "open ledgers", field: "open_ledgers", as: showCount },
      { label: "processes", field: "processes", as: showCount },
      { label: "subscriptions", field: "subscriptions", as: showCount },
    ],
  },
  {
    ledger: "$backup",
    entity: "backup",
    title: "what is copied",
    blurb: "the last run's report, written by the job that ran it.",
    readings: [
      { label: "copied", field: "copied_bytes", as: showBytes },
      { label: "segments", field: "copied_segments", as: showCount },
      { label: "held ledgers", field: "held_ledgers", as: showCount },
    ],
  },
  {
    ledger: "$drill",
    entity: "drill",
    title: "last proven restore",
    blurb:
      "a backup nobody restored is a hope. this moves only when one actually did.",
    readings: [
      { label: "proven at", field: "proven_at", as: showWhen },
      { label: "ledgers restored", field: "restored_ledgers", as: showCount },
    ],
  },
]

export default function Activity() {
  const { who } = useCluster()

  return (
    <>
      <PageHead title="activity">
        there is no health endpoint here. the jobs that watch the node write what
        they saw into ledgers, and this reads them with the same lua as anything
        else.
      </PageHead>

      <div className="grid gap-x-10 gap-y-9 sm:grid-cols-2 lg:grid-cols-3">
        {PANELS.map((panel) => (
          <PanelView
            key={panel.ledger}
            panel={panel}
            granted={who.ledgers.includes(panel.ledger)}
          />
        ))}
      </div>
    </>
  )
}

function PanelView({ panel, granted }: { panel: Panel; granted: boolean }) {
  const [held, setHeld] = useState<Record<string, Value> | null>(null)
  const [error, setError] = useState<unknown>(null)

  const read = useCallback(() => {
    if (!granted) return
    let live = true
    setError(null)

    // Whatever the job last wrote about itself, as a plain table.
    const source = `local out = {}
for field, value in pairs(${panel.entity}) do out[field] = value end
return out`

    run(panel.ledger, source)
      .then((result) => live && setHeld((result.value ?? {}) as Record<string, Value>))
      .catch((thrown) => live && setError(thrown))

    return () => {
      live = false
    }
  }, [panel, granted])

  useEffect(read, [read])

  return (
    <div className="border-l-2 border-flame/50 pl-5">
      <h3 className="text-base font-medium tracking-tight text-white">
        {panel.title}
      </h3>
      <p className="font-mono mt-1 text-xs text-muted-foreground">
        {panel.ledger}
      </p>

      {!granted ? (
        <p className="mt-4 max-w-xs text-sm leading-relaxed text-muted-foreground">
          this caller was not granted{" "}
          <span className="font-mono text-white/70">{panel.ledger}</span>. a
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
