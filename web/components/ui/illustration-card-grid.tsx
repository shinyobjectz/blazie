import type { ReactNode } from "react"

import { cn } from "@/lib/utils"
import {
  FenceIllustration,
  GraphIllustration,
  ProvenanceIllustration,
} from "@/components/ui/blazie-illustrations"

export type IllustrationCardGridItem = {
  id?: string
  title: ReactNode
  description: ReactNode
  illustration: ReactNode
  className?: string
  contentClassName?: string
  titleClassName?: string
  descriptionClassName?: string
  illustrationClassName?: string
}

export type IllustrationCardGridProps = React.ComponentProps<"section"> & {
  items?: IllustrationCardGridItem[]
  cardClassName?: string
  contentClassName?: string
  titleClassName?: string
  descriptionClassName?: string
  illustrationClassName?: string
}

/**
 * The three claims that need a picture. Everything else on the page is prose,
 * because a diagram of something already obvious is decoration.
 */
export const DEFAULT_ILLUSTRATION_CARD_GRID_ITEMS: IllustrationCardGridItem[] = [
  {
    id: "provenance",
    title: "every fact knows what made it",
    description:
      "provenance is a slot in the row, not a convention. an answer either came from outside or names the code that produced it, and there is no third option to forget.",
    illustration: <ProvenanceIllustration />,
  },
  {
    id: "fence",
    title: "one line touches the outside world",
    description:
      "a formula gets no clock, no network and no filesystem — isolation is the absence of anything to reach. a job is the only thing handed the world, and the only thing a schedule attaches to.",
    illustration: <FenceIllustration />,
  },
  {
    id: "graph",
    title: "a graph you did not have to model",
    description:
      "an edge is a fact whose value is another id. no node type, no edge type, and no second store to keep in step with the first.",
    illustration: <GraphIllustration />,
  },
]

export function IllustrationCardGrid({
  items = DEFAULT_ILLUSTRATION_CARD_GRID_ITEMS,
  className,
  cardClassName,
  contentClassName,
  titleClassName,
  descriptionClassName,
  illustrationClassName,
  ...props
}: IllustrationCardGridProps) {
  const largeScreenColumnsClass = items.length === 2 ? "lg:grid-cols-2" : "lg:grid-cols-3"

  return (
    <section
      className={cn(
        "mx-auto grid w-full max-w-5xl grid-cols-1 border border-border",
        largeScreenColumnsClass,
        className
      )}
      data-slot="illustration-card-grid"
      {...props}
    >
      {items.map((item, index) => {
        const isLastCard = index === items.length - 1

        return (
          <div
            className={cn(
              "flex flex-col gap-8 p-8 lg:h-[450px]",
              !isLastCard && "border-b border-border lg:border-r lg:border-b-0",
              cardClassName,
              item.className
            )}
            data-slot="illustration-card-grid-item"
            key={item.id ?? index}
          >
            <div
              className={cn("flex flex-col gap-4", contentClassName, item.contentClassName)}
              data-slot="illustration-card-grid-content"
            >
              <h3
                className={cn(
                  "text-balance text-xl font-medium leading-7 tracking-tight text-foreground/90",
                  titleClassName,
                  item.titleClassName
                )}
                data-slot="illustration-card-grid-title"
              >
                {item.title}
              </h3>
              <p
                className={cn(
                  "text-sm leading-relaxed text-foreground/60",
                  descriptionClassName,
                  item.descriptionClassName
                )}
                data-slot="illustration-card-grid-description"
              >
                {item.description}
              </p>
            </div>
            <div
              className={cn(
                "pointer-events-none flex grow select-none items-end justify-center",
                illustrationClassName,
                item.illustrationClassName
              )}
              data-slot="illustration-card-grid-illustration"
            >
              {item.illustration}
            </div>
          </div>
        )
      })}
    </section>
  )
}
