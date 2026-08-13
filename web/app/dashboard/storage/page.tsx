"use client"

import { HardDrive } from "lucide-react"
import { useCallback, useEffect, useState } from "react"

import { Nothing, PageHead } from "@/components/dashboard/page-shell"
import { CopyButton } from "@/components/ui/copy-button"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { run } from "@/lib/blazie"
import { showBytes, showCount } from "@/lib/format"

import { useCluster } from "../cluster"

/**
 * What each world costs on disk.
 *
 * Read from `$storage`, where a job writes a reading per world on a cadence —
 * because asking how large a file is reaches outside, so it is a job like
 * everything else that does. Each world is an entity there, which makes this
 * page the same shape as the data page and the chunk below the same six lines.
 */

const CHUNK = `local rows = {}
for w in each { bytes = true } do
  rows[#rows + 1] = {
    id = w.id,
    bytes = w.bytes,
    transactions = w.transactions,
    resident = w.resident,
    checkpoint_bytes = w.checkpoint_bytes,
  }
end
return rows`

type Row = {
  id: string
  bytes?: number
  transactions?: number
  resident?: number
  checkpoint_bytes?: number
}

export default function Storage() {
  const { who } = useCluster()
  const granted = who.worlds.includes("$storage")

  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<unknown>(null)

  const read = useCallback(() => {
    if (!granted) return
    let live = true
    setError(null)

    run("$storage", CHUNK)
      .then((result) => live && setRows((result.value ?? []) as Row[]))
      .catch((thrown) => live && setError(thrown))

    return () => {
      live = false
    }
  }, [granted])

  useEffect(read, [read])

  const total = (rows ?? []).reduce((sum, row) => sum + (row.bytes ?? 0), 0)

  return (
    <>
      <PageHead title="storage">
        what each world costs on disk. a job takes these readings on a cadence,
        because asking how large a file is depends on when you ask — so the
        history is here too, and growth is a question rather than a graph
        somebody had to keep.
      </PageHead>

      {!granted ? (
        <Nothing icon={HardDrive} title="not granted $storage">
          the node writes its storage readings into{" "}
          <span className="font-mono text-white/70">$storage</span>, and this
          caller may not name it. a reach is a list, so this is a grant nobody
          wrote.
        </Nothing>
      ) : error ? (
        <RefusalNote error={error} retry={read} />
      ) : !rows ? (
        <div className="space-y-2">
          {[0, 1, 2, 3].map((i) => (
            <Skeleton key={i} className="h-10 w-full bg-white/5" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <Nothing icon={HardDrive} title="no readings yet">
          the storage job has a cadence and has not run since this node came up.
          until it does there is nothing written to read — which is itself
          readable, rather than a dashboard showing zero.
        </Nothing>
      ) : (
        <>
          <div className="mb-8 grid gap-px overflow-hidden rounded-lg border border-border bg-border sm:grid-cols-3">
            <Figure label="on disk" value={showBytes(total)} note={`${rows.length} worlds`} />
            <Figure
              label="transactions"
              value={showCount(
                rows.reduce((sum, row) => sum + (row.transactions ?? 0), 0),
              )}
              note="across every world"
            />
            <Figure
              label="resident"
              value={showCount(rows.reduce((sum, row) => sum + (row.resident ?? 0), 0))}
              note="facts held in memory"
            />
          </div>

          <div className="overflow-x-auto rounded-lg border border-border">
            <Table className="font-mono text-xs">
              <TableHeader>
                <TableRow className="hover:bg-transparent">
                  {["world", "on disk", "transactions", "resident", "checkpoint"].map(
                    (head) => (
                      <TableHead key={head} className="text-muted-foreground">
                        {head}
                      </TableHead>
                    ),
                  )}
                </TableRow>
              </TableHeader>
              <TableBody>
                {[...rows]
                  .sort((a, b) => (b.bytes ?? 0) - (a.bytes ?? 0))
                  .map((row) => (
                    <TableRow key={row.id}>
                      <TableCell className="text-white/85">{row.id}</TableCell>
                      <TableCell className="text-spark">
                        {row.bytes === undefined ? "—" : showBytes(row.bytes)}
                      </TableCell>
                      <TableCell className="text-white/70">
                        {row.transactions === undefined ? "—" : showCount(row.transactions)}
                      </TableCell>
                      <TableCell className="text-white/70">
                        {row.resident === undefined ? "—" : showCount(row.resident)}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {row.checkpoint_bytes === undefined
                          ? "—"
                          : showBytes(row.checkpoint_bytes)}
                      </TableCell>
                    </TableRow>
                  ))}
              </TableBody>
            </Table>
          </div>

          <p className="mt-4 max-w-2xl text-sm leading-relaxed text-muted-foreground">
            only worlds this node currently holds open are measured. a world
            nobody has opened has no process to ask, and reading the directory
            would report files this node may not own.
          </p>

          <details className="mt-10 rounded-lg border border-border">
            <summary className="cursor-pointer px-4 py-3 text-sm text-muted-foreground transition-colors hover:text-white">
              the lua this page ran
            </summary>
            <div className="relative border-t border-border">
              <div className="absolute right-2 top-2">
                <CopyButton value={CHUNK} />
              </div>
              <pre className="overflow-x-auto p-4 font-mono text-xs leading-relaxed text-white/80">
                {CHUNK}
              </pre>
            </div>
          </details>
        </>
      )}
    </>
  )
}

function Figure({
  label,
  value,
  note,
}: {
  label: string
  value: string
  note: string
}) {
  return (
    <div className="bg-background p-5">
      <p className="mb-3 text-xs text-muted-foreground">{label}</p>
      <p className="font-mono text-2xl text-white">{value}</p>
      <p className="mt-1.5 text-xs text-muted-foreground">{note}</p>
    </div>
  )
}


