"use client"

import { useCallback, useEffect, useState } from "react"

import { Copyable } from "@/components/ui/copyable"
import { RefusalNote } from "@/components/ui/refusal-note"
import { type Fact, type SnapshotName, ask, open } from "@/lib/blazie"
import {
  latestNumber,
  showBytes,
  showCount,
  showName,
  showWhen,
} from "@/lib/format"

/**
 * Health is not a special endpoint. The cluster's jobs write their readings
 * into ordinary ledgers, so the console reads them with open + ask like it
 * reads anything else — which is the whole claim, made checkable.
 */

type Reading = { label: string; value: string }

type Panel = {
  ledger: string
  id: string
  title: string
  blurb: string
  read: (facts: Fact[]) => Reading[]
}

const panels: Panel[] = [
  {
    ledger: "$vitals",
    id: "vitals",
    title: "the node",
    blurb: "one reading per cadence. history is just the older facts.",
    read: (facts) => [
      { label: "memory", value: bytes(latestNumber(facts, "memory_bytes")) },
      {
        label: "open ledgers",
        value: count(latestNumber(facts, "open_ledgers")),
      },
      { label: "processes", value: count(latestNumber(facts, "processes")) },
    ],
  },
  {
    ledger: "$backup",
    id: "backup",
    title: "what is copied",
    blurb: "the last run's report, written as facts by the job that ran it.",
    read: (facts) => [
      { label: "copied", value: bytes(latestNumber(facts, "copied_bytes")) },
      {
        label: "held ledgers",
        value: count(latestNumber(facts, "held_ledgers")),
      },
    ],
  },
  {
    ledger: "$drill",
    id: "drill",
    title: "last proven restore",
    blurb:
      "a backup nobody restored is a hope. this advances only when one actually did.",
    read: (facts) => {
      const proven = latestNumber(facts, "proven_at")
      return [
        {
          label: "proven at",
          value: proven === undefined ? "never" : showWhen(proven),
        },
        {
          label: "ledgers restored",
          value: count(latestNumber(facts, "restored_ledgers")),
        },
      ]
    },
  },
]

function bytes(value: number | undefined) {
  return value === undefined ? "—" : showBytes(value)
}

function count(value: number | undefined) {
  return value === undefined ? "—" : showCount(value)
}

export function Health({ granted }: { granted: string[] }) {
  return (
    <div className="grid gap-x-10 gap-y-8 sm:grid-cols-2 lg:grid-cols-3">
      {panels.map((panel) => (
        <HealthPanel
          key={panel.ledger}
          panel={panel}
          granted={granted.includes(panel.ledger)}
        />
      ))}
    </div>
  )
}

function HealthPanel({ panel, granted }: { panel: Panel; granted: boolean }) {
  const [readings, setReadings] = useState<Reading[] | null>(null)
  const [name, setName] = useState<SnapshotName | null>(null)
  const [error, setError] = useState<unknown>(null)

  // Each panel opens its own ledger. Opening all three together would mean one
  // ungranted ledger blanking the other two.
  const read = useCallback(async () => {
    const opened = await open([panel.ledger])
    const facts = await ask(opened, { id: panel.id })
    return { opened, readings: panel.read(facts) }
  }, [panel])

  useEffect(() => {
    if (!granted) return

    let live = true
    read()
      .then((found) => {
        if (!live) return
        setName(found.opened)
        setReadings(found.readings)
      })
      .catch((thrown) => {
        if (live) setError(thrown)
      })

    return () => {
      live = false
    }
  }, [granted, read])

  const retry = useCallback(() => {
    setError(null)
    setReadings(null)
    read()
      .then((found) => {
        setName(found.opened)
        setReadings(found.readings)
      })
      .catch(setError)
  }, [read])

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
          reach is a list, so this is a grant nobody wrote — not a permission
          you can raise from here.
        </p>
      ) : error ? (
        <RefusalNote
          error={error}
          className="mt-4 -ml-5 border-l-0 pl-5"
          retry={retry}
        />
      ) : !readings ? (
        <p className="font-mono mt-4 text-sm text-muted-foreground">reading…</p>
      ) : (
        <>
          <dl className="mt-4 space-y-2.5">
            {readings.map((reading) => (
              <div key={reading.label} className="flex items-baseline gap-3">
                <dt className="w-28 shrink-0 text-sm text-muted-foreground">
                  {reading.label}
                </dt>
                <dd className="font-mono text-sm text-white">
                  {reading.value}
                </dd>
              </div>
            ))}
          </dl>

          <p className="mt-4 text-xs leading-relaxed text-muted-foreground">
            {panel.blurb}
          </p>

          {name && (
            <Copyable
              text={showName(name)}
              className="mt-3 max-w-full"
              label={showName(name)}
            />
          )}
        </>
      )}
    </div>
  )
}
