"use client"

import { Check, Database, Plus } from "lucide-react"
import { useState } from "react"

import { Nothing, PageHead } from "@/components/dashboard/page-shell"
import { RefusalNote } from "@/components/ui/refusal-note"
import { claim } from "@/lib/blazie"
import { cn } from "@/lib/utils"

import { useCluster } from "../cluster"

/**
 * Your ledgers, and how to make one.
 *
 * A ledger is where data lives — the thing another backend would call a
 * database. Making one is the operation the console could not perform at all
 * until recently: every request is checked against the ledgers a caller may
 * name, so naming a new one was refused before it could be created, and a
 * ledger existed only when somebody with shell access wrote a grant by hand.
 */
export default function Ledgers() {
  const { who, ledger: chosen, choose, refresh } = useCluster()
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
      <PageHead title="ledgers">
        a ledger is where data lives. names are global on this cluster, so they
        are first-come — a name somebody already holds is refused rather than
        shared.
      </PageHead>

      <form onSubmit={make} className="mb-10 flex flex-wrap items-end gap-3">
        <label className="block">
          <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
            new ledger
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

      {who.ledgers.length === 0 ? (
        <Nothing icon={Database} title="none yet">
          make one above. it is yours as soon as it exists — claiming grants it
          to you, and to nobody else.
        </Nothing>
      ) : (
        <div className="overflow-hidden rounded-lg border border-border">
          {who.ledgers.map((one) => (
            <button
              key={one}
              type="button"
              onClick={() => choose(one)}
              className={cn(
                "flex w-full items-center justify-between border-b border-border px-4 py-3 text-left transition-colors last:border-b-0 hover:bg-white/[0.03]",
                one === chosen && "bg-white/[0.04]",
              )}
            >
              <span className="font-mono text-sm text-white/85">{one}</span>
              {one === chosen ? (
                <span className="inline-flex items-center gap-1.5 text-xs text-flame">
                  <Check className="size-3.5" />
                  showing
                </span>
              ) : (
                <span className="text-xs text-muted-foreground">show</span>
              )}
            </button>
          ))}
        </div>
      )}

      <p className="mt-6 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        the ones beginning with{" "}
        <code className="font-mono text-white/70">$</code> belong to the node —
        it writes its own readings into them, and they cannot be claimed.
      </p>
    </>
  )
}
