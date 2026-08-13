"use client"

import { Play } from "lucide-react"
import { useCallback, useRef, useState } from "react"

import { PageHead } from "@/components/dashboard/page-shell"
import { CopyButton } from "@/components/ui/copy-button"
import { RefusalNote } from "@/components/ui/refusal-note"
import { useRemembered } from "@/hooks/use-remembered"
import type { RunResult } from "@/lib/blazie"
import { cn } from "@/lib/utils"

import { useCluster } from "../cluster"

/**
 * Write Lua, run it, read what came back.
 *
 * This is the whole API in one screen — there is no operation the console can
 * perform that is not something you could type here, which is the point of
 * having exactly one door. The examples below are the entire language surface:
 * set a field, read one, follow an edge, find, unsay, look back.
 */

const EXAMPLES: { label: string; source: string }[] = [
  { label: "write", source: "ada.height = 180\nada.name = 'Ada'\nreturn ada.height" },
  { label: "an edge", source: "grace.height = 175\nada.friend = grace\nreturn ada.friend.height" },
  {
    label: "find",
    source:
      "local found = {}\nfor p in each { height = 180 } do\n  found[#found + 1] = p.id\nend\nreturn found",
  },
  { label: "unsay", source: "ada.height = nil\nreturn ada.height" },
  {
    label: "list fields",
    source: "local out = {}\nfor field, value in pairs(ada) do\n  out[field] = value\nend\nreturn out",
  },
]

const HELD = "blazie.editor"

export default function Editor() {
  const { world, ask } = useCluster()
  const [result, setResult] = useState<RunResult | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [running, setRunning] = useState(false)
  const box = useRef<HTMLTextAreaElement>(null)

  // The draft this browser held, read rather than copied into state after
  // mount. This page is prerendered by the static export, so the held draft
  // cannot exist at render time — and correcting it in an effect meant the
  // editor showed the first example for one frame before replacing it with what
  // you were actually writing.
  const held = useRemembered(HELD)
  const [typed, setTyped] = useState<string | null>(null)
  const source = typed ?? held ?? EXAMPLES[0].source
  const setSource = setTyped

  const go = useCallback(async () => {
    if (!world || running) return
    setRunning(true)
    setError(null)
    window.localStorage.setItem(HELD, source)

    try {
      setResult(await ask(source))
    } catch (thrown) {
      setError(thrown)
      setResult(null)
    } finally {
      setRunning(false)
    }
  }, [ask, source, world, running])

  return (
    <>
      <PageHead title="editor">
        the whole api is on this page. everything the console does is a chunk
        like one of these, run against{" "}
        <span className="font-mono text-white/80">{world ?? "no world"}</span>.
      </PageHead>

      <div className="mb-4 flex flex-wrap gap-2">
        {EXAMPLES.map((example) => (
          <button
            key={example.label}
            type="button"
            onClick={() => {
              setSource(example.source)
              box.current?.focus()
            }}
            className="font-mono rounded-md border border-border px-3 py-1.5 text-xs text-muted-foreground transition-colors hover:border-white/30 hover:text-white"
          >
            {example.label}
          </button>
        ))}
      </div>

      <div className="overflow-hidden rounded-lg border border-border">
        <div className="flex items-center justify-between border-b border-border px-4 py-2">
          <span className="font-mono text-xs text-muted-foreground">lua</span>
          <CopyButton value={source} />
        </div>

        <textarea
          ref={box}
          value={source}
          onChange={(event) => setSource(event.target.value)}
          onKeyDown={(event) => {
            // The shortcut every console has. Enter alone must stay a newline.
            if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
              event.preventDefault()
              void go()
            }
          }}
          spellCheck={false}
          rows={12}
          className="font-mono w-full resize-y bg-muted/40 p-4 text-sm leading-relaxed text-white outline-none placeholder:text-muted-foreground"
          placeholder="ada.height = 180"
        />
      </div>

      <div className="mt-4 flex items-center gap-4">
        <button
          type="button"
          onClick={go}
          disabled={running || !world}
          className="inline-flex items-center gap-2 rounded-md bg-white px-5 py-2 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02] disabled:opacity-40"
        >
          <Play className="size-3.5" />
          {running ? "running…" : "run"}
        </button>
        <span className="text-xs text-muted-foreground">⌘↵</span>
      </div>

      {error ? <RefusalNote error={error} className="mt-6" /> : null}

      {result ? (
        <section className="mt-6">
          <div className="overflow-hidden rounded-lg border border-border">
            <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border px-4 py-2">
              <span className="font-mono text-xs text-muted-foreground">
                returned
              </span>
              <span className="font-mono text-xs text-muted-foreground">
                {result.wrote > 0 ? (
                  <span className="text-ember">
                    wrote {result.wrote}{" "}
                    {result.wrote === 1 ? "assertion" : "assertions"}
                  </span>
                ) : (
                  "read only"
                )}
                {" · "}
                <span className="text-spark">{describe(result.name)}</span>
              </span>
            </div>

            <pre
              className={cn(
                "overflow-x-auto p-4 font-mono text-sm leading-relaxed",
                result.value === null ? "text-muted-foreground" : "text-spark",
              )}
            >
              {result.value === null
                ? "nil — the chunk returned nothing"
                : JSON.stringify(result.value, null, 2)}
            </pre>
          </div>

          <p className="mt-3 max-w-2xl text-xs leading-relaxed text-muted-foreground">
            that name is the snapshot this ran against. the same source at the
            same name gives the same answer next month — it is what makes a
            number you got here something you can cite.
          </p>
        </section>
      ) : null}
    </>
  )
}

function describe(name: Record<string, number>) {
  return Object.entries(name)
    .map(([world, tx]) => `${world}@${tx}`)
    .join(" ")
}
