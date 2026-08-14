"use client"

import { Bot, Copy, Trash2 } from "lucide-react"
import { useCallback, useEffect, useRef, useState } from "react"

import { Section } from "@/components/dashboard/section"
import { RefusalNote } from "@/components/ui/refusal-note"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import {
  type Cluster,
  type Grant,
  type Remit,
  approvePairing,
  grants as askGrants,
  clusters as askClusters,
  makeGrant,
  revokeGrant,
} from "@/lib/blazie"
import { cn } from "@/lib/utils"

/**
 * What an agent may do on your behalf.
 *
 * Two ways in, and they make the same record. A code is for an agent sitting in
 * front of you asking to be let in; a key is for one that runs where nobody can
 * approve anything. The difference is only how the token gets there — what it
 * may do is the remit either way.
 *
 * The token is shown once and the screen says so, because it is true: the
 * control plane keeps a fingerprint and cannot produce the token again. A
 * console that implied otherwise would be teaching somebody to lose it.
 */

const CLUSTERS: { id: Remit["clusters"]; label: string; hint: string }[] = [
  { id: "none", label: "worlds only", hint: "cannot touch machines" },
  { id: "open", label: "may open clusters", hint: "spends money" },
  { id: "open+remove", label: "may open and remove", hint: "destroys data" },
]

/** Every Studio on every cluster, flat, so a picker can list them. */
function studiosOf(all: Cluster[]): { id: string; label: string }[] {
  return all.flatMap((cluster) =>
    (cluster.studios ?? []).map((one) => ({
      id: one.id,
      label: `${cluster.name} / ${one.name}`,
    })),
  )
}

