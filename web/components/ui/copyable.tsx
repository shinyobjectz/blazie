"use client"

import { useEffect, useState } from "react"

import { cn } from "@/lib/utils"

/**
 * Mono text with a copy affordance. Anything a caller would paste — a snapshot
 * name, a fingerprint, a ledger — is one of these, so "you can cite this" is
 * something the page lets you do rather than something it claims.
 */
export function Copyable({
  text,
  label,
  className,
}: {
  text: string
  label?: string
  className?: string
}) {
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!copied) return
    const timer = window.setTimeout(() => setCopied(false), 1400)
    return () => window.clearTimeout(timer)
  }, [copied])

  return (
    <button
      type="button"
      title="copy"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text)
          setCopied(true)
        } catch {
          setCopied(false)
        }
      }}
      className={cn(
        "group inline-flex max-w-full items-center gap-3 rounded-md border border-border bg-muted px-3 py-2 text-left transition-colors hover:border-white/30",
        className,
      )}
    >
      <span className="font-mono truncate text-sm text-white/85">
        {label ?? text}
      </span>
      <span
        className={cn(
          "shrink-0 text-xs transition-colors",
          copied ? "text-spark" : "text-muted-foreground group-hover:text-white/70",
        )}
      >
        {copied ? "copied" : "copy"}
      </span>
    </button>
  )
}
