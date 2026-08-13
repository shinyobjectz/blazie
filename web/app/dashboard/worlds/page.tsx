"use client"

import { Check, Database, Plus } from "lucide-react"
import { useCallback, useEffect, useState } from "react"

import { Nothing, PageHead } from "@/components/dashboard/page-shell"
import { CopyButton } from "@/components/ui/copy-button"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Skeleton } from "@/components/ui/skeleton"
import { WorldOrbit } from "@/components/ui/world-avatar"
import { claim, run } from "@/lib/blazie"
import { showCount } from "@/lib/format"
import { cn } from "@/lib/utils"

import { useCluster } from "../cluster"

/**
 * Your worlds, what is in each of them, and how to make one.
 *
 * A world is where data lives — the thing another backend would call a
 * database. Making one is the operation the console could not perform at all
 * until recently: every request is checked against the worlds a caller may
 * name, so naming a new one was refused before it could be created, and a
 * world existed only when somebody with shell access wrote a grant by hand.
 *
 * The list used to be the names and nothing else, which is the least a list of
 * databases can say. What is in each one is not held anywhere to look up, so
 * this asks — one chunk of Lua per world, each on its own, because they are
 * separate worlds and one that refuses must not blank the others.
 */

/**
 * What is in a world, counted where the data is.
 *
 * `each {}` walks the world, which is the same cost the data page pays and the
 * same cost anybody would pay writing this themselves — there is no statistics
 * table to read instead, because a count kept beside the facts is a second
 * account of them that can be wrong.
 *
 * A job says so about itself (`is = 'job'`). An agent is anything that `asks` a
 * model: an agent is a job with memory, declared rather than written, so the
 * declaration is what there is to count.
 */
const CENSUS = `local held, entities = {}, 0
for e in each {} do
  entities = entities + 1
  for field in pairs(e) do held[field] = true end
end

local fields = 0
for _ in pairs(held) do fields = fields + 1 end

local jobs = 0
for _ in each { is = 'job' } do jobs = jobs + 1 end

local agents = 0
for _ in each { asks = true } do agents = agents + 1 end

return { entities = entities, fields = fields, jobs = jobs, agents = agents }`

type Census = {
  entities: number
  fields: number
  jobs: number
  agents: number
}

export default function Worlds() {
  const { who, world: chosen, choose, refresh } = useCluster()
  const [name, setName] = useState("")
  const [error, setError] = useState<unknown>(null)
  const [claiming, setClaiming] = useState(false)

  async function make(event: React.FormEvent) {
    event.preventDefault()
    const wanted = name.trim()
    if (!wanted || claiming) return

    setClaiming(true)
    setError(null)
    try {
      await claim(wanted)
      setName("")
      refresh()
      choose(wanted)
    } catch (thrown) {
      setError(thrown)
    } finally {
      setClaiming(false)
    }
  }

  return (
    <>
      <PageHead title="worlds">
        a world is where data lives. names are global on this cluster, so they
        are first-come — a name somebody already holds is refused rather than
        shared. each one below was asked what it holds.
      </PageHead>

      <form onSubmit={make} className="mb-10 flex flex-wrap items-end gap-3">
        <label className="block">
          <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
            new world
          </span>
          <input
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="orders"
            className="font-mono w-64 rounded-md border border-border bg-muted px-3 py-2 text-sm text-white placeholder:text-muted-foreground focus:border-white/30 focus:outline-none"
          />
        </label>
        <button
          type="submit"
          disabled={claiming || !name.trim()}
          className="inline-flex items-center gap-2 rounded-md bg-white px-5 py-2 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02] disabled:opacity-40"
        >
          <Plus className="size-4" />
          {claiming ? "claiming…" : "create"}
        </button>
      </form>

      {error ? <RefusalNote error={error} className="mb-10" /> : null}

      {who.worlds.length === 0 ? (
        <Nothing icon={Database} title="none yet">
          make one above. it is yours as soon as it exists — claiming grants it
          to you, and to nobody else.
        </Nothing>
      ) : (
        <div className="grid gap-px overflow-hidden rounded-lg border border-border bg-border sm:grid-cols-2 xl:grid-cols-3">
          {who.worlds.map((one) => (
            <Holding
              key={one}
              world={one}
              chosen={one === chosen}
              onChoose={() => choose(one)}
            />
          ))}
        </div>
      )}

      <p className="mt-6 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        the ones beginning with{" "}
        <code className="font-mono text-white/70">$</code> belong to the node —
        it writes its own readings into them, and they cannot be claimed. the
        face on each is derived from its name, so the world called{" "}
        <code className="font-mono text-white/70">orders</code> looks the same
        to everybody who has one.
      </p>

      <details className="mt-10 rounded-lg border border-border">
        <summary className="cursor-pointer px-4 py-3 text-sm text-muted-foreground transition-colors hover:text-white">
          the lua this page ran, once per world
        </summary>
        <div className="relative border-t border-border">
          <div className="absolute right-2 top-2">
            <CopyButton value={CENSUS} />
          </div>
          <pre className="overflow-x-auto p-4 font-mono text-xs leading-relaxed text-white/80">
            {CENSUS}
          </pre>
        </div>
      </details>
    </>
  )
}

