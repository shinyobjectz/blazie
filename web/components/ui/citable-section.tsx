"use client"

import { Fingerprint, History, KeyRound, PlusCircle } from "lucide-react"

import { CopyButton } from "@/components/ui/copy-button"
import { cn } from "@/lib/utils"

/**
 * The section that replaced a table of verbs.
 *
 * The verbs were true and meant nothing to anybody who had not used this
 * already — "which ledgers → a snapshot name" explains a thing in its own
 * vocabulary. So the same four operations are here as an actual exchange you
 * could paste into a terminal, and the ideas come out of the code rather than
 * being asserted beside it.
 *
 * Every request and response below is the real shape, taken from
 * `Blazie.Surface.Controller` and `Blazie.Wire`. If those change, this is
 * wrong, and that is the right amount of coupling for a page that claims to
 * show what using it looks like.
 */

const features = [
  {
    icon: PlusCircle,
    title: "write, and get a name back",
    body: "the name is the snapshot your facts landed in, so you read your own write without polling for it.",
  },
  {
    icon: History,
    title: "ask at that name, forever",
    body: "the same question at the same name gives the same facts next month. cache on the pair and never invalidate.",
  },
  {
    icon: Fingerprint,
    title: "`by` says what made it",
    body: "null means it came from outside and cannot be reproduced. anything else names the code that produced it.",
  },
  {
    icon: KeyRound,
    title: "a token names ledgers",
    body: "authorization is a list of ledgers you may name — not row rules, not predicates, and readable in one glance.",
  },
]

const TRANSCRIPT = `# write one fact. it came from outside, so nothing produced it.
curl -X POST https://api.blazie.dev/write \\
  -H "Authorization: Bearer $BLAZIE_TOKEN" \\
  -d '{"ledger":"tenant-7","facts":[
        {"id":"ada","attribute":"height","value":180}]}'

{"name":{"tenant-7":42}}

# ask at that name. this answer does not change again.
curl -X POST https://api.blazie.dev/ask \\
  -H "Authorization: Bearer $BLAZIE_TOKEN" \\
  -d '{"name":{"tenant-7":42},"pattern":{"attribute":"height"}}'

{"facts":[
  {"id":"ada","attribute":"height","value":180,"tx":42,"by":null}]}

# a later fact corrects it. the old name still answers 180.
curl -X POST https://api.blazie.dev/write \\
  -H "Authorization: Bearer $BLAZIE_TOKEN" \\
  -d '{"ledger":"tenant-7","facts":[
        {"id":"ada","attribute":"height","value":181}]}'

{"name":{"tenant-7":43}}`

type Line = { text: string; kind: "comment" | "cmd" | "json" | "blank" }

/** Classified once, so the render is a map rather than a pile of conditionals. */
function classify(source: string): Line[] {
  return source.split("\n").map((text) => {
    if (text.trim() === "") return { text, kind: "blank" as const }
    if (text.trimStart().startsWith("#")) return { text, kind: "comment" as const }
    if (text.startsWith("{") || text.startsWith("  {") || text.startsWith("]"))
      return { text, kind: "json" as const }
    return { text, kind: "cmd" as const }
  })
}

const lineColour: Record<Line["kind"], string> = {
  comment: "text-white/35",
  cmd: "text-white/80",
  // The answers, in the mark's own colour — they are the point of the panel.
  json: "text-spark/90",
  blank: "",
}

export function CitableSection({ className, ...props }: React.ComponentProps<"section">) {
  const lines = classify(TRANSCRIPT)

  return (
    <section
      className={cn("w-full border-t border-border px-6 py-20 sm:px-10", className)}
      data-slot="citable-section"
      {...props}
    >
      <div className="mx-auto max-w-6xl">
        <h2 className="mb-3 text-3xl font-medium tracking-tight text-white">
          an answer you can cite
        </h2>
        <p className="mb-12 max-w-2xl text-sm leading-relaxed text-muted-foreground">
          four operations, and this is all of them. a caller holds the
          snapshot&apos;s name, never its bytes — so what it read is something it
          can hand to somebody else, and they get the same answer.
        </p>

        <div className="grid grid-cols-1 items-start gap-10 lg:grid-cols-[300px_1fr] lg:gap-12">
          <div className="space-y-7">
            {features.map((f) => (
              <div className="flex items-start gap-4" key={f.title}>
                <span className="flex size-9 shrink-0 items-center justify-center rounded-full border border-white/15 bg-white/5 text-flame">
                  <f.icon className="size-4" strokeWidth={1.75} />
                </span>
                <div>
                  <p className="text-sm font-medium text-white">{f.title}</p>
                  <p className="mt-1 text-sm leading-relaxed text-muted-foreground">
                    {f.body}
                  </p>
                </div>
              </div>
            ))}
          </div>

          <div className="relative overflow-hidden rounded-lg border border-border bg-muted/60">
            <div className="flex items-center justify-between border-b border-border px-4 py-2">
              <span className="font-mono text-xs text-muted-foreground">
                the whole api
              </span>
              <CopyButton value={TRANSCRIPT} />
            </div>

            <pre className="overflow-x-auto p-5 font-mono text-[13px] leading-relaxed">
              {lines.map((line, i) => (
                <div
                  className={cn("whitespace-pre", lineColour[line.kind])}
                  // Lines are positional and several are identical; the index is
                  // the only stable identity a transcript has.
                  key={`${i}-${line.text}`}
                >
                  {line.text || " "}
                </div>
              ))}
            </pre>
          </div>
        </div>

        <p className="mt-10 max-w-2xl text-sm leading-relaxed text-muted-foreground">
          the same four from a terminal:{" "}
          <code className="font-mono text-white/80">blazie write tenant-7 ada height 180</code>
          , then{" "}
          <code className="font-mono text-white/80">blazie ask tenant-7 --attribute height</code>
          , and{" "}
          <code className="font-mono text-white/80">blazie watch tenant-7</code> to be
          answered again as facts land.
        </p>
      </div>
    </section>
  )
}