export function Grants() {
  const [held, setHeld] = useState<Grant[]>([])
  const [error, setError] = useState<unknown>(null)
  const [shown, setShown] = useState<{ name: string; token: string } | null>(null)

  const [name, setName] = useState("")
  const [clusters, setClusters] = useState<Remit["clusters"]>("none")
  const [most, setMost] = useState(1)
  const [studio, setStudio] = useState("")
  const [studios, setStudios] = useState<{ id: string; label: string }[]>([])
  const [code, setCode] = useState("")
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    try {
      setHeld((await askGrants()).grants)
      setStudios(studiosOf((await askClusters()).clusters))
    } catch (thrown) {
      setError(thrown)
    }
  }, [])

  // Strict mode runs an effect twice and both runs would ask. The same guard the
  // cluster state uses, for the same reason.
  const started = useRef(false)

  useEffect(() => {
    if (started.current) return
    started.current = true
    void load()
  }, [load])

  const remit = (): Remit => ({
    // A Studio grant is a tenant's: the cluster enforces its worlds, and the
    // machine permissions are off — the server forces this too, but the form
    // should not offer what will be clamped away.
    clusters: studio ? "none" : clusters,
    most: studio || clusters === "none" ? 0 : most,
    worlds: [],
    ...(studio ? { studio } : {}),
    until: new Date(Date.now() + 30 * 86_400_000).toISOString(),
  })

  const make = async () => {
    if (busy || !name.trim()) return
    setBusy(true)
    setError(null)

    try {
      const made = await makeGrant({ name: name.trim(), remit: remit() })
      setShown({ name: made.grant.name, token: made.token })
      setName("")
      await load()
    } catch (thrown) {
      setError(thrown)
    } finally {
      setBusy(false)
    }
  }

  const approve = async () => {
    if (busy || !code.trim()) return
    setBusy(true)
    setError(null)

    try {
      await approvePairing(code.trim().toUpperCase(), remit())
      setCode("")
      await load()
    } catch (thrown) {
      setError(thrown)
    } finally {
      setBusy(false)
    }
  }

  const live = held.filter((one) => !one.revoked)

  return (
    <Section
      icon={Bot}
      title="agents"
      says="an agent talks to this control plane, not to a cluster — so it holds a grant and never a credential. anything it reads can instruct it, so what it may do is bounded here rather than trusted: opening a cluster spends money and removing one destroys every world on it, which is why they are two permissions and not one."
    >

      {/* What the grant may do, shared by both ways of making one — the remit is
          the same thing whether a code or a key carries it. */}
      <div className="mb-5 flex flex-wrap items-end gap-4">
        {studios.length > 0 ? (
          <label className="block">
            <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
              acting as
            </span>
            <Select value={studio || "account"} onValueChange={(one) => setStudio(one === "account" ? "" : one)}>
              <SelectTrigger className="font-mono h-auto min-w-56 rounded-md border-border bg-muted px-3 py-2 text-sm text-white">
                <SelectValue />
              </SelectTrigger>
              <SelectContent className="font-mono">
                <SelectItem value="account" className="text-sm">
                  the whole account
                  <span className="ml-2 text-xs text-muted-foreground">every cluster it holds</span>
                </SelectItem>
                {studios.map((one) => (
                  <SelectItem key={one.id} value={one.id} className="text-sm">
                    {one.label}
                    <span className="ml-2 text-xs text-muted-foreground">that studio&apos;s worlds only</span>
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </label>
        ) : null}

        {!studio ? (
          <label className="block">
            <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
              what it may do
            </span>
            <Select value={clusters} onValueChange={(one) => setClusters(one as Remit["clusters"])}>
              <SelectTrigger className="font-mono h-auto min-w-56 rounded-md border-border bg-muted px-3 py-2 text-sm text-white">
                <SelectValue />
              </SelectTrigger>
              <SelectContent className="font-mono">
                {CLUSTERS.map((one) => (
                  <SelectItem key={one.id} value={one.id} className="text-sm">
                    {one.label}
                    <span className="ml-2 text-xs text-muted-foreground">{one.hint}</span>
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </label>
        ) : null}

        {!studio && clusters !== "none" ? (
          <label className="block">
            <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
              at most, running at once
            </span>
            <input
              type="number"
              min={1}
              max={10}
              value={most}
              onChange={(event) => setMost(Number(event.target.value))}
              className="font-mono w-24 rounded-md border border-border bg-muted px-3 py-2 text-sm text-white focus:border-white/30 focus:outline-none"
            />
          </label>
        ) : null}
      </div>

      <div className="grid max-w-3xl gap-4 sm:grid-cols-2">
        <Way
          title="approve a code"
          says="the agent shows a short code. approving it here sends the token straight to it — nothing secret is typed or pasted."
          value={code}
          onChange={setCode}
          placeholder="ABCD-2345"
          action="approve"
          onAct={approve}
          busy={busy}
        />

        <Way
          title="make a key"
          says="for an agent that runs where nobody can approve a code — ci, a cron. the token is shown once and cannot be fetched again."
          value={name}
          onChange={setName}
          placeholder="what is holding it"
          action="make"
          onAct={make}
          busy={busy}
        />
      </div>

      {error ? <RefusalNote error={error} className="mt-6" /> : null}

      {shown ? (
        <div className="mt-6 rounded-lg border border-ember/40 bg-ember/5 p-4">
          <p className="font-mono mb-2 text-xs text-ember">
            {shown.name} — copy this now. it is not kept and cannot be shown again.
          </p>
          <div className="flex items-center gap-2">
            <code className="font-mono min-w-0 flex-1 truncate rounded bg-black/40 px-3 py-2 text-xs text-white">
              {shown.token}
            </code>
            <button
              type="button"
              onClick={() => void navigator.clipboard.writeText(shown.token)}
              className="flex size-8 items-center justify-center rounded-md border border-border text-muted-foreground transition-colors hover:border-white/30 hover:text-white"
              aria-label="copy"
            >
              <Copy className="size-3.5" />
            </button>
            <button
              type="button"
              onClick={() => setShown(null)}
              className="text-xs text-muted-foreground transition-colors hover:text-white"
            >
              done
            </button>
          </div>
        </div>
      ) : null}

      <div className="mt-8">
        {live.length === 0 ? (
          <p className="font-mono text-xs text-muted-foreground">
            no agent holds a grant.
          </p>
        ) : (
          <div className="grid gap-px overflow-hidden rounded-lg border border-border bg-border">
            {live.map((grant) => (
              <div key={grant.id} className="flex items-center gap-3 bg-background p-4">
                <Bot className="size-4 shrink-0 text-muted-foreground" />

                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm text-white">{grant.name}</span>
                  <span className="font-mono block truncate text-[11px] text-muted-foreground">
                    {grant.remit.studio
                      ? `studio ${studios.find((one) => one.id === grant.remit.studio)?.label ?? grant.remit.studio}`
                      : CLUSTERS.find((one) => one.id === grant.remit.clusters)?.label}
                    {grant.remit.clusters !== "none" ? ` · at most ${grant.remit.most}` : ""}
                    {" · until "}
                    {when(grant.remit.until)}
                    {grant.used ? ` · last used ${when(grant.used)}` : " · never used"}
                  </span>
                </span>

                <button
                  type="button"
                  onClick={async () => {
                    await revokeGrant(grant.id)
                    await load()
                  }}
                  className={cn(
                    "inline-flex items-center gap-1.5 text-xs text-muted-foreground",
                    "transition-colors hover:text-flame",
                  )}
                >
                  <Trash2 className="size-3.5" />
                  revoke
                </button>
              </div>
            ))}
          </div>
        )}
      </div>
    </Section>
  )
}

/** A date, said the way a person reads one. */
function when(iso: string): string {
  return new Date(iso).toLocaleDateString([], { day: "numeric", month: "short" })
}

function Way({
  title,
  says,
  value,
  onChange,
  placeholder,
  action,
  onAct,
  busy,
}: {
  title: string
  says: string
  value: string
  onChange: (next: string) => void
  placeholder: string
  action: string
  onAct: () => void
  busy: boolean
}) {
  return (
    <div className="rounded-lg border border-border p-4">
      <p className="mb-1 text-sm text-white">{title}</p>
      <p className="mb-4 text-xs leading-relaxed text-muted-foreground">{says}</p>

      <div className="flex gap-2">
        <input
          value={value}
          onChange={(event) => onChange(event.target.value)}
          placeholder={placeholder}
          className="font-mono min-w-0 flex-1 rounded-md border border-border bg-muted px-3 py-2 text-sm text-white placeholder:text-muted-foreground focus:border-white/30 focus:outline-none"
        />
        <button
          type="button"
          disabled={busy || !value.trim()}
          onClick={onAct}
          className="rounded-md bg-white px-4 py-2 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02] disabled:opacity-40 disabled:hover:scale-100"
        >
          {action}
        </button>
      </div>
    </div>
  )
}
