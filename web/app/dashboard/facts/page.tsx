"use client"

import { Plus, Rows3, X } from "lucide-react"
import { useMemo, useState } from "react"

import { FactTable } from "@/components/dashboard/fact-table"
import { Asked, Nothing, PageHead } from "@/components/dashboard/page-shell"
import { CopyButton } from "@/components/ui/copy-button"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import {
  type Assertion,
  type Id,
  type Pattern,
  type SnapshotName,
  write,
} from "@/lib/blazie"
import { factHaystack } from "@/lib/format"
import { cn } from "@/lib/utils"

import { useCluster } from "../cluster"
import { useAsk } from "../use-ask"

const PAGE = 50

/**
 * Two of the four operations, on the name the console is holding.
 *
 * They are separated into tabs because they are different in kind, not just in
 * form: asking at a name is answerable forever and changes nothing, while
 * writing produces a *new* name and leaves the one on screen exactly as it was.
 * That is the bit people find surprising, so the write tab says it after every
 * successful write rather than silently refreshing the table.
 */
export default function FactsPage() {
  const { who } = useCluster()

  if (who.ledgers.length === 0) {
    return (
      <>
        <PageHead title="facts">
          the row shape everything else is made of.
        </PageHead>
        <Nothing icon={Rows3} title="this caller may name no ledgers">
          authorization is a list of ledgers written on the cluster. a grant has
          to be made there before there is anything to ask or anywhere to write.
        </Nothing>
      </>
    )
  }

  return (
    <>
      <PageHead title="facts">
        one row shape, five slots, and nothing is ever rewritten. a correction is
        a later fact, and the earlier one still answers where it was written.
      </PageHead>

      <Tabs defaultValue="ask">
        <TabsList className="mb-8">
          <TabsTrigger value="ask">ask</TabsTrigger>
          <TabsTrigger value="write">write</TabsTrigger>
        </TabsList>

        <TabsContent value="ask">
          <AskPanel />
        </TabsContent>
        <TabsContent value="write">
          <WritePanel ledgers={who.ledgers} />
        </TabsContent>
      </Tabs>
    </>
  )
}

/* ------------------------------------------------------------------- asking */

