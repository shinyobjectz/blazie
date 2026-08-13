"use client"

/**
 * A badge that can animate its width when its contents change, and carry a
 * "live" dot.
 *
 * Adapted in one substantive way: the original's rim gradients are pink/purple/
 * cyan, which on a black page beside an orange mark reads as a different
 * product. They are re-pointed at the flame, and the whole rim is off by
 * default — a data console wants a legible chip, and a glowing one beside four
 * hundred rows is noise. Opt in with `rim` where a single badge is the subject.
 */

import type { VariantProps } from "class-variance-authority"
import { motion, useReducedMotion } from "motion/react"
import { type ComponentProps, type ReactNode, useMemo } from "react"

import { badgeVariants } from "@/components/ui/badge"
import { cn } from "@/lib/utils"

const layoutTransition = { type: "spring" as const, bounce: 0, duration: 0.32 }

/** Flame, ember, spark — the mark's own three colours, in motion. */
function RimBlobs({ reduceMotion }: { reduceMotion: boolean }) {
  const blobs = [
    { bg: "linear-gradient(90deg, var(--flame), var(--ember))", left: ["-5%", "75%", "-5%"], cls: "-bottom-2 h-10 w-28 blur-xl", d: 6 },
    { bg: "linear-gradient(90deg, var(--ember), var(--spark))", left: ["65%", "10%", "65%"], cls: "-bottom-1.5 h-8 w-20 blur-lg", d: 5 },
    { bg: "linear-gradient(90deg, var(--spark), var(--flame))", left: ["25%", "55%", "25%"], cls: "-bottom-1 h-6 w-16 blur-md", d: 4 },
  ]

  return (
    <div className="pointer-events-none absolute inset-0 z-0 overflow-hidden rounded-full">
      <div className="absolute inset-x-0 bottom-0 h-1/2 opacity-70">
        {blobs.map((b) => (
          <motion.div
            key={b.cls}
            animate={{ left: b.left }}
            className={cn("absolute", b.cls)}
            style={{ background: b.bg }}
            transition={{
              duration: reduceMotion ? 0.01 : b.d,
              repeat: reduceMotion ? 0 : Number.POSITIVE_INFINITY,
              ease: "easeInOut",
            }}
          />
        ))}
      </div>
    </div>
  )
}

export interface AnimatedBadgeProps
  extends Omit<ComponentProps<typeof motion.span>, "children">,
    VariantProps<typeof badgeVariants> {
  children?: ReactNode
  /** Leading dot — opacity pulse only, and still when motion is reduced. */
  live?: boolean
  /** Animate width when contents change. Off under reduced motion regardless. */
  layout?: boolean
  /** Stops digits shifting as a count changes. */
  tabularNums?: boolean
  /** The animated gradient rim. Off by default; it is for a badge that is the subject. */
  rim?: boolean
}

export function AnimatedBadge({
  variant = "default",
  className,
  children,
  live = false,
  layout = true,
  tabularNums = false,
  rim = false,
  ...props
}: AnimatedBadgeProps) {
  const reduceMotion = useReducedMotion() ?? false
  const enableLayout = layout && !reduceMotion

  const pulse = useMemo(
    () => ({
      duration: reduceMotion ? 0 : 1.15,
      ease: "easeInOut" as const,
      repeat: reduceMotion ? 0 : Number.POSITIVE_INFINITY,
    }),
    [reduceMotion]
  )

  const body = (
    <span
      className={cn(
        "inline-flex items-center leading-none",
        tabularNums && "tabular-nums tracking-tight"
      )}
    >
      {children}
    </span>
  )

  const dot = live ? (
    <motion.span
      animate={reduceMotion ? { opacity: 1 } : { opacity: [0.35, 1, 0.35] }}
      aria-hidden
      className="size-1.5 shrink-0 self-center rounded-full bg-current"
      transition={pulse}
    />
  ) : null

  if (!rim) {
    return (
      <motion.span
        className={cn(badgeVariants({ variant }), "relative", className)}
        layout={enableLayout}
        transition={layoutTransition}
        {...props}
      >
        {dot}
        {body}
      </motion.span>
    )
  }

  return (
    <motion.span
      className={cn("relative inline-flex max-w-full items-center leading-none", className)}
      layout={enableLayout}
      transition={layoutTransition}
      {...props}
    >
      {/* Concentric radii: a 1px ring around a fully-rounded inner pill. */}
      <span className="relative z-[1] inline-flex items-center justify-center rounded-full p-px text-[0] leading-none">
        <RimBlobs reduceMotion={reduceMotion} />
        <span className={cn(badgeVariants({ variant }), "relative z-[1] backdrop-blur-xl")}>
          {dot}
          {body}
        </span>
      </span>
    </motion.span>
  )
}
