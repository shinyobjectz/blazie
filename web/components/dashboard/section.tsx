import type { LucideIcon } from "lucide-react"

import { cn } from "@/lib/utils"

/**
 * A settings section: what it is about, said once, with everything under it.
 *
 * Settings was a run of `<section className="mt-14">` with an `<h2>` and a
 * paragraph, repeated four times with slightly different spacing each time. That
 * reads as four unrelated things on one page rather than four parts of one, and
 * the drift between them was the visible symptom of there being no component.
 *
 * The icon is not decoration. This page answers four different questions — who
 * you are, what the console is pointed at, what your token may name, what an
 * agent may do — and a reader scanning for one of them is looking for a shape,
 * not reading headings in order.
 */
export function Section({
  icon: Icon,
  title,
  says,
  children,
  tone = "plain",
}: {
  icon: LucideIcon
  title: string
  says?: string
  children: React.ReactNode
  /** `grave` is for the section you leave from. It should not look inviting. */
  tone?: "plain" | "grave"
}) {
  return (
    <section className="border-t border-border pt-8">
      <div className="mb-5 flex items-start gap-3">
        <span
          className={cn(
            "flex size-8 shrink-0 items-center justify-center rounded-lg border",
            tone === "grave"
              ? "border-flame/30 bg-flame/5 text-flame"
              : "border-border bg-muted text-muted-foreground",
          )}
        >
          <Icon className="size-4" />
        </span>

        <div className="min-w-0">
          <h2 className="text-base font-medium tracking-tight text-white">{title}</h2>
          {says ? (
            <p className="mt-1.5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
              {says}
            </p>
          ) : null}
        </div>
      </div>

      <div className="sm:pl-11">{children}</div>
    </section>
  )
}

/**
 * One labelled value in a row of them.
 *
 * `Detail` in the page shell puts its label above and is built for a wide row of
 * numbers. These are short facts about one thing, so they read better as a list
 * where the labels line up and the eye can go straight down the values.
 */
export function Fact({
  label,
  children,
}: {
  label: string
  children: React.ReactNode
}) {
  return (
    <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1 border-b border-border py-2.5 last:border-b-0">
      <span className="font-mono w-28 shrink-0 text-xs text-muted-foreground">{label}</span>
      <span className="min-w-0 flex-1 text-sm text-white/85">{children}</span>
    </div>
  )
}
