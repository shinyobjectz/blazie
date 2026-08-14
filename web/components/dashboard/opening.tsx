"use client"

import { Check, CircleDashed, TriangleAlert } from "lucide-react"
import { useEffect, useState } from "react"

import type { Cluster } from "@/lib/blazie"
import { cn } from "@/lib/utils"

/**
 * A machine becoming a cluster, while it happens.
 *
 * The steps are the machine's own, reported as it reaches them, so this is an
 * account rather than an animation pretending to be one. That distinction is
 * the whole reason it can say WHERE it stopped: a bar that fills on a timer
 * says the same thing whether the pull is slow or cloud-init died three minutes
 * ago, which is exactly the ambiguity the reporting exists to remove.
 *
 * Each step carries roughly how long it takes, because "is this stuck" is the
 * question somebody is actually asking, and it cannot be answered by a spinner.
 */

const STEPS = [
  // Not one of the machine's steps — the machine does not exist yet to report
  // it. UpCloud spends a minute or so cloning a disk before anything boots, and
  // with no row for it the first machine step sat spinning through a phase that
  // was not it: "machine booted" for ninety seconds, on a machine that had not.
  // Nothing reported is exactly what this phase looks like, so it is the row
  // that is current until the first report arrives.
  { id: "made", says: "making the machine", takes: "a minute or so" },
  { id: "booted", says: "machine booted", takes: "a few seconds" },
  { id: "packages", says: "installing packages", takes: "about a minute" },
  { id: "docker", says: "starting docker", takes: "a few seconds" },
  { id: "pulled", says: "pulling blazie", takes: "under a minute" },
  { id: "serving", says: "blazie answering", takes: "a few seconds" },
  { id: "tunnelled", says: "tunnel connected", takes: "under a minute" },
] as const

export function Opening({ cluster }: { cluster: Cluster }) {
  const since = useElapsed(cluster.opened)

  const step = cluster.saying?.step
  const failed = step === "failed"
  const reached = failed ? -1 : STEPS.findIndex((s) => s.id === step)
  const done = cluster.state === "open"

  return (
    <div>
      <div className="mb-8 flex items-baseline gap-3">
        <h2 className="text-xl font-medium tracking-tight text-white">
          {done ? "your cluster is up" : failed ? "it stopped" : `opening ${cluster.name}`}
        </h2>
        <span className="font-mono text-xs tabular-nums text-muted-foreground">
          {minutes(since)}
        </span>
      </div>

      <ol className="space-y-0">
        {STEPS.map((one, at) => {
          const passed = done || at <= reached
          const now = !done && !failed && at === reached + 1
          const stopped = failed && at === reached + 1

          return (
            <li key={one.id} className="flex gap-4">
              {/* The rail: a dot per step, joined by a line that fills as far as
                  the machine has actually got. */}
              <span className="flex flex-col items-center">
                <span
                  className={cn(
                    "flex size-5 shrink-0 items-center justify-center rounded-full border transition-colors duration-500",
                    passed && "border-spark bg-spark/15 text-spark",
                    now && "border-ember bg-ember/10 text-ember",
                    stopped && "border-flame bg-flame/10 text-flame",
                    !passed && !now && !stopped && "border-border text-muted-foreground",
                  )}
                >
                  {passed ? (
                    <Check className="size-3" />
                  ) : stopped ? (
                    <TriangleAlert className="size-3" />
                  ) : now ? (
                    <CircleDashed className="size-3 animate-spin [animation-duration:2.4s]" />
                  ) : (
                    <span className="size-1 rounded-full bg-current" />
                  )}
                </span>

                {at < STEPS.length - 1 ? (
                  <span
                    className={cn(
                      "w-px flex-1 transition-colors duration-700",
                      passed ? "bg-spark/40" : "bg-border",
                    )}
                  />
                ) : null}
              </span>

              <span className={cn("flex-1 pb-6", at === STEPS.length - 1 && "pb-0")}>
                <span
                  className={cn(
                    "font-mono block text-sm transition-colors duration-500",
                    passed && "text-white",
                    now && "text-ember",
                    stopped && "text-flame",
                    !passed && !now && !stopped && "text-muted-foreground/50",
                  )}
                >
                  {one.says}
                </span>
                <span className="font-mono block text-[11px] text-muted-foreground">
                  {passed ? "done" : now ? `usually ${one.takes}` : one.takes}
                </span>
              </span>
            </li>
          )
        })}
      </ol>

      {cluster.saying?.step === "failed" && cluster.saying.detail ? (
        <pre className="font-mono mt-8 max-h-48 overflow-auto whitespace-pre-wrap rounded-md border border-flame/30 bg-flame/5 p-4 text-[11px] leading-relaxed text-flame">
          {cluster.saying.detail}
        </pre>
      ) : null}

      {!done && !failed ? (
        <p className="mt-8 max-w-lg text-sm leading-relaxed text-muted-foreground">
          this takes two or three minutes altogether. you can leave this page —
          the machine reports each step whether or not anybody is watching, and
          it will be here when you come back.
        </p>
      ) : null}
    </div>
  )
}

/** Seconds since the cluster was opened, ticking. */
function useElapsed(opened: string): number {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1_000)
    return () => clearInterval(timer)
  }, [])

  return Math.max(0, Math.floor((now - Date.parse(opened)) / 1000))
}

function minutes(seconds: number): string {
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  return m > 0 ? `${m}m ${String(s).padStart(2, "0")}s` : `${s}s`
}
