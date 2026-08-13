"use client"

import { isRefusal } from "@/lib/blazie"
import { cn } from "@/lib/utils"

/**
 * A refusal, shown the way blazie means it: the problem names what happened,
 * the repair says how to comply. There is deliberately no "something went
 * wrong" path — an error with nothing to do about it is not an error message,
 * it is a shrug.
 */
export function RefusalNote({
  error,
  className,
  retry,
}: {
  error: unknown
  className?: string
  retry?: () => void
}) {
  if (!error) return null

  const problem = isRefusal(error) ? error.problem : "unexpected"
  const repair = isRefusal(error)
    ? error.repair
    : error instanceof Error
      ? error.message
      : String(error)

  return (
    <div
      className={cn(
        "border-l-2 border-flame bg-flame/5 py-3 pl-5 pr-4",
        className,
      )}
      role="alert"
    >
      <p className="font-mono text-sm text-flame">{problem}</p>
      <p className="mt-1.5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        {repair}
      </p>
      {retry && (
        <button
          type="button"
          onClick={retry}
          className="mt-3 text-sm text-white underline decoration-white/30 underline-offset-4 transition-colors hover:decoration-white"
        >
          try again
        </button>
      )}
    </div>
  )
}
