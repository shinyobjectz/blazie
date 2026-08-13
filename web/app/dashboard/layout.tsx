"use client"

import { Check, ChevronDown } from "lucide-react"

import { AppSidebar } from "@/components/dashboard/app-sidebar"
import {
  SidebarResizer,
  useSidebarWidth,
} from "@/components/dashboard/sidebar-resizer"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Separator } from "@/components/ui/separator"
import { WorldAvatar } from "@/components/ui/world-avatar"
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar"
import { Wordmark } from "@/components/ui/wordmark"

import { ClusterHeld, useClusterState } from "./cluster"

/**
 * The console shell: sidebar, and a bar saying which world you are looking at.
 *
 * Signing in is checked once, here, rather than on each page.
 */
export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const { cluster, error, retry } = useClusterState()
  const { width, setWidth, remember } = useSidebarWidth()

  if (error) {
    return (
      <main className="mx-auto max-w-3xl px-6 py-20">
        <Wordmark size="sm" className="mb-10 opacity-70" />
        <h1 className="mb-6 text-2xl font-medium tracking-tight text-white">
          the cluster would not answer for this token
        </h1>
        <RefusalNote error={error} retry={retry} />
      </main>
    )
  }

  if (!cluster) {
    return (
      <main className="px-6 py-20">
        <p className="font-mono mx-auto max-w-3xl text-sm text-muted-foreground">
          asking the cluster who you are…
        </p>
      </main>
    )
  }

  return (
    <ClusterHeld value={cluster}>
      {/* `--sidebar-width` is the variable the sidebar and its spacer already
          read, so driving it from the drag handle is the whole of the resize. */}
      <SidebarProvider style={{ "--sidebar-width": `${width}px` } as React.CSSProperties}>
        <AppSidebar login={cluster.who.login} />
        <SidebarResizer width={width} onWidth={setWidth} onSettled={remember} />

        <SidebarInset className="min-w-0">
          <header className="sticky top-0 z-10 flex h-14 shrink-0 items-center gap-3 border-b border-border bg-background/80 px-4 backdrop-blur">
            <SidebarTrigger />
            <Separator orientation="vertical" className="h-4" />

            {cluster.who.worlds.length === 0 ? (
              <span className="font-mono text-xs text-muted-foreground">
                no worlds yet
              </span>
            ) : (
              <DropdownMenu>
                <DropdownMenuTrigger className="font-mono inline-flex items-center gap-2 rounded-md border border-border py-1 pl-1 pr-3 text-xs text-white transition-colors hover:border-white/40 hover:bg-white/5">
                  {/* The one avatar worth a shader: it is the answer to "which
                      world am I writing into", and it is on screen on every
                      page whether or not the menu is ever opened. */}
                  {cluster.world ? (
                    <WorldAvatar live world={cluster.world} />
                  ) : null}
                  {cluster.world ?? "choose a world"}
                  <ChevronDown className="size-3.5 text-muted-foreground" />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="start" className="font-mono text-xs">
                  {cluster.who.worlds.map((one) => (
                    <DropdownMenuItem key={one} onSelect={() => cluster.choose(one)}>
                      <WorldAvatar size="sm" world={one} />
                      {one}
                      <Check
                        className={
                          one === cluster.world
                            ? "ml-auto size-3.5 text-flame"
                            : "ml-auto size-3.5 opacity-0"
                        }
                      />
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>
            )}

            {/* Where the last run read. A caller holds the name, never the
                bytes, so this is the one value on screen worth quoting. */}
            {cluster.at ? (
              <span className="font-mono ml-auto shrink-0 truncate text-xs text-muted-foreground">
                {Object.entries(cluster.at)
                  .map(([world, tx]) => `${world}@${tx}`)
                  .join(" ")}
              </span>
            ) : null}
          </header>

          <div className="min-w-0 flex-1 px-6 py-8">{children}</div>
        </SidebarInset>
      </SidebarProvider>
    </ClusterHeld>
  )
}
