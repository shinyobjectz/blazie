"use client"

import { BookMarked } from "lucide-react"

import { FactValue } from "@/components/dashboard/fact-table"
import { Asked, Nothing, PageHead } from "@/components/dashboard/page-shell"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import type { Fact } from "@/lib/blazie"

import { latest, useAsk } from "../use-ask"

/**
 * The declared vocabulary — which is itself facts, so this page is a query.
 *
 * An attribute is a defined thing described by facts in the same ledger, in the
 * same row shape: `{name, is, attribute}`, `{name, answers, …}`,
 * `{name, cardinality, one|many}`. That is why there is no schema screen here
 * and no migration to run — the vocabulary is data, and this reads it the way
 * anything else reads anything.
 */

const ROOT = ["is", "answers", "cardinality"]

export default function Attributes() {
  // One question for the whole page: every fact about every attribute. Asking
  // per-attribute would be three round trips each, at the same name, for facts
  // that were all in the first answer.
  const asked = useAsk({})

  return (
    <>
      <PageHead title="attributes">
        an attribute is a defined thing with facts describing it, which is why
        schema and vocabulary need no words of their own. defining one is writing
        facts about it — in the same ledger, in the same row shape.
      </PageHead>

      <Asked
        of={asked.facts}
        error={asked.error}
        loading={asked.loading}
        retry={asked.retry}
        empty={
          <Nothing icon={BookMarked} title="no attributes declared">
            nothing here has said what it is yet. the three root attributes —{" "}
            <code className="font-mono text-white/80">is</code>,{" "}
            <code className="font-mono text-white/80">answers</code>,{" "}
            <code className="font-mono text-white/80">cardinality</code> — are
            what a declaration is written with, and they bootstrap themselves.
          </Nothing>
        }
      >
        {(facts) => {
          const declared = describe(facts)

          if (declared.length === 0) {
            return (
              <Nothing icon={BookMarked} title="no attributes declared">
                there are facts here, but none of them say{" "}
                <code className="font-mono text-white/80">is: attribute</code>.
                blazie does not require a declaration before a write — it is what
                lets one be checked when there is one.
              </Nothing>
            )
          }

          return (
            <div className="overflow-x-auto rounded-lg border border-border">
              <Table className="font-mono text-xs">
                <TableHeader>
                  <TableRow className="hover:bg-transparent">
                    {["attribute", "answers", "cardinality", "declared at", ""].map(
                      (head) => (
                        <TableHead key={head} className="text-muted-foreground">
                          {head}
                        </TableHead>
                      ),
                    )}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {declared.map((one) => (
                    <TableRow key={one.name}>
                      <TableCell className="text-white/85">{one.name}</TableCell>
                      <TableCell>
                        {one.answers === undefined ? (
                          <span className="text-muted-foreground">any</span>
                        ) : (
                          <FactValue value={one.answers} />
                        )}
                      </TableCell>
                      <TableCell>
                        {one.cardinality === undefined ? (
                          <span className="text-muted-foreground">one</span>
                        ) : (
                          <FactValue value={one.cardinality} />
                        )}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {one.tx}
                      </TableCell>
                      <TableCell>
                        {ROOT.includes(one.name) ? (
                          <span
                            className="text-ember"
                            title="one of the three a declaration is written with — it describes itself"
                          >
                            root
                          </span>
                        ) : null}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )
        }}
      </Asked>
    </>
  )
}

type Declared = {
  name: string
  answers?: unknown
  cardinality?: unknown
  tx: number
}

/**
 * Which ids said `is: attribute`, and what else was said about them.
 *
 * `latest` per attribute, because a redeclaration is a later fact and the
 * earlier one is still there — showing both would read as a contradiction when
 * it is a history.
 */
function describe(facts: Fact[]): Declared[] {
  const names = new Set(
    facts
      .filter((f) => f.attribute === "is" && f.value === "attribute")
      .map((f) => String(f.id)),
  )

  const answers = latest(facts.filter((f) => f.attribute === "answers"))
  const cardinality = latest(facts.filter((f) => f.attribute === "cardinality"))
  const declaredAt = latest(
    facts.filter((f) => f.attribute === "is" && f.value === "attribute"),
  )

  return [...names].sort().map((name) => ({
    name,
    answers: answers.get(name)?.value,
    cardinality: cardinality.get(name)?.value,
    tx: declaredAt.get(name)?.tx ?? 0,
  }))
}
