"use client"

import { Bot, ChevronRight } from "lucide-react"
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
import { showCount, showWhen } from "@/lib/format"
import { cn } from "@/lib/utils"

import { useCluster } from "../cluster"
import { useLua } from "../use-lua"

/**
 * The agents in this world, and what one of them actually did.
 *
 * An agent is a field declared as produced — `asks` says who to ask, `watches`
 * says what it attends to — so finding them is a query rather than a registry.
 * That is also why this page can exist at all without an endpoint of its own:
 * everything here is the same `run` every other page uses.
 *
 * The trace at the bottom is the point. Ask any prompt library which constraints
 * an output passed, or what the agent knew when it decided, and the answer is a
 * log somebody remembered to keep. Here it is facts, so it is a query.
 */

const AGENTS = `local rows = {}
for a in each { asks = true } do
  rows[#rows + 1] = {
    id = a.id,
    asks = a.asks,
    produces = a.produces,
    answers = a.answers,
    ran_at = a.ran_at,
    tries = a.tries,
    failed = a.failed,
    budget = a.budget,
    tokens_in = a.tokens_in,
    tokens_out = a.tokens_out,
  }
end
return rows`

type Agent = {
  id: string
  asks?: string
  produces?: string
  answers?: string
  ran_at?: number
  tries?: number
  failed?: string
  budget?: number
  tokens_in?: number
  tokens_out?: number
}

