"use client"

import { useCallback, useEffect, useMemo, useState } from "react"

import { Copyable } from "@/components/ui/copyable"
import { RefusalNote } from "@/components/ui/refusal-note"
import {
  type Fact,
  type Id,
  type Pattern,
  type SnapshotName,
  ask,
  open,
} from "@/lib/blazie"
import { factHaystack, showName, showValue } from "@/lib/format"
import { cn } from "@/lib/utils"

const PAGE = 50

/**
 * The fact browser. Pick a ledger, open it, and ask it a question.
 *
 * A pattern is not a query language — an absent field is a wildcard and a
 * present one matches exactly. The narrow box below the results is a different
 * thing and says so: it filters rows already in the browser, and never goes
 * back to the cluster.
 */
export function Facts({ ledgers }: { ledgers: string[] }) {
  const [ledger, setLedger] = useState<string | null>(ledgers[0] ?? null)
  const [name, setName] = useState<SnapshotName | null>(null)
  const [facts, setFacts] = useState<Fact[] | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [asking, setAsking] = useState(false)

  // What goes into the pattern.
  const [id, setId] = useState("")
  const [attribute, setAttribute] = useState("")
  const [value, setValue] = useState("")

  // What only narrows what is already here.
  const [narrow, setNarrow] = useState("")
  const [page, setPage] = useState(0)

  const run = useCallback(
    async (reopen: boolean) => {
      if (!ledger) return
      setAsking(true)
      setError(null)
      try {
        const at = reopen || !name?.[ledger] ? await open([ledger]) : name
        const pattern: Pattern = {}
        if (id.trim()) pattern.id = asId(id.trim())
        if (attribute.trim()) pattern.attribute = attribute.trim()
        if (value.trim()) pattern.value = asTerm(value.trim())

        const found = await ask(at, pattern)
        setName(at)
        setFacts(found)
        setPage(0)
      } catch (thrown) {
        setError(thrown)
        setFacts(null)
      } finally {
        setAsking(false)
      }
    },
    [ledger, name, id, attribute, value],
  )

  // Choosing a ledger opens it and asks it everything. Nobody wants to press a
  // button to see what is in the thing they just clicked.
  useEffect(() => {
    if (!ledger) return
    setName(null)
    setFacts(null)
    setError(null)
    setNarrow("")
    setId("")
    setAttribute("")
    setValue("")
    setAsking(true)

    let live = true
    open([ledger])
      .then(async (at) => {
        const found = await ask(at, {})
        if (!live) return
        setName(at)
        setFacts(found)
        setPage(0)
      })
      .catch((thrown) => live && setError(thrown))
      .finally(() => live && setAsking(false))

    return () => {
      live = false
    }
  }, [ledger])

  const narrowed = useMemo(() => {
    if (!facts) return []
    const needle = narrow.trim().toLowerCase()
    if (!needle) return facts
    return facts.filter((fact) => factHaystack(fact).includes(needle))
  }, [facts, narrow])

  const pages = Math.max(1, Math.ceil(narrowed.length / PAGE))
  const shown = narrowed.slice(page * PAGE, page * PAGE + PAGE)

  if (ledgers.length === 0) {
    return (
      <p className="max-w-2xl text-sm leading-relaxed text-muted-foreground">
        this caller may name no ledgers yet. authorization in blazie is a list
        of ledgers, written on the cluster — a grant has to be made there before
        anything appears here.
      </p>
    )
  }

  return (
    <div>
      <div className="flex flex-wrap gap-2">
        {ledgers.map((one) => (
          <button
            key={one}
            type="button"
            onClick={() => setLedger(one)}
            className={cn(
              "font-mono rounded-md border px-3 py-1.5 text-sm transition-colors",
              one === ledger
                ? "border-flame/60 bg-flame/10 text-white"
                : "border-border text-muted-foreground hover:border-white/30 hover:text-white",
            )}
          >
            {one}
          </button>
        ))}
      </div>

      {ledger && (
        <>
          <div className="mt-8 flex flex-wrap items-end gap-6">
            <div>
              <p className="font-pixel mb-2 text-lg lowercase text-flame">open</p>
              <p className="mb-2 max-w-md text-xs leading-relaxed text-muted-foreground">
                the snapshot you are reading at. the same question at this name
                gives these facts forever — paste it into a request, or into a
                citation.
              </p>
              {name ? (
                <Copyable text={showName(name)} />
              ) : (
                <p className="font-mono text-sm text-muted-foreground">
                  {asking ? "opening…" : "—"}
                </p>
              )}
            </div>

            <button
              type="button"
              onClick={() => run(true)}
              disabled={asking}
              className="rounded-md border border-border px-4 py-2 text-sm text-muted-foreground transition-colors hover:border-white/30 hover:text-white disabled:opacity-50"
            >
              advance to now
            </button>
          </div>

          <div className="mt-10">
            <p className="font-pixel mb-2 text-lg lowercase text-flame">ask</p>
            <p className="mb-4 max-w-2xl text-xs leading-relaxed text-muted-foreground">
              an empty field is a wildcard; a filled one matches exactly. a
              value that parses as json is sent as json — <code className="font-mono">42</code>{" "}
              is the number, <code className="font-mono">&quot;42&quot;</code> is
              the string.
            </p>

            <form
              onSubmit={(event) => {
                event.preventDefault()
                run(false)
              }}
              className="flex flex-wrap items-end gap-3"
            >
              <Field label="id" value={id} onChange={setId} />
              <Field label="attribute" value={attribute} onChange={setAttribute} />
              <Field label="value" value={value} onChange={setValue} wide />
              <button
                type="submit"
                disabled={asking}
                className="rounded-md bg-white px-5 py-2 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02] disabled:opacity-50"
              >
                {asking ? "asking…" : "ask"}
              </button>
            </form>
          </div>

          {error && <RefusalNote error={error} className="mt-8" retry={() => run(true)} />}

          {facts && (
            <div className="mt-10">
              <div className="flex flex-wrap items-baseline justify-between gap-4">
                <p className="text-sm text-muted-foreground">
                  <span className="font-mono text-white">
                    {narrowed.length.toLocaleString("en-US")}
                  </span>{" "}
                  {narrowed.length === 1 ? "fact" : "facts"}
                  {narrow.trim() && (
                    <>
                      {" "}
                      of{" "}
                      <span className="font-mono">
                        {facts.length.toLocaleString("en-US")}
                      </span>
                    </>
                  )}
                </p>

                <input
                  value={narrow}
                  onChange={(event) => {
                    setNarrow(event.target.value)
                    setPage(0)
                  }}
                  placeholder="narrow these rows"
                  className="font-mono w-56 rounded-md border border-border bg-muted px-3 py-1.5 text-sm text-white placeholder:text-muted-foreground focus:border-white/30 focus:outline-none"
                />
              </div>

              {narrowed.length === 0 ? (
                <p className="mt-8 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                  nothing here matches. a pattern that matches nothing is an
                  answer, not an error — the snapshot is real and it holds no
                  such fact.
                </p>
              ) : (
                <FactTable facts={shown} />
              )}

              {pages > 1 && (
                <div className="mt-6 flex items-center gap-4">
                  <button
                    type="button"
                    onClick={() => setPage((at) => Math.max(0, at - 1))}
                    disabled={page === 0}
                    className="rounded-md border border-border px-3 py-1.5 text-sm text-muted-foreground transition-colors hover:border-white/30 hover:text-white disabled:opacity-40"
                  >
                    previous
                  </button>
                  <p className="font-mono text-sm text-muted-foreground">
                    {page + 1} / {pages}
                  </p>
                  <button
                    type="button"
                    onClick={() => setPage((at) => Math.min(pages - 1, at + 1))}
                    disabled={page >= pages - 1}
                    className="rounded-md border border-border px-3 py-1.5 text-sm text-muted-foreground transition-colors hover:border-white/30 hover:text-white disabled:opacity-40"
                  >
                    next
                  </button>
                </div>
              )}
            </div>
          )}
        </>
      )}
    </div>
  )
}

