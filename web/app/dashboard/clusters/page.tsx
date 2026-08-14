"use client"

import { CircleDashed, Server, Trash2, TriangleAlert } from "lucide-react"
import { useEffect, useState } from "react"

import { OpenCluster } from "@/components/dashboard/open-cluster"
import { Nothing, PageHead } from "@/components/dashboard/page-shell"
import { WorldAvatar } from "@/components/ui/world-avatar"
import { type Cluster, forgetCluster, look } from "@/lib/blazie"
import { cn } from "@/lib/utils"

import { useCluster } from "../cluster"

/**
 * Managing the clusters you hold — opening another, and taking one away.
 *
 * Not in the nav, and reached from the switcher instead. A cluster is what the
 * console is pointed at rather than a thing it shows you, so this is a place
 * you go when you are thinking about clusters, not one of the places you look
 * at your data. Holding none never lands here at all: that is the onboarding
 * screen, which is shown instead of the console rather than routed to.
 */

export default function Clusters() {
  const { clusters, cluster, chooseCluster, refresh } = useCluster()

  /**
   * A machine takes a few minutes to become a cluster, so this asks until one of
   * them stops saying it is opening. Polling rather than waiting on the request
   * that made it: that request returns as soon as UpCloud accepts, because one
   * that waited for cloud-init would time out somewhere in the middle and leave
   * the console unable to say what happened to a machine that was coming up fine.
   */
  useEffect(() => {
    if (!clusters.some((c) => c.state === "opening")) return

    const timer = setInterval(() => {
      void look().then(refresh).catch(() => undefined)
    }, 15_000)

    return () => clearInterval(timer)
  }, [clusters, refresh])

  return (
    <>
      <PageHead title="clusters">
        a cluster is a running blazie, holding worlds. opening one makes a machine
        and puts it behind a tunnel — it listens on nothing, and the only thing
        that can reach it is this console.
      </PageHead>

      <OpenCluster className="mb-12" />

      {clusters.length === 0 ? (
        <Nothing icon={Server} title="none yet">
          open one above. it takes a few minutes — a machine is made, blazie is
          installed on it, and it dials out to a tunnel. nothing about it is
          reachable from the internet.
        </Nothing>
      ) : (
        <div className="grid gap-px overflow-hidden rounded-lg border border-border bg-border sm:grid-cols-2">
          {clusters.map((held) => (
            <Card
              key={held.id}
              cluster={held}
              chosen={held.id === cluster?.id}
              onChoose={() => chooseCluster(held.id)}
              onForget={async (destroy) => {
                await forgetCluster(held.id, destroy)
                await refresh()
              }}
            />
          ))}
        </div>
      )}
    </>
  )
}

function Card({
  cluster,
  chosen,
  onChoose,
  onForget,
}: {
  cluster: Cluster
  chosen: boolean
  onChoose: () => void
  onForget: (destroy: boolean) => Promise<void>
}) {
  const [asking, setAsking] = useState(false)

  return (
    <div className={cn("bg-background p-5", chosen && "bg-raised/40")}>
      <button type="button" onClick={onChoose} className="flex w-full items-center gap-3 text-left">
        <WorldAvatar world={cluster.name} size="lg" live={chosen} />

        <span className="min-w-0 flex-1">
          <span className="block truncate text-base font-medium tracking-tight text-white">
            {cluster.name}
          </span>
          <span className="font-mono block truncate text-xs text-muted-foreground">
            {cluster.address.replace(/^https:\/\//, "")}
          </span>
          {cluster.host ? (
            <span className="font-mono mt-1 block text-[10px] text-muted-foreground">
              {cluster.host.plan} · {cluster.host.zone}
            </span>
          ) : null}
        </span>
      </button>

      <div className="mt-4 flex items-center justify-between gap-3">
        <State cluster={cluster} />

        {asking ? (
          <span className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => void onForget(true)}
              className="rounded-md border border-flame/40 px-2.5 py-1 text-xs text-flame transition-colors hover:bg-flame/10"
            >
              destroy it
            </button>
            <button
              type="button"
              onClick={() => void onForget(false)}
              className="rounded-md border border-border px-2.5 py-1 text-xs text-muted-foreground transition-colors hover:text-white"
            >
              just forget
            </button>
            <button
              type="button"
              onClick={() => setAsking(false)}
              className="text-xs text-muted-foreground transition-colors hover:text-white"
            >
              cancel
            </button>
          </span>
        ) : (
          <button
            type="button"
            onClick={() => setAsking(true)}
            className="inline-flex items-center gap-1.5 text-xs text-muted-foreground transition-colors hover:text-flame"
          >
            <Trash2 className="size-3.5" />
            remove
          </button>
        )}
      </div>

      {/* Two different acts, asked separately. Forgetting drops the record and
          leaves the machine running; destroying takes the machine and every
          world on it. A console where those are one button is a console that
          deletes a database by mis-click. */}
      {/* What it said on the way, oldest first. The sequence up to a failure is
          most of the diagnosis, and it is the thing a machine with no password
          and no key cannot be asked for afterwards. */}
      {cluster.said && cluster.said.length > 1 ? (
        <ol className="font-mono mt-4 space-y-1 text-[11px] text-muted-foreground">
          {cluster.said.map((one, at) => (
            <li key={`${one.step}-${one.at}`} className="flex gap-2">
              <span className="w-4 shrink-0 text-right text-white/25">{at + 1}</span>
              <span className={one.step === "failed" ? "text-flame" : "text-white/70"}>
                {one.step}
              </span>
              <span className="ml-auto shrink-0 tabular-nums">
                {new Date(one.at).toLocaleTimeString()}
              </span>
            </li>
          ))}
        </ol>
      ) : null}

      {cluster.saying?.step === "failed" && cluster.saying.detail ? (
        <pre className="font-mono mt-4 max-h-40 overflow-auto whitespace-pre-wrap rounded-md border border-flame/30 bg-flame/5 p-3 text-[11px] leading-relaxed text-flame">
          {cluster.saying.detail}
        </pre>
      ) : cluster.state === "unreachable" && cluster.refusal ? (
        <p className="font-mono mt-4 rounded-md border border-flame/30 bg-flame/5 p-3 text-[11px] leading-relaxed text-flame">
          {cluster.refusal.repair}
        </p>
      ) : null}
    </div>
  )
}

/**
 * How far along, said by the machine rather than guessed from silence.
 *
 * A machine reports each step as it reaches it, so "opening" can say WHERE it
 * is. Before this, one answer — nothing at that address — covered "still
 * installing", "cloud-init died" and "the tunnel never dialled", which are three
 * states needing three different responses.
 */
const STEPS = ["booted", "packages", "docker", "pulled", "serving", "tunnelled"]

function State({ cluster }: { cluster: Cluster }) {
  if (cluster.state === "open") {
    return <span className="font-mono text-xs text-spark">open</span>
  }

  const step = cluster.saying?.step
  const reached = step ? STEPS.indexOf(step) : -1

  return (
    <span
      className={cn(
        "font-mono inline-flex items-center gap-1.5 text-xs",
        cluster.state === "opening" ? "text-ember" : "text-flame",
      )}
    >
      {cluster.state === "opening" ? (
        <>
          <CircleDashed className="size-3" />
          {reached >= 0 ? `${step} — ${reached + 1}/${STEPS.length}` : "opening"}
        </>
      ) : (
        <>
          <TriangleAlert className="size-3" />
          {step === "failed" ? "failed while installing" : "unreachable"}
        </>
      )}
    </span>
  )
}