/**
 * One world: its face, its name, and what came back when it was asked.
 *
 * Only the chosen world's avatar runs the shader. A grid of them would be a
 * grid of WebGL contexts, and the one worth spending on is the one every other
 * page in the console is pointed at.
 */
function Holding({
  world,
  chosen,
  onChoose,
}: {
  world: string
  chosen: boolean
  onChoose: () => void
}) {
  const [attempt, setAttempt] = useState(0)
  const asking = `${world} ${attempt}`
  const [answered, setAnswered] = useState<{ to: string; census: Census | null; error: unknown } | null>(null)

  useEffect(() => {
    let live = true

    run(world, CENSUS)
      .then((result) => live && setAnswered({ to: asking, census: result.value as Census, error: null }))
      .catch((thrown) => live && setAnswered({ to: asking, census: null, error: thrown }))

    return () => {
      live = false
    }
  }, [world, asking])

  const read = useCallback(() => setAttempt((n) => n + 1), [])

  // Only an answer about THIS world. Clearing the error by hand meant a card
  // could briefly show one world's refusal while counting another's.
  const current = answered?.to === asking ? answered : null
  const census = current?.census ?? null
  const error = current?.error ?? null

  return (
    <button
      type="button"
      // Clicking also re-asks, which is why the refusal below carries no "try
      // again" of its own: a button inside a button is not a thing, and the
      // card is already the affordance.
      onClick={() => {
        onChoose()
        read()
      }}
      className={cn(
        "flex items-start gap-5 p-5 text-left transition-colors",
        chosen ? "bg-muted" : "bg-background hover:bg-muted",
      )}
    >
      <WorldOrbit
        world={world}
        agents={census?.agents ?? 0}
        jobs={census?.jobs ?? 0}
        live={chosen}
      />

      <div className="min-w-0 flex-1">
        <div className="flex items-baseline gap-2">
          <span className="font-mono truncate text-sm text-white/85">
            {world}
          </span>
          {world.startsWith("$") ? (
            <span className="shrink-0 text-xs text-muted-foreground">
              the node&apos;s
            </span>
          ) : null}
        </div>

        {error ? (
          <RefusalNote error={error} className="mt-3 -ml-5" />
        ) : !census ? (
          <div className="mt-3 space-y-2">
            <Skeleton className="h-4 w-32 bg-white/5" />
            <Skeleton className="h-4 w-24 bg-white/5" />
          </div>
        ) : (
          <dl className="mt-3 space-y-1.5">
            <Count of={census.entities} one="entity" many="entities" />
            <Count of={census.fields} one="field" many="fields" />
            {/* Zero agents and zero jobs is the ordinary case for a world
                somebody is only putting data in, and four lines of nought is
                noise. What circles a world is only worth a line when it does. */}
            {census.agents > 0 ? (
              <Count of={census.agents} one="agent" many="agents" tone="agent" />
            ) : null}
            {census.jobs > 0 ? (
              <Count of={census.jobs} one="job" many="jobs" tone="job" />
            ) : null}
          </dl>
        )}

        <p className="mt-3 text-xs">
          {chosen ? (
            <span className="inline-flex items-center gap-1.5 text-flame">
              <Check className="size-3.5" />
              showing
            </span>
          ) : (
            <span className="text-muted-foreground">show</span>
          )}
        </p>
      </div>
    </button>
  )
}

/** A count and its unit, with the dot that stands for it on the ring. */
function Count({
  of,
  one,
  many,
  tone,
}: {
  of: number
  one: string
  many: string
  tone?: "agent" | "job"
}) {
  return (
    <div className="flex items-baseline gap-2">
      {tone ? (
        <span
          aria-hidden
          className={cn(
            "size-1.5 shrink-0 self-center rounded-full",
            tone === "agent" ? "bg-flame" : "bg-ember",
          )}
        />
      ) : null}
      <dt className="font-mono text-sm text-white">{showCount(of)}</dt>
      <dd className="text-sm text-muted-foreground">{of === 1 ? one : many}</dd>
    </div>
  )
}
