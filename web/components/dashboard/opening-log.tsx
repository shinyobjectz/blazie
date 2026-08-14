"use client"

import { useEffect, useRef } from "react"

import type { Cluster } from "@/lib/blazie"
import { cn } from "@/lib/utils"

/**
 * What is happening, in the shape of a log, while a cluster opens.
 *
 * The steps beside this say how far along it is. This says that something is
 * still going on — which is a different question, and the one somebody asks
 * during the first minute, when the machine does not exist yet and therefore
 * cannot report anything about itself. A step with a spinner on it for ninety
 * seconds and a log that is still printing are the same state and do not feel
 * like it.
 *
 * ## Nothing here comes off the machine
 *
 * Every line is composed here out of things the control plane already knows:
 * what it asked the vendors for, what the vendor says the machine is doing, and
 * which of a closed set of steps have been reported. None of it is machine
 * output.
 *
 * That is deliberate rather than incidental. The obvious way to build this is
 * to tail cloud-init's log, and cloud-init's log is written by a script holding
 * the tunnel token, the key everything is sealed under and the credentials for
 * the backup bucket. A viewer would see them. The machine now blanks its own
 * secrets before it says anything, but the rule worth keeping is the stronger
 * one: this pane renders what we constructed, so there is no path from a
 * machine's stdout to a screen.
 */

type Line = {
  at: number
  says: string
  /** `done` has happened, `doing` is happening, `failed` stopped. */
  how: "done" | "doing" | "failed"
}

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

/** What the vendor's own word for a state means, in ours. */
const VENDOR: Record<string, string> = {
  maintenance: "cloning disk image (50 GB)",
  started: "machine started",
  stopped: "machine stopped",
  error: "vendor reported an error",
}

/** What each reported step was actually doing to get there. */
const AFTER: Record<string, string> = {
  booted: "cloud-init running",
  packages: "apt-get install docker.io ufw curl apparmor",
  docker: "systemctl start docker · ufw default deny incoming",
  pulled: "docker pull ghcr.io/shinyobjectz/blazie:latest",
  serving: "waiting for blazie to answer on 127.0.0.1:4000",
  tunnelled: "cloudflared registered · closing the firewall",
}

export function OpeningLog({ cluster, tick }: { cluster: Cluster; tick: number }) {
  const lines = compose(cluster)
  const bottom = useRef<HTMLDivElement>(null)

  // Follows, the way a terminal does. Only while it is still going: yanking the
  // view down under somebody reading a finished log is worse than not following.
  useEffect(() => {
    if (lines.some((one) => one.how === "doing")) {
      bottom.current?.scrollIntoView({ behavior: "smooth", block: "end" })
    }
  }, [lines])

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-black/40">
      <div className="flex items-center gap-1.5 border-b border-border px-3 py-2">
        <span className="size-2 rounded-full bg-flame/60" />
        <span className="size-2 rounded-full bg-ember/60" />
        <span className="size-2 rounded-full bg-spark/60" />
        <span className="font-mono ml-2 text-[10px] text-muted-foreground">
          opening {cluster.name}
        </span>
      </div>

      <div className="font-mono max-h-[22rem] overflow-y-auto px-3 py-3 text-[11px] leading-relaxed">
        {lines.map((line, at) => (
          <p key={`${line.says}-${at}`} className="flex gap-2">
            <span
              className={cn(
                "w-3 shrink-0",
                line.how === "done" && "text-spark",
                line.how === "doing" && "text-ember",
                line.how === "failed" && "text-flame",
              )}
            >
              {line.how === "done"
                ? "✓"
                : line.how === "failed"
                  ? "✗"
                  : SPINNER[tick % SPINNER.length]}
            </span>

            <span
              className={cn(
                "min-w-0 flex-1 break-words",
                line.how === "done" && "text-white/60",
                line.how === "doing" && "text-white",
                line.how === "failed" && "text-flame",
              )}
            >
              {line.says}
            </span>

            <span className="shrink-0 tabular-nums text-white/25">
              {stamp(line.at)}
            </span>
          </p>
        ))}
        <div ref={bottom} />
      </div>
    </div>
  )
}

/**
 * The lines, from what is known rather than from anything that was printed.
 *
 * Written oldest first with the one in progress last, so it reads as a log even
 * though it is derived from a record that has no order of its own.
 */
function compose(cluster: Cluster): Line[] {
  const began = Date.parse(cluster.opened)
  const lines: Line[] = []
  const said = cluster.said ?? []
  const failed = cluster.saying?.step === "failed"

  // What the control plane did before there was a machine to talk about. These
  // are already true by the time this screen can render — opening does them and
  // only then answers.
  lines.push({ at: began, says: `created tunnel blazie-${cluster.name}`, how: "done" })
  lines.push({ at: began, says: `pointed ${host(cluster)} at it`, how: "done" })

  if (cluster.host) {
    lines.push({
      at: began,
      says: `asked upcloud for ${cluster.host.plan} in ${cluster.host.zone}`,
      how: "done",
    })
  }

  // The vendor's own account, which is the only thing there is to say until the
  // machine boots and starts reporting for itself.
  if (cluster.host?.state && said.length === 0) {
    const state = cluster.host.state
    lines.push({
      at: began,
      says: VENDOR[state] ?? `machine is ${state}`,
      how: state === "maintenance" ? "doing" : "done",
    })
  }

  for (const one of said) {
    if (one.step === "failed") continue
    lines.push({ at: Date.parse(one.at), says: AFTER[one.step] ?? one.step, how: "done" })
  }

  if (failed) {
    lines.push({
      at: Date.parse(cluster.saying!.at),
      says: "stopped — the detail is below",
      how: "failed",
    })
  } else if (cluster.state === "open") {
    lines.push({ at: Date.now(), says: "cluster answering · claimed `main`", how: "done" })
  } else {
    // Whatever comes next after the last thing reported. Always exactly one, so
    // there is always exactly one thing spinning.
    const last = said.at(-1)?.step
    const next = last ? NEXT[last] : cluster.host?.state ? null : "waiting for the machine to boot"

    if (next) lines.push({ at: Date.now(), says: next, how: "doing" })
  }

  return lines
}

/** What is being waited on, once a step has been reported. */
const NEXT: Record<string, string> = {
  booted: "installing packages",
  packages: "starting docker",
  docker: "pulling the blazie image",
  pulled: "starting blazie",
  serving: "connecting the tunnel to cloudflare",
  tunnelled: "waiting for the console to reach it",
}

function host(cluster: Cluster): string {
  return cluster.address.replace(/^https:\/\//, "") || `${cluster.name}.blazie.dev`
}

function stamp(at: number): string {
  return new Date(at).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  })
}
