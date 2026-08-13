"use client"

import { CopyButton } from "@/components/ui/copy-button"
import type { SnapshotName as Name } from "@/lib/blazie"

/**
 * The name, in the bar, always.
 *
 * A caller holds a name and never the bytes, so the name is the one thing on
 * this console worth copying: paste it to somebody else and they get the same
 * answers you are looking at. It is in the header rather than on a page because
 * it qualifies every number on every page.
 */
export function SnapshotName({ name }: { name: Name }) {
  const ledgers = Object.entries(name)

  if (ledgers.length === 0) {
    return (
      <span className="font-mono truncate text-xs text-muted-foreground">
        no ledgers — nothing to name
      </span>
    )
  }

  return (
    <span className="flex min-w-0 items-center gap-2">
      <span className="font-mono flex min-w-0 items-center gap-2 overflow-x-auto whitespace-nowrap text-xs">
        {ledgers.map(([ledger, tx]) => (
          <span
            key={ledger}
            className="inline-flex shrink-0 items-center gap-1.5 rounded border border-border px-2 py-1"
          >
            <span className="text-white/80">{ledger}</span>
            <span className="text-muted-foreground">@</span>
            <span className="text-spark">{tx}</span>
          </span>
        ))}
      </span>
      <CopyButton value={JSON.stringify(name)} className="shrink-0" />
    </span>
  )
}
