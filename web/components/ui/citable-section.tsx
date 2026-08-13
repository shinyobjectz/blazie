"use client"

import { Fingerprint, History, KeyRound, PlusCircle } from "lucide-react"

import { CopyButton } from "@/components/ui/copy-button"
import { cn } from "@/lib/utils"

/**
 * The section that replaced a table of verbs.
 *
 * The verbs were true and meant nothing to anybody who had not used this
 * already — "which worlds → a snapshot name" explains a thing in its own
 * vocabulary. Then the four became one: send Lua, get back what it returned.
 * So this is an exchange you could paste into a terminal, and the ideas come
 * out of the code rather than being asserted beside it.
 *
 * Every request and response below is the real shape, taken from
 * `Blazie.Surface.Controller` and `Blazie.Lua.World`. If those change, this is
 * wrong, and that is the right amount of coupling for a page that claims to
 * show what using it looks like.
 */

const features = [
  {
    icon: PlusCircle,
    title: "it is just lua",
    body: "no query language and no schema. an entity is a table, a field is a field, and an edge is a field holding another entity.",
  },
  {
    icon: History,
    title: "every answer has a name",
    body: "a run tells you which snapshot it read. ask again at that name next month and the answer is identical.",
  },
  {
    icon: Fingerprint,
    title: "nothing is overwritten",
    body: "a correction is a later fact. `at(42)` still answers what was true then, so “what did it believe on tuesday” is a question.",
  },
  {
    icon: KeyRound,
    title: "one door",
    body: "send lua, get back what it returned. there is no second endpoint to learn and no client library to keep in step.",
  },
]

const TRANSCRIPT = `# the whole api. send lua, get back what it returned.
curl -X POST https://api.blazie.dev/run \\
  -H "Authorization: Bearer $BLAZIE_TOKEN" \\
  -d '{"world":"main","source":"
        ada.height = 180
        ada.friend = grace
        return ada.height
      "}'

{"value":180,"name":{"main":42},"wrote":5}

# that name is the answer's receipt. it does not change again.
curl -X POST https://api.blazie.dev/run \\
  -H "Authorization: Bearer $BLAZIE_TOKEN" \\
  -d '{"world":"main","name":{"main":42},"source":"
        return ada.friend.height
      "}'

{"value":175,"name":{"main":42},"wrote":0}

# find things. lua is the query language, so counting needs nothing new.
curl -X POST https://api.blazie.dev/run \\
  -H "Authorization: Bearer $BLAZIE_TOKEN" \\
  -d '{"world":"main","source":"
        local n = 0
        for p in each { height = 180 } do n = n + 1 end
        return n
      "}'

{"value":1,"name":{"main":43},"wrote":0}`

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
          one operation, and this is all of it. every run hands back the name of
          the snapshot it read, so what you got is something you can hand to
          somebody else and they get the same answer.
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
          the same from a terminal:{" "}
          <code className="font-mono text-white/80">blazie run main &apos;ada.height = 180&apos;</code>
          , or{" "}
          <code className="font-mono text-white/80">blazie run main -f setup.lua</code>{" "}
          to send a file.
        </p>
      </div>
    </section>
  )
}
