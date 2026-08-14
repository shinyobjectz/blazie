"use client"

import { Check, ChevronsUpDown, CircleDashed, Plus, TriangleAlert } from "lucide-react"
import Link from "next/link"
import { useRouter } from "next/navigation"

import { useCluster } from "@/app/dashboard/cluster"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { ClusterMark } from "@/components/ui/cluster-mark"
import type { Cluster } from "@/lib/blazie"
import { cn } from "@/lib/utils"

/**
 * Which cluster you are looking at, at the top of the nav.
 *
 * It replaces the wordmark, which is the right trade even though it costs the
 * brand its most obvious place: a console that manages several clusters must say
 * which one is on screen somewhere permanent, and there is exactly one spot that
 * every page shares. A logo tells you what you already know. This tells you
 * whether the number below is production.
 *
 * The mark is a `ClusterMark`, not a world's avatar. It used to be the latter,
 * which drew a cluster as a planet — a circle, and at size a running shader —
 * so the two kinds of thing this console holds looked like one kind. A cluster
 * HOLDS worlds; if they wear the same face the sidebar says the opposite of
 * what the model means. It also spent one of the six WebGL contexts a tab has,
 * from a component that is on every page, for something that is not a world.
 */
export function ClusterSwitcher() {
  const { clusters, cluster, chooseCluster } = useCluster()
  const router = useRouter()

  // Holding none never reaches this — the layout shows onboarding instead of
  // the console, so there is no sidebar to be in. This is the narrower case of
  // holding some and having chosen none, which resolves itself as soon as the
  // list loads.
  if (!cluster) {
    return (
      <Link
        href="/dashboard/clusters"
        className="flex h-full items-center gap-2 px-2 text-sm text-muted-foreground transition-colors hover:text-white"
      >
        <CircleDashed className="size-4" />
        choose a cluster
      </Link>
    )
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger className="flex h-full w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-raised">
        <ClusterMark name={cluster.name} size="md" />

        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm font-medium tracking-tight text-white">
            {cluster.name}
          </span>
          <State cluster={cluster} />
        </span>

        <ChevronsUpDown className="size-3.5 shrink-0 text-muted-foreground" />
      </DropdownMenuTrigger>

      <DropdownMenuContent align="start" className="w-60">
        <DropdownMenuLabel className="text-xs text-muted-foreground">
          clusters
        </DropdownMenuLabel>

        {clusters.map((held) => (
          <DropdownMenuItem
            key={held.id}
            onSelect={() => chooseCluster(held.id)}
            className="gap-2"
          >
            <ClusterMark name={held.name} size="sm" />
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm">{held.name}</span>
              <State cluster={held} />
            </span>
            {held.id === cluster.id ? (
              <Check className="size-3.5 shrink-0 text-flame" />
            ) : null}
          </DropdownMenuItem>
        ))}

        <DropdownMenuSeparator />

        {/* The only way to the management surface, now that it is not in the
            nav. Somebody thinking about clusters is already looking here. */}
        <DropdownMenuItem
          onSelect={() => router.push("/dashboard/clusters")}
          className="gap-2 text-muted-foreground"
        >
          <Plus className="size-3.5" />
          open another, or remove one
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/**
 * Opening, open, or unreachable — said in the switcher rather than only on the
 * clusters page, because "why is everything refusing" is answered here.
 */
function State({ cluster }: { cluster: Cluster }) {
  if (cluster.state === "open") {
    return (
      <span className="font-mono block truncate text-[10px] text-muted-foreground">
        {cluster.address.replace(/^https:\/\//, "")}
      </span>
    )
  }

  return (
    <span
      className={cn(
        "font-mono flex items-center gap-1 text-[10px]",
        cluster.state === "opening" ? "text-ember" : "text-flame",
      )}
    >
      {cluster.state === "opening" ? (
        <>
          <CircleDashed className="size-2.5 shrink-0" />
          opening
        </>
      ) : (
        <>
          <TriangleAlert className="size-2.5 shrink-0" />
          unreachable
        </>
      )}
    </span>
  )
}
