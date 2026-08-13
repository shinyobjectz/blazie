"use client"

import { Activity } from "lucide-react"

import { Asked, Nothing, PageHead } from "@/components/dashboard/page-shell"
import type { Fact } from "@/lib/blazie"
import { showBytes, showCount, showWhen } from "@/lib/format"
import { cn } from "@/lib/utils"

import { useCluster } from "../cluster"
import { useAsk } from "../use-ask"

/**
 * How the node is doing — which is a query, because there is no health endpoint.
 *
 * Reading the clock, the VM, or how many ledgers are open is reaching outside:
 * the answer depends on when you ask. So vitals is a *job*, not a formula, and
 * the readings it writes are ordinary facts in an ordinary ledger. This page is
 * `ask` with `id: vitals`, and the trend below is a query over the older
 * readings rather than a time-series database.
 */

type Panel = {
  ledger: string
  id: string
  title: string
  blurb: string
  readings: { label: string; attribute: string; as: (n: number) => string }[]
}

const panels: Panel[] = [
  {
    ledger: "$vitals",
    id: "vitals",
    title: "the node",
    blurb: "one reading per cadence. history is just the older facts.",
    readings: [
      { label: "memory", attribute: "memory_bytes", as: showBytes },
      { label: "open ledgers", attribute: "open_ledgers", as: showCount },
      { label: "processes", attribute: "processes", as: showCount },
      { label: "subscriptions", attribute: "subscriptions", as: showCount },
    ],
  },
  {
    ledger: "$backup",
    id: "backup",
    title: "what is copied",
    blurb: "the last run's report, written as facts by the job that ran it.",
    readings: [
      { label: "copied", attribute: "copied_bytes", as: showBytes },
      { label: "segments", attribute: "copied_segments", as: showCount },
      { label: "held ledgers", attribute: "held_ledgers", as: showCount },
    ],
  },
  {
    ledger: "$drill",
    id: "drill",
    title: "last proven restore",
    blurb:
      "a backup nobody restored is a hope. this advances only when one actually did.",
    readings: [
      { label: "proven at", attribute: "proven_at", as: showWhen },
      { label: "ledgers restored", attribute: "restored_ledgers", as: showCount },
    ],
  },
]

export default function Vitals() {
  const { who } = useCluster()
  // One question for all three panels: they are all in the held name already if
  // they were granted at all, so opening them separately would ask the cluster
  // three times for facts that came back in the first answer.
  const asked = useAsk({})

  return (
    <>
      <PageHead title="vitals">
        there is no health endpoint. the jobs that watch the node write what they
        saw into ledgers, and this reads them with open and ask — the same two
        operations as everything else here.
      </PageHead>

      <Asked
        of={asked.facts}
        error={asked.error}
        loading={asked.loading}
        retry={asked.retry}
        empty={<NoReadings />}
      >
        {(facts) => (
          <>
            <div className="grid gap-x-10 gap-y-9 sm:grid-cols-2 lg:grid-cols-3">
              {panels.map((panel) => (
                <PanelView
                  key={panel.ledger}
                  panel={panel}
                  facts={facts}
                  granted={who.ledgers.includes(panel.ledger)}
                />
              ))}
            </div>

            <Trend facts={facts} />
          </>
        )}
      </Asked>
    </>
  )
}

function PanelView({
  panel,
  facts,
  granted,
}: {
  panel: Panel
  facts: Fact[]
  granted: boolean
}) {
  const mine = facts.filter((f) => String(f.id) === panel.id)

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
          reach is a list, so this is a grant nobody wrote — not a permission you
          can raise from here.
        </p>
      ) : mine.length === 0 ? (
        <p className="mt-4 max-w-xs text-sm leading-relaxed text-muted-foreground">
          granted, but the job has not written a reading yet.
        </p>
      ) : (
        <>
          <dl className="mt-4 space-y-2.5">
            {panel.readings.map((reading) => {
              const value = newest(mine, reading.attribute)
              return (
                <div key={reading.label} className="flex items-baseline gap-3">
                  <dt className="w-28 shrink-0 text-sm text-muted-foreground">
                    {reading.label}
                  </dt>
                  <dd className="font-mono text-sm text-white">
                    {value === undefined ? "—" : reading.as(value)}
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

/**
 * A trend, which is a query over old readings.
 *
 * Drawn as bars against the largest reading in the window rather than a proper
 * chart, because the useful question here is "is it climbing" and a library
 * that answers it more precisely would not answer it more usefully.
 */
function Trend({ facts }: { facts: Fact[] }) {
  const history = facts
    .filter((f) => String(f.id) === "vitals" && f.attribute === "memory_bytes")
    .filter((f): f is Fact & { value: number } => typeof f.value === "number")
    .sort((a, b) => a.tx - b.tx)
    .slice(-60)

  if (history.length < 2) return null

  const peak = Math.max(...history.map((f) => f.value))

  return (
    <section className="mt-14">
      <h2 className="mb-2 text-lg font-medium tracking-tight text-white">
        memory, over the readings held
      </h2>
      <p className="mb-6 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        {history.length} readings in this snapshot, oldest first. nothing built a
        time series to make this — the older facts never went anywhere, so a
        trend is a question about them.
      </p>

      <div className="flex h-28 items-end gap-px overflow-hidden rounded-lg border border-border bg-muted/40 p-3">
        {history.map((reading) => (
          <div
            key={`${reading.tx}-${reading.value}`}
            className={cn("min-w-[2px] flex-1 rounded-sm bg-flame/60")}
            style={{ height: `${Math.max(2, (reading.value / peak) * 100)}%` }}
            title={`tx ${reading.tx} · ${showBytes(reading.value)}`}
          />
        ))}
      </div>

      <p className="font-mono mt-3 text-xs text-muted-foreground">
        peak {showBytes(peak)}
      </p>
    </section>
  )
}

function NoReadings() {
  return (
    <Nothing icon={Activity} title="nothing has reported yet">
      vitals is declared as a job with a cadence. until the node&apos;s runner
      ticks it, there is no reading to read — and that absence is itself
      readable, rather than a dashboard showing zero.
    </Nothing>
  )
}

/** The latest value of one attribute on this id. A correction is a later fact. */
function newest(facts: Fact[], attribute: string): number | undefined {
  const held = facts
    .filter((f) => f.attribute === attribute && typeof f.value === "number")
    .sort((a, b) => b.tx - a.tx)[0]
  return held?.value as number | undefined
}
