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
import { WorldAvatar } from "@/components/ui/world-avatar"
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
 * The avatar is derived from the cluster's name by the same function that draws
 * a world's, so two clusters are told apart by colour before they are read.
 */
export function ClusterSwitcher() {
  const { clusters, cluster, chooseCluster } = useCluster()
  const router = useRouter()

  if (!cluster) {
    return (
      <Link
        href="/dashboard/clusters"
        className="flex h-full items-center gap-2 px-2 text-sm text-muted-foreground transition-colors hover:text-white"
      >
        <CircleDashed className="size-4" />
        no cluster yet
      </Link>
    )
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger className="flex h-full w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-raised">
        <WorldAvatar world={cluster.name} size="sm" />

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
            <WorldAvatar world={held.name} size="sm" />
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

        <DropdownMenuItem
          onSelect={() => router.push("/dashboard/clusters")}
          className="gap-2 text-muted-foreground"
        >
          <Plus className="size-3.5" />
          open another
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