function AskPanel() {
  // Two levels, and the difference is load-bearing. `pattern` goes to the
  // cluster; `narrow` never leaves the browser and only hides rows already
  // fetched. Conflating them is how a console starts lying about what it asked.
  const [pattern, setPattern] = useState<Pattern>({})
  const [draft, setDraft] = useState({ id: "", attribute: "", value: "", by: "" })
  const [narrow, setNarrow] = useState("")
  const [page, setPage] = useState(0)

  const asked = useAsk(pattern)

  const narrowed = useMemo(() => {
    if (!asked.facts) return []
    const needle = narrow.trim().toLowerCase()
    if (!needle) return asked.facts
    return asked.facts.filter((fact) => factHaystack(fact).includes(needle))
  }, [asked.facts, narrow])

  const pages = Math.max(1, Math.ceil(narrowed.length / PAGE))
  const shown = narrowed.slice(page * PAGE, page * PAGE + PAGE)

  return (
    <>
      <p className="mb-4 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        a pattern is not a query language. an empty field is a wildcard, a filled
        one matches exactly, and there are no operators. a value that parses as
        json is sent as json — <code className="font-mono">42</code> is the
        number, <code className="font-mono">&quot;42&quot;</code> the string.
      </p>

      <form
        onSubmit={(event) => {
          event.preventDefault()
          setPage(0)
          setPattern(built(draft))
        }}
        className="flex flex-wrap items-end gap-3"
      >
        <Field label="id" value={draft.id} onChange={(id) => setDraft({ ...draft, id })} />
        <Field
          label="attribute"
          value={draft.attribute}
          onChange={(attribute) => setDraft({ ...draft, attribute })}
        />
        <Field
          label="value"
          value={draft.value}
          onChange={(value) => setDraft({ ...draft, value })}
          wide
        />
        <Field
          label="by"
          value={draft.by}
          onChange={(by) => setDraft({ ...draft, by })}
          placeholder="any producer"
        />
        <button
          type="submit"
          className="rounded-md bg-white px-5 py-2 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02]"
        >
          ask
        </button>
      </form>

      <div className="mt-10">
        <Asked
          of={asked.facts}
          error={asked.error}
          loading={asked.loading}
          retry={asked.retry}
          rows={6}
          empty={
            <p className="max-w-2xl text-sm leading-relaxed text-muted-foreground">
              nothing here matches. a pattern that matches nothing is an answer
              rather than an error — the snapshot is real and holds no such fact.
            </p>
          }
        >
          {(facts) => (
            <>
              <div className="mb-5 flex flex-wrap items-baseline justify-between gap-4">
                <p className="text-sm text-muted-foreground">
                  <span className="font-mono text-white">
                    {narrowed.length.toLocaleString("en-US")}
                  </span>{" "}
                  {narrowed.length === 1 ? "fact" : "facts"}
                  {narrow.trim() ? (
                    <>
                      {" "}
                      of <span className="font-mono">{facts.length.toLocaleString("en-US")}</span>
                    </>
                  ) : null}
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
                <p className="text-sm text-muted-foreground">
                  nothing in these rows matches “{narrow.trim()}”.
                </p>
              ) : (
                <FactTable facts={shown} />
              )}

              {pages > 1 ? (
                <div className="mt-6 flex items-center gap-4">
                  <Pager
                    label="previous"
                    disabled={page === 0}
                    onClick={() => setPage((at) => Math.max(0, at - 1))}
                  />
                  <p className="font-mono text-sm text-muted-foreground">
                    {page + 1} / {pages}
                  </p>
                  <Pager
                    label="next"
                    disabled={page >= pages - 1}
                    onClick={() => setPage((at) => Math.min(pages - 1, at + 1))}
                  />
                </div>
              ) : null}
            </>
          )}
        </Asked>
      </div>
    </>
  )
}

/* ------------------------------------------------------------------ writing */

type Row = { id: string; attribute: string; value: string }

const BLANK: Row = { id: "", attribute: "", value: "" }

