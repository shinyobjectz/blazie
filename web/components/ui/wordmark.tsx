import Image from "next/image"

import { cn } from "@/lib/utils"

const sizes = {
  sm: { mark: 20, text: "text-xl" },
  md: { mark: 28, text: "text-3xl" },
  lg: { mark: 64, text: "text-6xl sm:text-7xl" },
} as const

/**
 * The flame and the name. Always lowercase — it is a wordmark, not a sentence,
 * and Pixelify Sans is doing the shouting.
 */
export function Wordmark({
  size = "md",
  className,
  markOnly = false,
}: {
  size?: keyof typeof sizes
  className?: string
  markOnly?: boolean
}) {
  const { mark, text } = sizes[size]

  return (
    <span className={cn("inline-flex items-center gap-3 select-none", className)}>
      <Image
        src="/brand/blazie-mark.gif"
        alt="blazie"
        width={mark}
        height={mark}
        priority
        unoptimized
        className="[image-rendering:pixelated]"
      />
      {!markOnly && (
        <span className={cn("font-pixel lowercase leading-none tracking-tight", text)}>
          blazie
        </span>
      )}
    </span>
  )
}