function Field({
  label,
  value,
  onChange,
  wide,
}: {
  label: string
  value: string
  onChange: (next: string) => void
  wide?: boolean
}) {
  return (
    <label className="block">
      <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
        {label}
      </span>
      <input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder="any"
        className={cn(
          "font-mono rounded-md border border-border bg-muted px-3 py-2 text-sm text-white placeholder:text-muted-foreground focus:border-white/30 focus:outline-none",
          wide ? "w-64" : "w-44",
        )}
      />
    </label>
  )
}

function FactTable({ facts }: { facts: Fact[] }) {
  return (
    <div className="mt-5 overflow-x-auto">
      <table className="w-full min-w-[52rem] text-left text-sm">
        <thead>
          <tr className="border-b border-border text-xs text-muted-foreground">
            <th className="font-mono py-2 pr-6 font-normal">id</th>
            <th className="font-mono py-2 pr-6 font-normal">attribute</th>
            <th className="font-mono py-2 pr-6 font-normal">value</th>
            <th className="font-mono py-2 pr-6 font-normal">tx</th>
            <th className="font-mono py-2 font-normal text-ember/80">by</th>
          </tr>
        </thead>
        <tbody>
          {facts.map((fact, at) => (
            <tr
              key={`${fact.tx}-${String(fact.id)}-${fact.attribute}-${at}`}
              className="border-b border-border/50 align-top"
            >
              <td className="font-mono py-2.5 pr-6 text-white/85">
                {String(fact.id)}
              </td>
              <td className="font-mono py-2.5 pr-6 text-white/70">
                {fact.attribute}
              </td>
              <td className="font-mono max-w-md break-words py-2.5 pr-6 text-white">
                {showValue(fact.value)}
              </td>
              <td className="font-mono py-2.5 pr-6 text-muted-foreground">
                {fact.tx}
              </td>
              <td className="py-2.5">
                <By by={fact.by} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/**
 * Provenance is the point of the product, so it is the one column that does not
 * look like the others. There are exactly two states and no third to forget:
 * a fact came from outside, or it names the code that made it.
 */
function By({ by }: { by: string | null }) {
  if (by === null) {
    return (
      <span
        className="font-mono text-xs text-muted-foreground"
        title="written from outside — a caller asserted it"
      >
        outside
      </span>
    )
  }

  return (
    <span
      className="font-mono inline-block rounded border border-ember/40 bg-ember/10 px-2 py-0.5 text-xs text-ember"
      title="derived — produced by this formula or job"
    >
      {by}
    </span>
  )
}

/** A field the API takes as a term: json if it parses, otherwise the string. */
function asTerm(raw: string): unknown {
  try {
    return JSON.parse(raw)
  } catch {
    return raw
  }
}

/** An id travels as a number or a string, so nothing else is offered here. */
function asId(raw: string): Id {
  const term = asTerm(raw)
  return typeof term === "number" ? term : raw
}
