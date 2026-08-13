"use client"

import { BookMarked, Clock, Database, Sparkles } from "lucide-react"
import Link from "next/link"

import { Asked, Nothing, PageHead } from "@/components/dashboard/page-shell"
import { FactTable } from "@/components/dashboard/fact-table"
import type { Fact } from "@/lib/blazie"

import { useCluster } from "./cluster"
import { idsThatAre, useAsk } from "./use-ask"

/**
 * What this caller can see, counted.
 *
 * Every number here is derived from one `ask` with an empty pattern, because
 * there is no count endpoint and inventing one would mean a second way to be
 * wrong about the same facts. The cost of that is honest and stated below: this
 * page reads everything it is allowed to read.
 */
export default function Overview() {
  const { who, name } = useCluster()
  const everything = useAsk({})

  return (
    <>
      <PageHead title={who.login ? `hello, ${who.login}` : "this caller"}>
        a caller is a fingerprint and a list of ledgers it may name. that list is
        the whole of its reach — there are no row rules underneath it to go and
        check.
      </PageHead>

      <Asked {...outcome(everything)} empty={<NoLedgers granted={who.ledgers.length} />}>
        {(facts) => {
          const produced = facts.filter((f) => f.by !== null)
          const ids = new Set(facts.map((f) => String(f.id)))
          const attributes = new Set(facts.map((f) => f.attribute))
          const declares = facts.filter((f) => f.attribute === "is")

          return (
            <>
              <div className="grid gap-px overflow-hidden rounded-lg border border-border bg-border sm:grid-cols-2 lg:grid-cols-4">
                <Count
                  icon={Database}
                  label="facts"
                  value={facts.length}
                  note={`${ids.size} ids · ${attributes.size} attributes`}
                />
                <Count
                  icon={Sparkles}
                  label="produced"
                  value={produced.length}
                  note={
                    facts.length === 0
                      ? "nothing yet"
                      : `${facts.length - produced.length} came from outside`
                  }
                  href="/dashboard/produced"
                />
                <Count
                  icon={BookMarked}
                  label="attributes"
                  value={idsThatAre(declares, "attribute").length}
                  note="declared vocabulary"
                  href="/dashboard/attributes"
                />
                <Count
                  icon={Clock}
                  label="jobs"
                  value={idsThatAre(declares, "job").length}
                  note="the only thing with a cadence"
                  href="/dashboard/jobs"
                />
              </div>

              <section className="mt-12">
                <h2 className="mb-2 text-lg font-medium tracking-tight text-white">
                  the ledgers you may name
                </h2>
                <p className="mb-5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                  each is held at the transaction in the bar above. that pair is
                  the snapshot&apos;s name, and it is what every page here is
                  reading.
                </p>

                {/* No per-ledger count: a fact comes back as its five slots
                    and which ledger it was in is not one of them. A snapshot
                    over several ledgers answers as one, which is the point of
                    opening them together — so counting them apart would mean
                    asking each on its own, and that would be a different
                    snapshot for each row. */}
                <div className="overflow-hidden rounded-lg border border-border">
                  {who.ledgers.map((ledger) => (
                    <div
                      key={ledger}
                      className="font-mono flex items-center justify-between border-b border-border px-4 py-3 text-sm last:border-b-0"
                    >
                      <span className="text-white/85">{ledger}</span>
                      <span className="text-muted-foreground">
                        @ <span className="text-spark">{name[ledger] ?? "—"}</span>
                      </span>
                    </div>
                  ))}
                </div>
              </section>

              <section className="mt-12">
                <h2 className="mb-2 text-lg font-medium tracking-tight text-white">
                  what landed last
                </h2>
                <p className="mb-5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                  the highest transactions in the snapshot. nothing was rewritten
                  to put them there — a correction is a later fact, so this is the
                  end of the ledger rather than the current state of anything.
                </p>
                <FactTable facts={newest(facts, 12)} />
              </section>
            </>
          )
        }}
      </Asked>
    </>
  )
}

/** The tail of the ledger: highest tx first. */
function newest(facts: Fact[], howMany: number): Fact[] {
  return [...facts].sort((a, b) => b.tx - a.tx).slice(0, howMany)
}

function outcome(asked: ReturnType<typeof useAsk>) {
  return {
    of: asked.facts,
    error: asked.error,
    loading: asked.loading,
    retry: asked.retry,
  }
}

function NoLedgers({ granted }: { granted: number }) {
  return (
    <Nothing icon={Database} title={granted === 0 ? "this caller was granted nothing" : "no facts yet"}>
      {granted === 0 ? (
        <>
          a token names ledgers, and this one names none — so there is nothing to
          open and nothing to read. that is the refusal working, not a failure.
          a caller is granted, never registered.
        </>
      ) : (
        <>
          the ledgers opened, and they are empty. write the first fact from{" "}
          <Link href="/dashboard/facts" className="text-white underline decoration-white/30 underline-offset-4">
            facts
          </Link>
          .
        </>
      )}
    </Nothing>
  )
}

function Count({
  icon: Icon,
  label,
  value,
  note,
  href,
}: {
  icon: typeof Database
  label: string
  value: number
  note: string
  href?: string
}) {
  const body = (
    <div className="bg-background p-5 transition-colors hover:bg-white/[0.02]">
      <div className="mb-3 flex items-center gap-2 text-muted-foreground">
        <Icon className="size-4" strokeWidth={1.75} />
        <span className="text-xs">{label}</span>
      </div>
      <p className="font-mono text-2xl text-white">{value.toLocaleString()}</p>
      <p className="mt-1.5 text-xs text-muted-foreground">{note}</p>
    </div>
  )

  return href ? <Link href={href}>{body}</Link> : body
}
