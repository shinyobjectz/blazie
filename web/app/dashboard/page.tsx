"use client"

import { Database, Table2 } from "lucide-react"
import Link from "next/link"
import { useMemo, useState } from "react"

import { Asked, Nothing, PageHead } from "@/components/dashboard/page-shell"
import { CopyButton } from "@/components/ui/copy-button"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import type { Value } from "@/lib/blazie"
import { cn } from "@/lib/utils"

import { useCluster } from "./cluster"
import { EVERY_ROW, type Row, columnsOf, useLua } from "./use-lua"

/**
 * The data, as a table. The first thing anybody wants from a backend.
 *
 * Columns are the union of every field present rather than a schema, because
 * there is no schema to read — two entities in one ledger can hold entirely
 * different fields and both are correct. A blank cell means the entity does not
 * have that field, which is different from holding nothing, and the table says
 * so rather than printing an empty string.
 */
export default function Data() {
  const { ledger } = useCluster()
  const [narrow, setNarrow] = useState("")
  const { value, error, running, retry } = useLua<Row[]>(EVERY_ROW)

  const rows = useMemo(() => (Array.isArray(value) ? value : []), [value])
  const columns = useMemo(() => columnsOf(rows), [rows])

  const shown = useMemo(() => {
    const needle = narrow.trim().toLowerCase()
    if (!needle) return rows
    return rows.filter((row) =>
      JSON.stringify(row).toLowerCase().includes(needle),
    )
  }, [rows, narrow])

  if (!ledger) {
    return (
      <>
        <PageHead title="data">nothing to show until there is a ledger.</PageHead>
        <Nothing icon={Database} title="no ledger yet">
          a ledger is where your data lives.{" "}
          <Link
            href="/dashboard/ledgers"
            className="text-white underline decoration-white/30 underline-offset-4"
          >
            make one
          </Link>{" "}
          and this page fills in.
        </Nothing>
      </>
    )
  }

  return (
    <>
      <PageHead
        title="data"
        aside={
          <input
            value={narrow}
            onChange={(event) => setNarrow(event.target.value)}
            placeholder="filter rows"
            className="font-mono w-56 rounded-md border border-border bg-muted px-3 py-1.5 text-sm text-white placeholder:text-muted-foreground focus:border-white/30 focus:outline-none"
          />
        }
      >
        everything in <span className="font-mono text-white/80">{ledger}</span>.
        columns are whatever fields are actually present — there is no schema to
        read, and two rows may hold entirely different ones.
      </PageHead>

      <Asked of={shown} error={error} loading={running} retry={retry} rows={6} empty={<Empty />}>
        {(here) => (
          <>
            <div className="overflow-x-auto rounded-lg border border-border">
              <Table className="font-mono text-xs">
                <TableHeader>
                  <TableRow className="hover:bg-transparent">
                    <TableHead className="text-muted-foreground">id</TableHead>
                    {columns.map((column) => (
                      <TableHead key={column} className="text-muted-foreground">
                        {column}
                      </TableHead>
                    ))}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {here.map((row) => (
                    <TableRow key={row.id}>
                      <TableCell className="text-white/85">{row.id}</TableCell>
                      {columns.map((column) => (
                        <TableCell key={column} className="max-w-xs truncate">
                          <Cell value={row[column]} />
                        </TableCell>
                      ))}
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>

            <p className="mt-4 text-sm text-muted-foreground">
              {shown.length.toLocaleString()}{" "}
              {shown.length === 1 ? "entity" : "entities"}
              {narrow.trim() ? ` of ${rows.length.toLocaleString()}` : ""} ·{" "}
              {columns.length} {columns.length === 1 ? "field" : "fields"}
            </p>

            <Chunk />
          </>
        )}
      </Asked>
    </>
  )
}

/**
 * The Lua this page ran, shown at the bottom.
 *
 * Not decoration: it is the answer to "how would I do that myself", and it is
 * the same six lines whether the ledger holds three rows or three million.
 */
function Chunk() {
  return (
    <details className="mt-10 rounded-lg border border-border">
      <summary className="cursor-pointer px-4 py-3 text-sm text-muted-foreground transition-colors hover:text-white">
        the lua this page ran
      </summary>
      <div className="relative border-t border-border">
        <div className="absolute right-2 top-2">
          <CopyButton value={EVERY_ROW} />
        </div>
        <pre className="overflow-x-auto p-4 font-mono text-xs leading-relaxed text-white/80">
          {EVERY_ROW}
        </pre>
      </div>
    </details>
  )
}

function Cell({ value }: { value: Value }) {
  if (value === undefined) {
    return (
      <span className="text-white/20" title="this entity has no such field">
        —
      </span>
    )
  }
  if (value === null) return <span className="text-muted-foreground">nil</span>
  if (typeof value === "string") return <span className="text-spark">{value}</span>
  if (typeof value === "number" || typeof value === "boolean") {
    return <span className="text-white/90">{String(value)}</span>
  }
  return <span className={cn("text-white/70")}>{JSON.stringify(value)}</span>
}

function Empty() {
  return (
    <Nothing icon={Table2} title="this ledger is empty">
      write the first thing into it from the{" "}
      <Link
        href="/dashboard/editor"
        className="text-white underline decoration-white/30 underline-offset-4"
      >
        editor
      </Link>
      {" — "}
      <code className="font-mono text-white/80">ada.height = 180</code> is a
      complete program.
    </Nothing>
  )
}
