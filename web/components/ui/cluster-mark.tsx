import { avatarOf, paletteOf } from "@/lib/world-avatar"
import { cn } from "@/lib/utils"

/**
 * The mark that stands for a cluster, everywhere one is named.
 *
 * Not a `WorldAvatar`. Clusters were wearing one, and that was wrong twice
 * over: a world's face is a planet — a circle, and at large sizes a running
 * shader — so a cluster in the switcher looked like a world, and the console's
 * two different kinds of thing were drawn as the same kind of thing. The
 * distinction the console rests on is that a cluster HOLDS worlds; if they look
 * alike, the sidebar says the opposite of what the model means.
 *
 * It also spent a WebGL context. There are six per tab and a page listing
 * worlds needs all of them; a switcher that is on every page was taking one for
 * something that is not a world at all.
 *
 * So: a rounded square rather than a circle, flat rather than lit, with the
 * initial in it. The colour is derived from the name by the same function a
 * world's is, which is deliberate — two things named the same way should be
 * recognisably related — but the SHAPE says which kind you are looking at.
 */

const SIZES = {
  sm: "size-5 text-[9px] rounded",
  md: "size-7 text-[11px] rounded-md",
  lg: "size-10 text-sm rounded-lg",
} as const

export function ClusterMark({
  name,
  size = "md",
  className,
}: {
  name: string
  size?: keyof typeof SIZES
  className?: string
}) {
  const [ink, glow] = paletteOf(avatarOf(name))

  return (
    <span
      aria-hidden
      className={cn(
        "flex shrink-0 items-center justify-center border font-mono font-semibold uppercase",
        SIZES[size],
        className,
      )}
      style={{
        // Its own colour, dimmed to a ground rather than used at full strength:
        // this sits behind a name that has to stay readable, which is the
        // opposite of a planet, whose whole job is to be the thing you look at.
        background: `color-mix(in oklab, ${ink} 18%, transparent)`,
        borderColor: `color-mix(in oklab, ${ink} 45%, transparent)`,
        color: glow,
      }}
    >
      {name.slice(0, 1)}
    </span>
  )
}