function WritePanel({ ledgers }: { ledgers: string[] }) {
  const { reopen } = useCluster()
  const [ledger, setLedger] = useState(ledgers[0])
  const [rows, setRows] = useState<Row[]>([{ ...BLANK }])
  const [landed, setLanded] = useState<SnapshotName | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [sending, setSending] = useState(false)

  const ready = rows.filter((row) => row.id.trim() && row.attribute.trim())

  async function send() {
    setSending(true)
    setError(null)
    setLanded(null)
    try {
      const facts: Assertion[] = ready.map((row) => ({
        id: asId(row.id.trim()),
        attribute: row.attribute.trim(),
        value: asTerm(row.value.trim()),
      }))
      setLanded(await write(ledger, facts))
      setRows([{ ...BLANK }])
    } catch (thrown) {
      setError(thrown)
    } finally {
      setSending(false)
    }
  }

  return (
    <>
      <p className="mb-6 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        a fact written from here came from outside, so it names nothing — the{" "}
        <code className="font-mono text-ember">by</code> slot is not offered
        because claiming one would be a lie the cluster refuses anyway. only a
        formula or a job can fill it.
      </p>

      {ledgers.length > 1 ? (
        <div className="mb-6 flex flex-wrap gap-2">
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
      ) : null}

      <div className="space-y-3">
        {rows.map((row, at) => (
          // Rows are positional and identical rows are legal, so the index is
          // the only identity one has.
          <div key={at} className="flex flex-wrap items-end gap-3">
            <Field
              label={at === 0 ? "id" : ""}
              value={row.id}
              onChange={(id) => setRows(replace(rows, at, { ...row, id }))}
            />
            <Field
              label={at === 0 ? "attribute" : ""}
              value={row.attribute}
              onChange={(attribute) => setRows(replace(rows, at, { ...row, attribute }))}
            />
            <Field
              label={at === 0 ? "value" : ""}
              value={row.value}
              onChange={(value) => setRows(replace(rows, at, { ...row, value }))}
              wide
            />
            <button
              type="button"
              onClick={() => setRows(rows.length === 1 ? [{ ...BLANK }] : rows.filter((_, i) => i !== at))}
              className="mb-0.5 rounded-md border border-border p-2 text-muted-foreground transition-colors hover:border-white/30 hover:text-white"
              aria-label="remove this row"
            >
              <X className="size-4" />
            </button>
          </div>
        ))}
      </div>

      <div className="mt-6 flex flex-wrap items-center gap-3">
        <button
          type="button"
          onClick={() => setRows([...rows, { ...BLANK }])}
          className="inline-flex items-center gap-2 rounded-md border border-border px-3 py-2 text-sm text-muted-foreground transition-colors hover:border-white/30 hover:text-white"
        >
          <Plus className="size-4" />
          another fact
        </button>

        <button
          type="button"
          onClick={send}
          disabled={sending || ready.length === 0}
          className="rounded-md bg-white px-5 py-2 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02] disabled:opacity-40"
        >
          {sending
            ? "writing…"
            : `write ${ready.length || ""} ${ready.length === 1 ? "fact" : "facts"}`.trim()}
        </button>
      </div>

      {error ? <RefusalNote error={error} className="mt-8" /> : null}

      {landed ? (
        <div className="mt-8 rounded-lg border border-spark/30 bg-spark/5 p-5">
          <p className="text-sm text-white">
            written. the snapshot they landed in is:
          </p>
          <div className="mt-3 flex items-center gap-2">
            <code className="font-mono text-sm text-spark">
              {JSON.stringify(landed)}
            </code>
            <CopyButton value={JSON.stringify(landed)} />
          </div>
          <p className="mt-4 max-w-xl text-sm leading-relaxed text-muted-foreground">
            that name is how you read your own write without polling for it. the
            console is still holding the older name and still answering exactly
            what it did before, which is correct —{" "}
            <button
              type="button"
              onClick={reopen}
              className="text-white underline decoration-white/30 underline-offset-4 transition-colors hover:decoration-white"
            >
              re-open
            </button>{" "}
            to move it forward.
          </p>
        </div>
      ) : null}
    </>
  )
}

/* ----------------------------------------------------------------- plumbing */

function replace(rows: Row[], at: number, row: Row): Row[] {
  return rows.map((held, i) => (i === at ? row : held))
}

function built({ id, attribute, value, by }: Record<string, string>): Pattern {
  const pattern: Pattern = {}
  if (id.trim()) pattern.id = asId(id.trim())
  if (attribute.trim()) pattern.attribute = attribute.trim()
  if (value.trim()) pattern.value = asTerm(value.trim())
  if (by.trim()) pattern.by = by.trim()
  return pattern
}

/** A field the API takes as a term: json if it parses, otherwise the string. */
function asTerm(raw: string): unknown {
  if (raw === "") return ""
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

function Field({
  label,
  value,
  onChange,
  wide,
  placeholder = "any",
}: {
  label: string
  value: string
  onChange: (next: string) => void
  wide?: boolean
  placeholder?: string
}) {
  return (
    <label className="block">
      {label ? (
        <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
          {label}
        </span>
      ) : null}
      <input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        className={cn(
          "font-mono rounded-md border border-border bg-muted px-3 py-2 text-sm text-white placeholder:text-muted-foreground focus:border-white/30 focus:outline-none",
          wide ? "w-64" : "w-44",
        )}
      />
    </label>
  )
}

function Pager({
  label,
  disabled,
  onClick,
}: {
  label: string
  disabled: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="rounded-md border border-border px-3 py-1.5 text-sm text-muted-foreground transition-colors hover:border-white/30 hover:text-white disabled:opacity-40"
    >
      {label}
    </button>
  )
}
