"use client"

import { Check, Copy } from "lucide-react"
import { AnimatePresence, motion, useReducedMotion } from "motion/react"
import * as React from "react"

import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

const ICON_SPRING = { type: "spring" as const, duration: 0.3, bounce: 0 }

function iconMotion(reduceMotion: boolean) {
  if (reduceMotion) {
    return {
      initial: { opacity: 1, scale: 1, filter: "blur(0px)" },
      animate: { opacity: 1, scale: 1, filter: "blur(0px)" },
      exit: { opacity: 1, scale: 1, filter: "blur(0px)" },
      transition: { duration: 0 },
    }
  }
  return {
    initial: { opacity: 0, scale: 0.25, filter: "blur(4px)" },
    animate: { opacity: 1, scale: 1, filter: "blur(0px)" },
    exit: { opacity: 0, scale: 0.25, filter: "blur(4px)" },
    transition: ICON_SPRING,
  }
}

/**
 * The fallback matters more here than usual: a snapshot name is the thing a
 * caller is meant to keep, and `navigator.clipboard` is unavailable on any page
 * that is not a secure context. Failing silently would lose the one value the
 * whole design asks people to hold on to.
 */
function legacyCopyToClipboard(value: string) {
  const textArea = document.createElement("textarea")
  textArea.value = value
  textArea.setAttribute("readonly", "")
  textArea.style.position = "fixed"
  textArea.style.opacity = "0"
  textArea.style.pointerEvents = "none"

  document.body.appendChild(textArea)
  textArea.focus()
  textArea.select()
  textArea.setSelectionRange(0, value.length)

  let hasCopied = false
  try {
    hasCopied = document.execCommand("copy")
  } catch {
    hasCopied = false
  }

  document.body.removeChild(textArea)
  return hasCopied
}

export async function copyToClipboardWithMeta(value: string) {
  if (typeof window === "undefined" || !value) return false

  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value)
      return true
    } catch {
      return legacyCopyToClipboard(value)
    }
  }

  return legacyCopyToClipboard(value)
}

export function CopyButton({
  value,
  className,
  variant = "ghost",
  layout = "inline",
  ...props
}: React.ComponentProps<typeof Button> & {
  value: string
  /** `overlay` = absolute corner for code blocks; `inline` = normal flow next to text */
  layout?: "inline" | "overlay"
}) {
  const [hasCopied, setHasCopied] = React.useState(false)
  const reduceMotion = useReducedMotion()

  React.useEffect(() => {
    if (hasCopied) {
      const timer = setTimeout(() => setHasCopied(false), 2000)
      return () => clearTimeout(timer)
    }
  }, [hasCopied])

  const motionProps = iconMotion(!!reduceMotion)

  return (
    <Button
      aria-label={hasCopied ? "Copied to clipboard" : "Copy to clipboard"}
      className={cn(
        "before:-inset-2 touch-manipulation before:absolute before:z-[-1] before:content-['']",
        "motion-safe:active:scale-[0.96]",
        layout === "overlay" && "absolute top-2 right-2 z-10 size-7 shrink-0 overflow-hidden",
        layout === "inline" && "relative size-7 shrink-0 overflow-hidden rounded-md",
        className
      )}
      data-copied={hasCopied}
      data-slot="copy-button"
      onClick={async () => {
        if (await copyToClipboardWithMeta(value)) setHasCopied(true)
      }}
      size="icon"
      variant={variant}
      {...props}
    >
      <span aria-atomic="true" aria-live="polite" className="sr-only">
        {hasCopied ? "Copied" : ""}
      </span>
      <span aria-hidden="true" className="relative inline-flex size-4 items-center justify-center">
        <AnimatePresence initial={false} mode="sync">
          {hasCopied ? (
            <motion.span
              className="absolute inset-0 flex items-center justify-center"
              key="check"
              {...motionProps}
            >
              <Check className="size-4 text-spark" strokeWidth={2} />
            </motion.span>
          ) : (
            <motion.span
              className="absolute inset-0 flex items-center justify-center"
              key="copy"
              {...motionProps}
            >
              <Copy className="size-4" strokeWidth={2} />
            </motion.span>
          )}
        </AnimatePresence>
      </span>
    </Button>
  )
}
