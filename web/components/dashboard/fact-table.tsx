"use client"

import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import type { Fact, Value } from "@/lib/blazie"
import { cn } from "@/lib/utils"

/**
 * Facts, in the shape they are actually stored in.
 *
 * All five slots, always, including `by` — a table that hid provenance to save
 * a column would be hiding the one column that makes the rest of them worth
 * anything. `by: null` gets said out loud as "from outside" rather than left
 * blank, because blank reads as missing and this is a claim.
 */

export function FactValue({ value }: { value: Value }) {
  // The one reserved envelope. Printing a thousand floats helps nobody; what
  // matters is that it is a symbol and which space it belongs to.
  if (
    value &&
    typeof value === "object" &&
    "$symbol" in value &&
    typeof (value as { $symbol: unknown }).$symbol === "object"
  ) {
    const symbol = (value as { $symbol: { space: string; values: number[] } })
      .$symbol
    return (
      <span className="text-ember">
        symbol · {symbol.space} · {symbol.values?.length ?? 0}d
      </span>
    )
  }

  if (value === null) return <span className="text-muted-foreground">null</span>
  if (typeof value === "string") return <span className="text-spark">{value}</span>
  if (typeof value === "number" || typeof value === "boolean") {
    return <span className="text-white/90">{String(value)}</span>
  }
  return <span className="text-white/70">{JSON.stringify(value)}</span>
}

export function By({ by }: { by: string | null }) {
  if (by === null) {
    return (
      <span className="text-muted-foreground" title="nothing produced this — it came from outside and cannot be reproduced">
        from outside
      </span>
    )
  }
  return <span className="text-ember">{by}</span>
}

export function FactTable({
  facts,
  className,
  show = ["id", "attribute", "value", "tx", "by"],
}: {
  facts: Fact[]
  className?: string
  show?: ("id" | "attribute" | "value" | "tx" | "by")[]
}) {
  return (
    <div className={cn("overflow-x-auto rounded-lg border border-border", className)}>
      <Table className="font-mono text-xs">
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            {show.map((column) => (
              <TableHead key={column} className="text-muted-foreground">
                {column}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {facts.map((fact) => (
            // A ledger admits the same assertion twice, so id+attribute+tx is
            // not unique on its own; the value is what separates them.
            <TableRow key={`${fact.id}·${fact.attribute}·${fact.tx}·${JSON.stringify(fact.value)}`}>
              {show.includes("id") && (
                <TableCell className="text-white/80">{String(fact.id)}</TableCell>
              )}
              {show.includes("attribute") && (
                <TableCell className="text-white/60">{fact.attribute}</TableCell>
              )}
              {show.includes("value") && (
                <TableCell className="max-w-md truncate">
                  <FactValue value={fact.value} />
                </TableCell>
              )}
              {show.includes("tx") && (
                <TableCell className="text-muted-foreground">{fact.tx}</TableCell>
              )}
              {show.includes("by") && (
                <TableCell>
                  <By by={fact.by} />
                </TableCell>
              )}
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}
