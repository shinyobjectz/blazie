"use client"

import { CircleDashed, Server, Trash2, TriangleAlert } from "lucide-react"
import { useCallback, useEffect, useState } from "react"

import { Nothing, PageHead } from "@/components/dashboard/page-shell"
import { RefusalNote } from "@/components/ui/refusal-note"
import { WorldAvatar } from "@/components/ui/world-avatar"
import {
  type Cluster,
  forgetCluster,
  look,
  openCluster,
} from "@/lib/blazie"
import { cn } from "@/lib/utils"

import { useCluster } from "../cluster"

/**
 * The clusters you hold, and opening one.
 *
 * This is the only page that works before you have anything, which is what it
 * is for. Everything else in the console asks a cluster a question.
 */

const ZONES = [
  { id: "uk-lon1", label: "London" },
  { id: "de-fra1", label: "Frankfurt" },
  { id: "us-nyc1", label: "New York" },
  { id: "sg-sin1", label: "Singapore" },
]

const PLANS = [
  { id: "1xCPU-2GB", label: "1 CPU · 2 GB", monthly: 9 },
  { id: "2xCPU-4GB", label: "2 CPU · 4 GB", monthly: 18 },
  { id: "4xCPU-8GB", label: "4 CPU · 8 GB", monthly: 44 },
]

export default function Clusters() {
  const { clusters, cluster, chooseCluster, who, refresh } = useCluster()

  const [name, setName] = useState("")
  const [zone, setZone] = useState(ZONES[0].id)
  const [plan, setPlan] = useState(PLANS[0].id)
  const [opening, setOpening] = useState(false)
  const [error, setError] = useState<unknown>(null)

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

  const open = useCallback(
    async (event: React.FormEvent) => {
      event.preventDefault()
      if (opening || !name.trim()) return

      setOpening(true)
      setError(null)

      try {
        const { cluster: made } = await openCluster({ name: name.trim(), zone, plan })
        setName("")
        await refresh()
        chooseCluster(made.id)
      } catch (thrown) {
        setError(thrown)
      } finally {
        setOpening(false)
      }
    },
    [name, zone, plan, opening, refresh, chooseCluster],
  )

  return (
    <>
      <PageHead title="clusters">
        a cluster is a running blazie, holding worlds. opening one makes a machine
        and puts it behind a tunnel — it listens on nothing, and the only thing
        that can reach it is this console.
      </PageHead>

      {!who.can.open_clusters ? (
        <p className="font-mono mb-10 max-w-2xl rounded-lg border border-ember/30 bg-ember/5 p-4 text-xs leading-relaxed text-ember">
          this deployment cannot open clusters yet — it has no credentials to
          make a machine with. set UPCLOUD_TOKEN, CLOUDFLARE_API_TOKEN,
          CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_ZONE_ID with `wrangler pages
          secret put`. clusters already open still work.
        </p>
      ) : (
        <form onSubmit={open} className="mb-12 flex flex-wrap items-end gap-4">
          <label className="block">
            <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
              name
            </span>
            <input
              value={name}
              onChange={(event) => setName(event.target.value)}
              placeholder="atlas"
              className="font-mono w-52 rounded-md border border-border bg-muted px-3 py-2 text-sm text-white placeholder:text-muted-foreground focus:border-white/30 focus:outline-none"
            />
          </label>

          <Choice label="where" value={zone} onChange={setZone} options={ZONES} />

          <Choice
            label="size"
            value={plan}
            onChange={setPlan}
            options={PLANS.map((p) => ({ id: p.id, label: `${p.label} · $${p.monthly}/mo` }))}
          />

          <button
            type="submit"
            disabled={opening || !name.trim()}
            className="inline-flex items-center gap-2 rounded-md bg-white px-5 py-2 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02] disabled:opacity-40"
          >
            <Server className="size-4" />
            {opening ? "opening…" : "open"}
          </button>
        </form>
      )}

      {error ? <RefusalNote error={error} className="mb-10" /> : null}

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

function Choice({
  label,
  value,
  onChange,
  options,
}: {
  label: string
  value: string
  onChange: (next: string) => void
  options: { id: string; label: string }[]
}) {
  return (
    <label className="block">
      <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
        {label}
      </span>
      <select
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="font-mono rounded-md border border-border bg-muted px-3 py-2 text-sm text-white focus:border-white/30 focus:outline-none"
      >
        {options.map((option) => (
          <option key={option.id} value={option.id} className="bg-muted">
            {option.label}
          </option>
        ))}
      </select>
    </label>
  )
}
