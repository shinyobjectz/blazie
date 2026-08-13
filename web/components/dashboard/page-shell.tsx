"use client"

import type { LucideIcon } from "lucide-react"

import { RefusalNote } from "@/components/ui/refusal-note"
import { Skeleton } from "@/components/ui/skeleton"
import { cn } from "@/lib/utils"

/**
 * The furniture every console page shares.
 *
 * `Asked` is the important one: each page here is a question put to the held
 * snapshot, and a question has exactly four outcomes — refused, still going,
 * answered with nothing, answered. Writing that out once means no page can
 * quietly render an empty table for a request that actually failed.
 */

export function PageHead({
  title,
  children,
  aside,
}: {
  title: string
  children: React.ReactNode
  aside?: React.ReactNode
}) {
  return (
    <header className="mb-8 flex flex-wrap items-start justify-between gap-6">
      <div className="min-w-0">
        <h1 className="text-2xl font-medium tracking-tight text-white">
          {title}
        </h1>
        <p className="mt-2 max-w-2xl text-sm leading-relaxed text-muted-foreground">
          {children}
        </p>
      </div>
      {aside}
    </header>
  )
}

/** What a page shows when the question came back with nothing in it. */
export function Nothing({
  icon: Icon,
  title,
  children,
}: {
  icon: LucideIcon
  title: string
  children?: React.ReactNode
}) {
  return (
    <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border px-6 py-16 text-center">
      <Icon className="size-6 text-muted-foreground" strokeWidth={1.5} />
      <p className="text-sm font-medium text-white">{title}</p>
      {children ? (
        <p className="max-w-md text-sm leading-relaxed text-muted-foreground">
          {children}
        </p>
      ) : null}
    </div>
  )
}

/**
 * A question's four outcomes, in the order they can happen.
 *
 * `empty` is optional — a page that has nothing better to say than "nothing"
 * gets a plain line, but most have something worth saying about *why* it is
 * empty, which is usually more useful than the table would have been.
 */
export function Asked<T>({
  of,
  error,
  loading,
  retry,
  empty,
  children,
  rows = 4,
}: {
  of: T[] | null
  error: unknown
  loading: boolean
  retry: () => void
  empty?: React.ReactNode
  children: (answered: T[]) => React.ReactNode
  rows?: number
}) {
  if (error) return <RefusalNote error={error} retry={retry} />

  if (loading || of === null) {
    return (
      <div className="space-y-2">
        {Array.from({ length: rows }, (_, i) => (
          <Skeleton key={i} className="h-10 w-full bg-white/5" />
        ))}
      </div>
    )
  }

  if (of.length === 0) {
    return (
      empty ?? (
        <p className="font-mono text-sm text-muted-foreground">
          nothing answered that.
        </p>
      )
    )
  }

  return <>{children(of)}</>
}

/** A label above a value, used wherever a page states one fact about itself. */
export function Detail({
  label,
  children,
  className,
}: {
  label: string
  children: React.ReactNode
  className?: string
}) {
  return (
    <div className={cn("min-w-0", className)}>
      <p className="mb-1.5 text-xs text-muted-foreground">{label}</p>
      {children}
    </div>
  )
}
