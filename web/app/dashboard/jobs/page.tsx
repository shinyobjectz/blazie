"use client"

import { Clock } from "lucide-react"

import { Asked, Nothing, PageHead } from "@/components/dashboard/page-shell"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import type { Fact } from "@/lib/blazie"

import { latest, useAsk } from "../use-ask"

/**
 * Jobs: the only thing a schedule can attach to.
 *
 * A job is the mirror of a formula and the asymmetry is the point — a formula
 * can be thrown away and rebuilt, so storing its answer is a performance
 * choice; a job's answer happened once and cannot be reproduced, so it is
 * written. Which means everything on this page is already in the ledger, and
 * this is a query rather than a scheduler UI.
 *
 * There is no run-now button, and that absence is deliberate: running a job is
 * reaching outside the fence, and nothing on a static page holds the authority
 * to do that. The node's runner ticks it.
 */
export default function Jobs() {
  const asked = useAsk({})

  return (
    <>
      <PageHead title="jobs">
        declared work that needs the outside world — fetching, calling a hosted
        model, an agent taking a turn. a job&apos;s answer happened once and
        cannot be rebuilt, so it is written down. nothing here is a queue.
      </PageHead>

      <Asked
        of={asked.facts}
        error={asked.error}
        loading={asked.loading}
        retry={asked.retry}
        empty={<NoJobs />}
      >
        {(facts) => {
          const declared = describe(facts)
          if (declared.length === 0) return <NoJobs />

          return (
            <>
              <div className="overflow-x-auto rounded-lg border border-border">
                <Table className="font-mono text-xs">
                  <TableHeader>
                    <TableRow className="hover:bg-transparent">
                      {["job", "cadence", "last ran", "runs", "failures"].map(
                        (head) => (
                          <TableHead key={head} className="text-muted-foreground">
                            {head}
                          </TableHead>
                        ),
                      )}
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {declared.map((job) => (
                      <TableRow key={job.id}>
                        <TableCell className="text-white/85">{job.id}</TableCell>
                        <TableCell>
                          {job.every === undefined ? (
                            <span
                              className="text-muted-foreground"
                              title="declared without `every` — it runs when something ticks it, never on a clock"
                            >
                              on demand
                            </span>
                          ) : (
                            <span className="text-white/80">
                              every {job.every}s
                            </span>
                          )}
                        </TableCell>
                        <TableCell>
                          {job.ranAt === undefined ? (
                            <span className="text-muted-foreground">never</span>
                          ) : (
                            <span className="text-spark" title={String(job.ranAt)}>
                              {when(job.ranAt)}
                            </span>
                          )}
                        </TableCell>
                        <TableCell className="text-muted-foreground">
                          {job.runs}
                        </TableCell>
                        <TableCell>
                          {job.failures === 0 ? (
                            <span className="text-muted-foreground">none</span>
                          ) : (
                            <span className="text-flame">{job.failures}</span>
                          )}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>

              {declared.some((job) => job.lastFailure) ? (
                <section className="mt-10">
                  <h2 className="mb-2 text-lg font-medium tracking-tight text-white">
                    what went wrong
                  </h2>
                  <p className="mb-5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                    a job that failed still ran, so the reason is a fact with a
                    transaction like any other. it is history, not an alert to
                    dismiss.
                  </p>
                  <div className="space-y-2">
                    {declared
                      .filter((job) => job.lastFailure)
                      .map((job) => (
                        <div
                          key={job.id}
                          className="rounded-lg border border-flame/30 bg-flame/5 px-4 py-3"
                        >
                          <p className="font-mono text-xs text-flame">{job.id}</p>
                          <p className="font-mono mt-1.5 text-xs leading-relaxed text-white/80">
                            {job.lastFailure}
                          </p>
                        </div>
                      ))}
                  </div>
                </section>
              ) : null}
            </>
          )
        }}
      </Asked>
    </>
  )
}

function NoJobs() {
  return (
    <Nothing icon={Clock} title="no jobs declared">
      a job is declared by writing{" "}
      <code className="font-mono text-white/80">{`{id, is, job}`}</code>, and a
      cadence by writing{" "}
      <code className="font-mono text-white/80">{`{id, every, seconds}`}</code>.
      the node&apos;s own vitals are declared exactly that way — observability is
      a job here, because reading the clock is reaching outside.
    </Nothing>
  )
}

type Declared = {
  id: string
  every?: number
  ranAt?: number
  runs: number
  failures: number
  lastFailure?: string
}

function describe(facts: Fact[]): Declared[] {
  const ids = new Set(
    facts
      .filter((f) => f.attribute === "is" && f.value === "job")
      .map((f) => String(f.id)),
  )

  const every = latest(facts.filter((f) => f.attribute === "every"))
  const ran = facts.filter((f) => f.attribute === "ran_at")
  const failed = facts.filter((f) => f.attribute === "failed")
  const lastRan = latest(ran)
  const lastFailed = latest(failed)

  return [...ids].sort().map((id) => ({
    id,
    every: numeric(every.get(id)?.value),
    ranAt: numeric(lastRan.get(id)?.value),
    // Every run is its own fact, so counting them is counting rows — there is
    // no counter anywhere that could disagree with the history.
    runs: ran.filter((f) => String(f.id) === id).length,
    failures: failed.filter((f) => String(f.id) === id).length,
    lastFailure: text(lastFailed.get(id)?.value),
  }))
}

function numeric(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined
}

function text(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined
}

/** `ran_at` is unix seconds, written by the node when the job ran. */
function when(seconds: number): string {
  const ago = Math.floor(Date.now() / 1000) - seconds
  if (ago < 0) return new Date(seconds * 1000).toLocaleString()
  if (ago < 60) return `${ago}s ago`
  if (ago < 3600) return `${Math.floor(ago / 60)}m ago`
  if (ago < 86400) return `${Math.floor(ago / 3600)}h ago`
  return `${Math.floor(ago / 86400)}d ago`
}