export default function Agents() {
  const { world } = useCluster()
  const asked = useLua<Agent[]>(AGENTS)
  const [tracing, setTracing] = useState<string | null>(null)

  const agents = useMemo(() => (Array.isArray(asked.value) ? asked.value : []), [asked.value])

  if (!world) {
    return (
      <>
        <PageHead title="agents">nothing to show until there is a world.</PageHead>
        <Nothing icon={Bot} title="no world chosen" />
      </>
    )
  }

  return (
    <>
      <PageHead title="agents">
        an agent is a field declared as produced — what it watches, who it asks,
        and what must be true of the answer. finding them is a query, because
        the declaration is the registry.
      </PageHead>

      <Asked
        of={agents}
        error={asked.error}
        loading={asked.running}
        retry={asked.retry}
        empty={
          <Nothing icon={Bot} title="none declared here">
            an agent arrives by being written. declare a field with{" "}
            <code className="font-mono text-white/80">asks</code>,{" "}
            <code className="font-mono text-white/80">watches</code> and{" "}
            <code className="font-mono text-white/80">produces</code> and it
            appears — nothing has to be told.
          </Nothing>
        }
      >
        {(here) => (
          <>
            <div className="overflow-x-auto rounded-lg border border-border">
              <Table className="font-mono text-xs">
                <TableHeader>
                  <TableRow className="hover:bg-transparent">
                    {["field", "asks", "produces", "last run", "tries", "spent", ""].map((head) => (
                      <TableHead key={head} className="text-muted-foreground">
                        {head}
                      </TableHead>
                    ))}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {here.map((agent) => (
                    <TableRow key={agent.id}>
                      <TableCell className="text-white/85">{agent.id}</TableCell>
                      <TableCell className="text-white/60">{agent.asks ?? "—"}</TableCell>
                      <TableCell className="text-white/60">{agent.produces ?? "—"}</TableCell>
                      <TableCell className="text-muted-foreground">
                        {typeof agent.ran_at === "number" ? showWhen(agent.ran_at) : "never"}
                      </TableCell>
                      <TableCell className={agent.tries && agent.tries > 1 ? "text-ember" : "text-muted-foreground"}>
                        {agent.tries ?? "—"}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        <Spent agent={agent} />
                      </TableCell>
                      <TableCell>
                        <button
                          type="button"
                          onClick={() => setTracing(tracing === agent.id ? null : agent.id)}
                          className="inline-flex items-center gap-1 text-xs text-muted-foreground transition-colors hover:text-white"
                        >
                          trace
                          <ChevronRight
                            className={cn(
                              "size-3 transition-transform",
                              tracing === agent.id && "rotate-90",
                            )}
                          />
                        </button>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>

            {here.some((a) => a.failed) ? (
              <section className="mt-8">
                <h2 className="mb-2 text-lg font-medium tracking-tight text-white">
                  what went wrong
                </h2>
                <p className="mb-4 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                  a run that failed still ran, so the reason is a fact with a
                  transaction. history, not an alert to dismiss.
                </p>
                <div className="space-y-2">
                  {here
                    .filter((a) => a.failed)
                    .map((a) => (
                      <div key={a.id} className="rounded-lg border border-flame/30 bg-flame/5 px-4 py-3">
                        <p className="font-mono text-xs text-flame">{a.id}</p>
                        <p className="font-mono mt-1.5 text-xs leading-relaxed text-white/80">
                          {a.failed}
                        </p>
                      </div>
                    ))}
                </div>
              </section>
            ) : null}

            {tracing ? <Trace field={tracing} /> : null}

            <details className="mt-10 rounded-lg border border-border">
              <summary className="cursor-pointer px-4 py-3 text-sm text-muted-foreground transition-colors hover:text-white">
                the lua this page ran
              </summary>
              <div className="relative border-t border-border">
                <div className="absolute right-2 top-2">
                  <CopyButton value={AGENTS} />
                </div>
                <pre className="overflow-x-auto p-4 font-mono text-xs leading-relaxed text-white/80">
                  {AGENTS}
                </pre>
              </div>
            </details>
          </>
        )}
      </Asked>
    </>
  )
}

/**
 * One answer, explained.
 *
 * What was produced, which requirements it passed, how many attempts it took,
 * and what tools were called. Every line is a fact rather than a log line —
 * which is why this page needed no instrumentation to exist.
 */
function Trace({ field }: { field: string }) {
  const source = `local rows = {}
for e in each { ${field} = true } do
  rows[#rows + 1] = { id = e.id, answer = e.${field}, satisfied = e.satisfied }
end
return rows`

  const asked = useLua<{ id: string; answer: unknown; satisfied?: string }[]>(source)
  const rows = Array.isArray(asked.value) ? asked.value : []

  return (
    <section className="mt-8 rounded-lg border border-border p-5">
      <h2 className="mb-2 text-lg font-medium tracking-tight text-white">
        what <span className="font-mono text-flame">{field}</span> decided
      </h2>
      <p className="mb-5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        every answer it produced, and which requirement it satisfied. ask a
        prompt library the same question and the answer is a log somebody
        remembered to keep.
      </p>

      <Asked
        of={rows}
        error={asked.error}
        loading={asked.running}
        retry={asked.retry}
        rows={3}
        empty={
          <p className="text-sm text-muted-foreground">
            it has not answered anything yet.
          </p>
        }
      >
        {(here) => (
          <div className="overflow-x-auto rounded-lg border border-border">
            <Table className="font-mono text-xs">
              <TableHeader>
                <TableRow className="hover:bg-transparent">
                  {["entity", "answered", "satisfied"].map((head) => (
                    <TableHead key={head} className="text-muted-foreground">
                      {head}
                    </TableHead>
                  ))}
                </TableRow>
              </TableHeader>
              <TableBody>
                {here.map((row) => (
                  <TableRow key={row.id}>
                    <TableCell className="text-white/85">{row.id}</TableCell>
                    <TableCell className="text-spark">{String(row.answer)}</TableCell>
                    <TableCell className={row.satisfied ? "text-white/70" : "text-flame/70"}>
                      {row.satisfied ?? "nothing checked it"}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Asked>
    </section>
  )
}

function Spent({ agent }: { agent: Agent }) {
  const used = (agent.tokens_in ?? 0) + (agent.tokens_out ?? 0)
  if (used === 0) return <span className="text-white/20">—</span>

  const over = typeof agent.budget === "number" && used >= agent.budget

  return (
    <span className={over ? "text-flame" : undefined}>
      {showCount(used)}
      {typeof agent.budget === "number" ? ` / ${showCount(agent.budget)}` : ""}
    </span>
  )
}
